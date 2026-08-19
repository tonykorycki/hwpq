`default_nettype none
// white-box addendum for systolic_array: characterising the F-7 ready/accept gap
//
// Separate from hwpq_spec.sv for the usual reason - the shared spec reads only
// the six interface ports, and this file reaches inside one module.
//
// WHAT THIS IS FOR
//
// systolic_array advertises write-readiness and gates write-acceptance on two
// DIFFERENT thresholds (systolic_array.sv:81, :252):
//
//     o_write_ready = !(size >= QUEUE_SIZE - 3) && ...   // what it ADVERTISES
//     full          =  (size >= QUEUE_SIZE - 2)          // what it ENFORCES
//     if (i_wrt && !i_read && !full) size_next = size + 1;
//
// so there is a band of `size` where the queue says "not ready" and takes the
// write anyway. F-7 was found from a counterexample trace, which shows the
// behaviour exists but not how wide it is or whether it is reachable in
// general. These properties decide both, from inside, for every reachable
// state - which is what turns an anecdote into a characterisation.
//
// Runs with ASSUME_ENQ_WHEN_WREADY = 0 by construction: this file is bound
// WITHOUT hwpq_spec, so the assumption that hides the window is not present.

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

  // The window: quiescent, advertising no room, but not actually full.
  wire in_gap = settled && !o_write_ready && !full;

  // 1. The gap is EXACTLY one slot wide, and sits at QUEUE_SIZE-3.
  //    `settled` is what rules out the other reason o_write_ready drops - a
  //    MIN_VALUE bubble at the head - so what is left is purely the threshold
  //    disagreement.
  a_gap_is_one_slot : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      in_gap |-> size == QUEUE_SIZE - 3);

  // 2. In that window the DUT really does take the write it just refused to
  //    advertise. This is the F-7 mechanism itself, stated as an invariant
  //    rather than read off one trace.
  a_gap_accepts_anyway : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      in_gap && cmd_enqueue |=> size == $past(size) + 1);

  // 3. The true capacity, which is one more than the advertised one.
  a_size_bounded : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      size <= QUEUE_SIZE - 2);

  // Anti-vacuity. If the window were unreachable, 1 and 2 would prove while
  // saying nothing at all - which is exactly the failure mode that makes a
  // green table worthless.
  c_gap_reachable    : cover property (@(posedge i_CLK) disable iff (!i_RSTn) in_gap);
  c_gap_write_taken  : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      in_gap && cmd_enqueue);

  // The consequence a caller can observe: the queue holding strictly more than
  // it ever advertised room for.
  c_holds_beyond_advertised : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && size > QUEUE_SIZE - 3);

`ifdef HWPQ_SELFTEST
  // This file is bound WITHOUT hwpq_spec, so it does not inherit that file's
  // self-test hook - and a configuration with no way to fail is a configuration
  // that has stopped checking. That is F-3, which cost a green --selftest on
  // every sequential module before it was noticed. Repeated here rather than
  // shared, because the whole point is that it must exist in every build.
  a_selftest_must_fail : assert property (@(posedge i_CLK) disable iff (!i_RSTn) 1'b0);
`endif

endmodule

`default_nettype wire
