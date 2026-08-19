// Attaches hwpq_spec to systolic_array
//
// Port-map explicitly rather than `.*`, and pass every parameter explicitly.
//
// This module breaks the pattern the first four shared. Read the ready
// derivation before changing anything here (systolic_array.sv:81-83):
//
//   full          = size >= QUEUE_SIZE - 2
//   empty         = size <= 0
//   o_write_ready = !(size >= QUEUE_SIZE - 3) && (o_data != MIN_VALUE || empty)
//   o_read_ready  = !empty && (o_data != MIN_VALUE)
//
// Three consequences, each of which decides a parameter below.
//
// HAS_BUSY=1. Dequeuing writes MIN_VALUE into OB[0] and lets a "bubble"
// propagate back through the array to refill the head. While that bubble sits
// at the head both readies go low - the `o_data != MIN_VALUE` term is what
// drops them - so `settled` really does deassert and the busy machinery in the
// spec applies. Note this is a DIFFERENT mechanism from the trees: there is no
// timer, the busy state is decoded from the head value itself.
//
// HAS_FULL=0. `!o_write_ready` conflates two unrelated things - the bubble
// state above, and a capacity limit at QUEUE_SIZE-3 rather than QUEUE_SIZE. The
// array reserves slack slots for the shifting network to work in, so its
// effective capacity is strictly below the nominal QUEUE_SIZE and
// a_occ_full_agrees (`occ == QUEUE_SIZE` iff `!o_write_ready`) cannot hold.
// HAS_FULL=0 is the honest setting, not a workaround; it costs
// a_no_enq_when_full and the two full covers, which is recorded as a hole.
//
// MAX_SETTLE is a plain number here, unlike the trees. This design has no
// settle-timer localparam to read - the bubble takes as long as it takes - so
// the bound is pinned by a_progress rather than transcribed from the RTL. If
// a_progress fails, read the counterexample length and raise this; do not raise
// it pre-emptively, because a too-large MAX_SETTLE weakens both a_progress and
// p_at_next_settle without any warning in the table.
//
// systolic_array has no ENQ_ENA parameter at all - the enqueue datapath is
// always present - so ENQ_ENA is passed as a literal 1 rather than forwarded.
bind systolic_array hwpq_spec #(
    .QUEUE_SIZE (QUEUE_SIZE),
    .DATA_WIDTH (DATA_WIDTH),
    .ENQ_ENA    (1'b1),
    .HAS_BUSY   (1'b1),
    .MAX_SETTLE (2),
    .HAS_FULL   (1'b0),
    // F-7: this DUT advertises !o_write_ready one slot before it actually stops
    // accepting writes, so the spec's ready-based acceptance decode undercounts
    // without this. See the parameter comment in hwpq_spec.sv.
    .ASSUME_ENQ_WHEN_WREADY (1'b1)
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
