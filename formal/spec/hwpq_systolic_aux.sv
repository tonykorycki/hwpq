`default_nettype none
// white-box addendum for systolic_array: capacity and handshake agreement
//
// Separate from hwpq_spec.sv for the usual reason - the shared spec reads only
// the six interface ports, and this file reaches inside one module.
//
// WHAT THIS IS FOR
//
// systolic_array has two notions of "no more room" and they have to agree:
//
//   full          =  (size >= QUEUE_SIZE - 2)     what the enqueue path ENFORCES
//   o_write_ready = !full && (bubble term)        what the queue ADVERTISES
//
// They did not always. o_write_ready used to carry its own threshold at
// QUEUE_SIZE-3, one slot tighter, so the queue advertised no room while still
// accepting writes. That was F-7: it cost a usable slot for any caller that
// honoured the ready, and left a window that behaved differently for one that
// did not. The two are now structurally coupled - o_write_ready is derived from
// `full` - and these properties are what keeps them that way.
//
// This file previously measured the width of that window. It does not need to
// any more; it guards the invariant instead. The measurement is recorded in
// F-7/F-9 of formal/README.md.

module hwpq_systolic_aux #(
    parameter int QUEUE_SIZE = 8
) (
    input var logic i_CLK,
    input var logic i_RSTn,
    input var logic i_wrt,
    input var logic i_read,
    input var logic o_write_ready,
    input var logic o_read_ready,
    input var int   size,
    input var logic full,
    input var logic empty
);

  wire settled     = o_write_ready || o_read_ready;
  wire cmd_enqueue = i_wrt && !i_read;

  // THE INVARIANT: while quiescent, what the queue advertises is exactly what it
  // will accept. `settled` is what rules out the other reason o_write_ready
  // drops - a MIN_VALUE bubble at the head, which is a busy state and not a
  // capacity limit. Re-introducing a separate threshold on either side breaks
  // this immediately.
  a_ready_matches_accept : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled |-> (o_write_ready == !full));

  // The real capacity, two below nominal. The two reserved slots are what keeps
  // the shift network able to move; one is provably not enough (F-9).
  a_size_bounded : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      size <= QUEUE_SIZE - 2);

  // Anti-vacuity. Both asserts are trivial on a queue that never fills, and
  // a_ready_matches_accept says nothing unless o_write_ready is seen low while
  // settled - which is the whole case it exists to pin down.
  c_at_capacity   : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && size == QUEUE_SIZE - 2);
  c_write_refused : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && cmd_enqueue && !o_write_ready);

`ifdef HWPQ_SELFTEST
  // Bound without hwpq_spec, so it does not inherit that file's self-test hook.
  // A configuration with no way to fail has stopped checking (F-3).
  a_selftest_must_fail : assert property (@(posedge i_CLK) disable iff (!i_RSTn) 1'b0);
`endif

endmodule

`default_nettype wire
