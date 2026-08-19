// Attaches hwpq_spec and hwpq_tree_aux to register_tree_pipelined
//
// Port-map explicitly rather than `.*`, and pass every parameter explicitly.
//
// Same shape as register_tree: both readies gate on head_valid (:100-101), so
// HAS_BUSY=1, and head_valid is a countdown flop (:281) rather than a heap
// scan - so the timer-soundness lemma applies here too, unchanged.
//
// The timer bound differs though. register_tree takes the larger of
// CLIMB_CYCLES and SINK_CYCLES; this design uses one uniform SETTLE_CYCLES =
// TREE_DEPTH (:48), which is deeper. Reading it from the DUT's own localparam
// means the difference is picked up automatically instead of being transcribed.
bind register_tree_pipelined hwpq_spec #(
    .QUEUE_SIZE (QUEUE_SIZE),
    .DATA_WIDTH (DATA_WIDTH),
    .ENQ_ENA    (ENQ_ENA),
    .HAS_BUSY   (1'b1),
    .MAX_SETTLE (SETTLE_CYCLES),
    .HAS_FULL   (1'b1)
) u_spec (
    .i_CLK        (i_CLK),
    .i_RSTn       (i_RSTn),
    .i_wrt        (i_wrt),
    .i_read       (i_read),
    .i_data       (i_data),
    .o_write_ready(o_write_ready),
    .o_read_ready (o_read_ready),
    .o_data       (o_data)
);

bind register_tree_pipelined hwpq_tree_aux #(
    .DATA_WIDTH  (DATA_WIDTH),
    .NODES_NEEDED(NODES_NEEDED)
) u_aux (
    .i_CLK     (i_CLK),
    .i_RSTn    (i_RSTn),
    .head_valid(head_valid),
    .queue     (queue)
);
