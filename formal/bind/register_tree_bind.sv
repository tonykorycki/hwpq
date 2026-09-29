// Attaches hwpq_spec to register_tree
//
// Port-map explicitly rather than `.*`, and pass every parameter explicitly.
//
// register_tree is the first SEQUENTIAL module in the suite. Both readies are
// gated on head_valid (register_tree.sv:115-116), so they drop together while
// an operation is in flight and `settled` really does go low: HAS_BUSY=1.
//
// MAX_SETTLE is taken from the DUT's own SETTLE_MAX localparam rather than
// hardcoded, so it tracks QUEUE_SIZE automatically. SETTLE_MAX is the larger of
// CLIMB_CYCLES and SINK_CYCLES (register_tree.sv:50-52) - the same hand-computed
// bound the settle timer loads. Asserting a_progress against it is therefore a
// real check that the timer is big enough, not a tautology: the property fails
// if the design stays unsettled longer than the design itself claims it can.
bind register_tree hwpq_spec #(
    .QUEUE_SIZE (QUEUE_SIZE),
    .DATA_WIDTH (DATA_WIDTH),
    .ENQ_ENA    (ENQ_ENA),
    .HAS_BUSY   (1'b1),
    .MAX_SETTLE (SETTLE_MAX),
    .HAS_FULL   (1'b1),
`ifdef HWPQ_UNGATED
    // run.sh --ungated: drop the workaround and reproduce the recorded defect.
    .ASSUME_FILL_FIRST (1'b0)
`else
    .ASSUME_FILL_FIRST (1'b1)
`endif
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
