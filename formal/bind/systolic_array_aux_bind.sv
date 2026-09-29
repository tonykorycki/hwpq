// Attaches hwpq_systolic_aux to systolic_array
//
// Bound alone, without hwpq_spec: this file asks a white-box question about the
// module's two capacity thresholds, and needs no interface-level assumptions to
// do it.
bind systolic_array hwpq_systolic_aux #(
    .QUEUE_SIZE(QUEUE_SIZE)
) u_sys_aux (
    .i_CLK        (i_CLK),
    .i_RSTn       (i_RSTn),
    .i_wrt        (i_wrt),
    .i_read       (i_read),
    .o_write_ready(o_write_ready),
    .o_read_ready (o_read_ready),
    .size         (size),
    .full         (full),
    .empty        (empty)
);
