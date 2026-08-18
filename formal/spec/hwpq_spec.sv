`default_nettype none
// portable specification for the HWPQ library
//
// Bound to a DUT from outside (formal/bind/). Reads just the six shared
// interface ports, so the same file attaches to every architecture in the library
//
// Portability Notes:
// - Every property carries its own explicit `@(posedge i_CLK)` and
//   `disable iff (!i_RSTn)` instead of using `default clocking` / `default disable iff`,
//   to avoid relying on tool support, and unblock local testing
// - `var` on the inputs keeps the ports single-driver under `default_nettype none`.
//
// CONTENTS (see formal/README.md section 4 for the tier definitions):
//   Tier 0  assumptions - the interface contract we promise the DUT
//   Tier 1  progress and handshake asserts
//   4.5     anti-vacuity cover set
// Tier 2 (occupancy) and Tier 3 (ordering, via the tv/count abstraction) are
// not here yet.

module hwpq_spec #(
    // These must match the elaborated DUT. The bind file passes them
    // explicitly - dont rely on the defaults here
    parameter int QUEUE_SIZE = 4,
    parameter int DATA_WIDTH = 3,
    parameter bit ENQ_ENA    = 1,

    // Does the DUT have a busy state
    // 0 = single-cycle design; `settled` is constant 1
    // 1 = sequential design; `settled` drops while an operation is in flight
    parameter bit HAS_BUSY = 1,

    // Upper bound, in cycles, on how long the DUT may stay unsettled
    parameter int MAX_SETTLE = 1,

    // Applies am_no_cmd_while_busy, which hides any bug needing a command
    // mid-operation (hole CH-2). Set 0 for a second, ungated run.
    parameter bit NO_CMD_WHILE_BUSY = 1
) (
    input var logic                  i_CLK,
    input var logic                  i_RSTn,
    input var logic                  i_wrt,
    input var logic                  i_read,
    input var logic [DATA_WIDTH-1:0] i_data,
    input var logic                  o_write_ready,
    input var logic                  o_read_ready,
    input var logic [DATA_WIDTH-1:0] o_data
);

  // A module is either idle - in which case it cannot be simultaneously full
  // and empty, so at least one ready is high - or it is mid-operation, in which case
  // the sequential designs drop both. Same wire the simulation harness uses
  wire settled = o_write_ready || o_read_ready;

  // Command decode, straight off {i_wrt, i_read}. `replace` deliberately needs
  // NEITHER ready - only quiescence - so it is never gated on one.
  wire cmd_enqueue = i_wrt && !i_read;
  wire cmd_dequeue = !i_wrt && i_read;
  wire cmd_replace = i_wrt && i_read;


  // ---------------------------------------------------------------------------
  // Tier 0 - the interface contract (assumptions)
  //
  // EVERY ASSUMPTION IS A HOLE. Over-assume and the design can no longer reach
  // the interesting states, every assert passes vacuously, and the summary
  // table looks identical to a real proof. The cover set below is the detector.
  // ---------------------------------------------------------------------------

  // '0 and all-ones are reserved sentinels, not payloads. Hole CH-1; the
  // behaviour when they ARE driven is characterised in Appendix A.
  am_payload_legal : assume property (@(posedge i_CLK) disable iff (!i_RSTn)
      i_data != '0 && i_data != '1);

  generate
    // Guarded on HAS_BUSY as well as the parameter: with no busy state the
    // antecedent is unsatisfiable, so this constrains nothing and only leaves
    // an UNREACHABLE precondition cover behind. See section 4.5.
    if (HAS_BUSY && NO_CMD_WHILE_BUSY) begin : g_no_cmd_while_busy
      am_no_cmd_while_busy : assume property (@(posedge i_CLK) disable iff (!i_RSTn)
          !settled |-> !i_wrt && !i_read);
    end

    // A replace-only build has no enqueue datapath, so a bare write is not a
    // command it has. Keeps the reachable command set honest.
    if (!ENQ_ENA) begin : g_replace_only
      am_no_enqueue_cmd : assume property (@(posedge i_CLK) disable iff (!i_RSTn)
          !cmd_enqueue);
    end
  endgenerate


  // ---------------------------------------------------------------------------
  // Tier 1 - progress and handshake
  // ---------------------------------------------------------------------------

  // "At the first settled cycle at or after the next one, `cond` holds."
  //
  // This is what keeps the handshake asserts portable: a plain |=> is only
  // sound at MAX_SETTLE 1, and on a sequential module lands on a busy cycle
  // where the consequent is trivially true. Collapses back to |=> when
  // `settled` is constant, so do NOT fork it per HAS_BUSY. See section 4.
  property p_at_next_settle(trigger, cond);
    @(posedge i_CLK) disable iff (!i_RSTn)
    trigger |=> (!settled)[*0:MAX_SETTLE] ##1 (settled && cond);
  endproperty

  // PROGRESS: the DUT always returns to a commandable state within MAX_SETTLE.
  // The property simulation is worst at, and a deadlock invalidates every other
  // result - a wedged queue trivially satisfies "the head is always correct".
  //
  // Only meaningful with a busy state; a_plumbing below is the stronger
  // statement that replaces it when there is none. Exactly one of the two
  // exists in any given build.
  generate
    if (HAS_BUSY) begin : g_progress
      a_progress : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
          !settled |-> ##[1:MAX_SETTLE] settled);
    end
  endgenerate

  // A refused command has no effect: the ready does not flip in your favour.
  // There is no "accepted" signal on the interface and we do not need one -
  // occupancy modelling is Tier 2's job. Both exclude `replace` by
  // construction, which is what stops them fighting the ENQ_ENA=0 modules.
  generate
    if (ENQ_ENA) begin : g_enq_handshake
      a_no_enq_when_full : assert property (p_at_next_settle(
          settled && !o_write_ready && cmd_enqueue, !o_write_ready));
    end
  endgenerate

  a_no_deq_when_empty : assert property (p_at_next_settle(
      settled && !o_read_ready && cmd_dequeue, !o_read_ready));


  // For a DUT with no busy state, `settled` is constant 1. This proves everything binded correctly
  // HWPQ_SELFTEST inverts it into a guaranteed failure. This proves the harness can report failure
  generate
    if (!HAS_BUSY) begin : g_plumbing
`ifdef HWPQ_SELFTEST
      a_plumbing : assert property (@(posedge i_CLK) disable iff (!i_RSTn) !settled);
`else
      a_plumbing : assert property (@(posedge i_CLK) disable iff (!i_RSTn) settled);
`endif
    end
  endgenerate


  // ---------------------------------------------------------------------------
  // 4.5 - anti-vacuity cover set. NOT OPTIONAL.
  //
  // If any of these comes back UNREACHABLE an assumption has strangled the
  // design and every `proven` above it is worthless. common.tcl fails the run
  // on one rather than leaving it to be noticed by eye.
  // ---------------------------------------------------------------------------

  // if this comes back unreachable the design cannot move and every `proven` above it is worthless
  c_plumbing_alive : cover property (@(posedge i_CLK) disable iff (!i_RSTn) o_read_ready);

  generate
    if (ENQ_ENA) begin : g_enq_covers
      c_enqueue_fires : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
          settled && o_write_ready && cmd_enqueue);
      // Full is only reachable in a build that can actually push elements in.
      c_reaches_full : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
          settled && !o_write_ready);
      c_deq_from_full : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
          settled && !o_write_ready && cmd_dequeue);
    end
  endgenerate

  c_dequeue_fires : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && o_read_ready && cmd_dequeue);

  c_replace_fires : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && cmd_replace);

  c_reaches_empty : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && !o_read_ready);

  // Parameters not yet consumed. QUEUE_SIZE arrives in Tier 2 (occupancy).
  localparam int UNUSED_GUARD = QUEUE_SIZE;
  if (UNUSED_GUARD < 0) begin : g_never
    // never elaborated; exists only to consume the parameters
  end

endmodule

`default_nettype wire
