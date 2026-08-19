// Attaches hwpq_systolic_aux to systolic_array
//
// Deliberately does NOT bind hwpq_spec alongside it. The spec carries
// ASSUME_ENQ_WHEN_WREADY, which forbids exactly the window this file exists to
// characterise - binding both would make every property here vacuous and the
// covers unreachable.
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
