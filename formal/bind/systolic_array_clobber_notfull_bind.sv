// Attaches hwpq_systolic_clobber to systolic_array
//
// Bound alone, without hwpq_spec: the spec carries ASSUME_ENQ_WHEN_WREADY,
// which forbids the very writes this run exists to study.
//
// HALF_SIZE is passed explicitly because it sizes the IB/OB ports - getting it
// from QUEUE_SIZE independently would silently truncate if the DUT ever changed
// how it splits the array.
bind systolic_array hwpq_systolic_clobber #(
    .QUEUE_SIZE(QUEUE_SIZE),
    .DATA_WIDTH(DATA_WIDTH),
    .HALF_SIZE (HALF_SIZE),
    .ASSUME_ENQ_WHEN_NOT_FULL (1'b1)
) u_clobber_nf (
    .i_CLK        (i_CLK),
    .i_RSTn       (i_RSTn),
    .i_wrt        (i_wrt),
    .i_read       (i_read),
    .i_data       (i_data),
    .o_write_ready(o_write_ready),
    .o_read_ready (o_read_ready),
    .IB           (IB),
    .OB           (OB),
    .size         (size),
    .full         (full),
    .empty        (empty)
);
