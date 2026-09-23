`default_nettype none
// white-box addendum for the register tree designs
//
// Separate from hwpq_spec.sv on purpose. The shared spec reads only the six
// interface ports, which is what lets it bind to every architecture unchanged.
// This file reaches INSIDE one family, so keeping the two apart is what stops
// the portable spec from acquiring module-specific dependencies.
//
// WHAT THIS IS FOR
//
// register_tree does not derive head_valid from a heap scan. It derives it from
// a hand-computed countdown loaded with CLIMB_CYCLES/SINK_CYCLES
// (register_tree.sv:50-52, :312-324). The timer is a CLAIM - "by now the head
// is trustworthy" - and asserting the timer against itself would prove nothing.
//
// So invert it: prove the claim is CONSERVATIVE. Whenever the timer says the
// head is valid, the heap really does hold. Simulation can only ever sample
// whether a hand-computed cycle count was large enough; this decides it for
// every reachable state at once.
//
// `heap_holds` is the design's own definition, taken verbatim from the
// commented-out detector at register_tree.sv:338-344 - the alternative the
// author measured against but did not ship.

module hwpq_tree_aux #(
    parameter int DATA_WIDTH   = 3,
    parameter int NODES_NEEDED = 7
) (
    input var logic                  i_CLK,
    input var logic                  i_RSTn,
    input var logic                  head_valid,
    input var logic [DATA_WIDTH-1:0] queue      [NODES_NEEDED]
);

  // Every parent outranks both of its children.
  logic heap_holds;
  always_comb begin : heap_invariant
    heap_holds = 1'b1;
    for (int i = 0; i < NODES_NEEDED; i++) begin
      if (2 * i + 1 < NODES_NEEDED && queue[i] < queue[2*i+1]) heap_holds = 1'b0;
      if (2 * i + 2 < NODES_NEEDED && queue[i] < queue[2*i+2]) heap_holds = 1'b0;
    end
  end

  // The weaker claim that actually matters at the interface: the root outranks
  // everything held. Implied by the full invariant, but worth asserting
  // separately - if the timer turns out to guarantee the head without
  // guaranteeing full heap order, that is a materially different result and
  // this is what distinguishes them.
  logic head_outranks_all;
  always_comb begin : root_dominates
    head_outranks_all = 1'b1;
    for (int i = 1; i < NODES_NEEDED; i++) begin
      if (queue[0] < queue[i]) head_outranks_all = 1'b0;
    end
  end

  // THE LEMMA: the timer never claims validity before the heap has settled.
  a_timer_is_sound : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      head_valid |-> heap_holds);

  a_timer_head_is_max : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      head_valid |-> head_outranks_all);

  // Anti-vacuity. If head_valid were stuck low the lemma would prove while
  // saying nothing at all; if it were stuck high the timer would not exist.
  c_timer_valid   : cover property (@(posedge i_CLK) disable iff (!i_RSTn) head_valid);
  c_timer_counting : cover property (@(posedge i_CLK) disable iff (!i_RSTn) !head_valid);

endmodule

`default_nettype wire
