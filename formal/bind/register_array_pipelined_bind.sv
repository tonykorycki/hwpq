// Attaches hwpq_spec to register_array_pipelined
//
// Port-map explicitly rather than `.*`, and pass every parameter explicitly.
//
// Sequential, like register_tree, but it reaches `settled` a different way.
// register_tree counts down a hand-computed timer; this design derives
// head_valid straight from the data - `queue[0] >= queue[1]`
// (register_array_pipelined.sv:198) - and gates both readies on it
// (:74-75), so HAS_BUSY=1.
//
// MAX_SETTLE is therefore NOT read from a localparam here, because there is no
// timer to read: the settle time is however long the compare-exchange network
// takes to get the two leading elements in order. 2 covers the even/odd phase
// pair. If a_progress fails, that number is wrong and is the thing to raise -
// the property is what pins it down.
bind register_array_pipelined hwpq_spec #(
    .QUEUE_SIZE (QUEUE_SIZE),
    .DATA_WIDTH (DATA_WIDTH),
    .ENQ_ENA    (ENQ_ENA),
    .HAS_BUSY   (1'b1),
    .MAX_SETTLE (2),
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
