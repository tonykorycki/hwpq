// Attaches hwpq_systolic_clobber to systolic_array
//
// Bound alone, without hwpq_spec, and with NO assumption about when writes may
// be issued. It used to need one: before F-8 was fixed, a caller that asserted
// i_wrt while full corrupted IB[0], and the properties below only held for a
// caller that honoured o_write_ready. Now they hold unconditionally, which is
// the stronger and correct statement - a refused command is inert.
//
// HALF_SIZE is passed explicitly because it sizes the IB/OB ports - getting it
// from QUEUE_SIZE independently would silently truncate if the DUT ever changed
// how it splits the array.
bind systolic_array hwpq_systolic_clobber #(
    .QUEUE_SIZE(QUEUE_SIZE),
    .DATA_WIDTH(DATA_WIDTH),
    .HALF_SIZE (HALF_SIZE)
) u_clobber (
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
