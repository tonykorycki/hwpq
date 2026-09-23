`default_nettype none
// white-box addendum for systolic_array: does a write ever destroy IB[0]?
//
// Separate from hwpq_systolic_aux.sv on purpose. That file characterises the
// F-7 window with NO assumptions at all, which is what makes its results
// strong. This one needs the payload-alphabet convention to say anything
// (a tracked value has to be distinguishable from an empty cell), so keeping
// them apart avoids retroactively weakening a result already reported.
//
// THE QUESTION
//
// Every enqueue and every replace writes IB[0] unconditionally
// (systolic_array.sv:100-117) - there is no "is IB[0] free?" check anywhere.
// Whatever sat there is overwritten unless the sorting network moved it out in
// the same cycle. The shift chain that does the moving is anchored on the last
// IB slot being empty and propagates backward one cell per cycle, so how much
// slack the queue keeps decides whether IB[0] drains in time.
//
// These properties held only for a well-behaved caller until F-8 was fixed;
// they now hold with NO assumption at all, which is the statement worth having:
// a refused command is inert. The parameters that used to select between those
// configurations are gone along with the defect that needed them.
//
// METHOD
//
// The same counting abstraction hwpq_spec uses for ordering, applied to the
// physical cells instead of the interface: pick one arbitrary value, count how
// many copies live in IB and OB, and require that the count only ever falls
// when the head is legitimately popped. A clobbered IB[0] is a copy that
// vanishes with no pop to account for it.

module hwpq_systolic_clobber #(
    parameter int QUEUE_SIZE = 8,
    parameter int DATA_WIDTH = 3,
    parameter int HALF_SIZE  = 4
) (
    input var logic                  i_CLK,
    input var logic                  i_RSTn,
    input var logic                  i_wrt,
    input var logic                  i_read,
    input var logic [DATA_WIDTH-1:0] i_data,
    input var logic                  o_write_ready,
    input var logic                  o_read_ready,
    input var logic [DATA_WIDTH-1:0] IB    [HALF_SIZE],
    input var logic [DATA_WIDTH-1:0] OB    [HALF_SIZE],
    input var int                    size,
    input var logic                  full,
    input var logic                  empty
);

  localparam logic [DATA_WIDTH-1:0] MIN_VALUE = '0;

  wire settled     = o_write_ready || o_read_ready;
  wire cmd_enqueue = i_wrt && !i_read;

  // ---------------------------------------------------------------------------
  // Environment. MIN_VALUE is the module's reserved "invalid entry" sentinel
  // (systolic_array.sv:50, :28), so driving it as a payload is out of the
  // supported input range - hole CH-1, and Appendix A.1 records that it wedges
  // the queue outright. The stimulus in the shared testbench excludes it too.
  // ---------------------------------------------------------------------------
  am_payload_legal : assume property (@(posedge i_CLK) disable iff (!i_RSTn)
      i_data != MIN_VALUE);

  // The standard quiescence convention (CH-2).
  am_no_cmd_while_busy : assume property (@(posedge i_CLK) disable iff (!i_RSTn)
      !settled |-> !i_wrt && !i_read);

  // ---------------------------------------------------------------------------
  // The tracked value: undriven, so the tool explores every choice at once.
  // ---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] tv;

  am_tv_stable : assume property (@(posedge i_CLK) disable iff (!i_RSTn)
      ##1 $stable(tv));
  am_tv_legal : assume property (@(posedge i_CLK) disable iff (!i_RSTn)
      tv != MIN_VALUE);

  // How many copies of tv are physically resident, across BOTH buffers.
  int phys_count;
  always_comb begin : count_copies
    phys_count = 0;
    for (int i = 0; i < HALF_SIZE; i++) begin
      if (IB[i] == tv) phys_count = phys_count + 1;
      if (OB[i] == tv) phys_count = phys_count + 1;
    end
  end

  // The ONLY legitimate way a copy leaves: the head is popped. Both arms zero
  // OB[0] (:95, :115). Note these are the DUT's own internal accept gates, not
  // the advertised readies - which is exactly the distinction F-7 is about.
  wire deq_fires = i_read && !i_wrt && !empty;
  wire rep_fires = i_wrt && i_read && !empty;
  wire pops_tv   = (deq_fires || rep_fires) && (OB[0] == tv);

  logic past_valid;
  always_ff @(posedge i_CLK or negedge i_RSTn) begin
    if (!i_RSTn) past_valid <= 1'b0;
    else past_valid <= 1'b1;
  end

  // THE PROPERTY: no copy disappears without a pop to account for it. A write
  // that overwrites a live IB[0] is precisely a copy going missing with
  // pops_tv low, so this fires on a clobber and on nothing else.
  a_no_clobber : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      past_valid |-> ($past(phys_count) - phys_count) <= ($past(pops_tv) ? 1 : 0));

  // ---------------------------------------------------------------------------
  // Anti-vacuity. a_no_clobber is worthless unless the dangerous situation is
  // actually reachable - a queue that never puts the tracked value in IB[0],
  // or never writes while it is there, satisfies it trivially.
  // ---------------------------------------------------------------------------
  c_tv_in_ib0 : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      IB[0] == tv);

  // The risk scenario itself: a write arrives while IB[0] holds a live value.
  c_write_onto_live_ib0 : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && cmd_enqueue && IB[0] == tv);

  // Replace hits IB[0] too, and is gated on no ready at all.
  c_replace_onto_live_ib0 : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && i_wrt && i_read && !empty && IB[0] == tv);

  // ---------------------------------------------------------------------------
  // Soundness diagnostic for the property above.
  //
  // phys_count counts CELLS equal to tv. That is only a valid proxy for "copies
  // the queue is holding" if the array never leaves stale cells behind - values
  // that are logically gone but were never overwritten with MIN_VALUE. The
  // array clears vacated cells only under conditions, so this is worth
  // checking rather than assuming: if live_cells can exceed `size`, there are
  // ghosts, a_no_clobber can fire on an overwrite of one, and it is NOT a
  // sound data-loss detector.
  // ---------------------------------------------------------------------------
  int live_cells;
  always_comb begin : count_live
    live_cells = 0;
    for (int i = 0; i < HALF_SIZE; i++) begin
      if (IB[i] != MIN_VALUE) live_cells = live_cells + 1;
      if (OB[i] != MIN_VALUE) live_cells = live_cells + 1;
    end
  end

  // Stated as an ASSERT, not a cover: "no ghosts" is the desired outcome, and a
  // cover whose unreachability is the good news is the wrong construct - it
  // would fail the run via common.tcl's vacuity gate for the right reason
  // reported as the wrong one.
  a_no_ghost_cells : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled |-> live_cells <= size);

`ifdef HWPQ_SELFTEST
  // Bound without hwpq_spec, so it does not inherit that file's self-test hook.
  // A configuration with no way to fail has stopped checking (F-3).
  a_selftest_must_fail : assert property (@(posedge i_CLK) disable iff (!i_RSTn) 1'b0);
`endif

endmodule

`default_nettype wire
