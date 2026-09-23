// Attaches hwpq_spec to register_array
//
// Port-map explicitly rather than `.*`, and pass every parameter explicitly
//
// register_array folds the whole operation into a combinational sort network in
// one cycle, and both `full` and `empty` are pure functions of `size`
// so both readies can never be low together: HAS_BUSY=0, MAX_SETTLE=1
bind register_array hwpq_spec #(
    .QUEUE_SIZE (QUEUE_SIZE),
    .DATA_WIDTH (DATA_WIDTH),
    .ENQ_ENA    (ENQ_ENA),
    .HAS_BUSY   (1'b0),
    .MAX_SETTLE (1),
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
