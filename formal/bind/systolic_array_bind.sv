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
// HAS_FULL=1, via CAPACITY. `!o_write_ready` here means "full OR bubble", but
// the bubble case is excluded by `settled` in every property that uses it, so
// once the capacity is named correctly the full properties hold exactly as they
// do on the register designs.
//
// MAX_SETTLE is a plain number here, unlike the trees. This design has no
// settle-timer localparam to read - the bubble takes as long as it takes - so
// the bound is pinned by a_progress rather than transcribed from the RTL. If
// a_progress fails, read the counterexample length and raise this; do not raise
// it pre-emptively, because a too-large MAX_SETTLE weakens both a_progress and
// p_at_next_settle without any warning in the table.
//
// ASSUME_ENQ_WHEN_WREADY is GONE, and its absence is the point. It used to be
// needed because o_write_ready and the enqueue path disagreed by one slot, so
// the spec's "acceptance == the matching ready" decode undercounted (F-7). The
// two are now structurally coupled, the decode is exact, and the proof holds
// with no assumption about when the caller may write.
//
// systolic_array has no ENQ_ENA parameter at all - the enqueue datapath is
// always present - so ENQ_ENA is passed as a literal 1 rather than forwarded.
bind systolic_array hwpq_spec #(
    .QUEUE_SIZE (QUEUE_SIZE),
    .DATA_WIDTH (DATA_WIDTH),
    .ENQ_ENA    (1'b1),
    .HAS_BUSY   (1'b1),
    .MAX_SETTLE (2),
    // The real capacity: the array reserves two slots for its shift network,
    // so it holds QUEUE_SIZE-2 rather than QUEUE_SIZE (F-9). Naming it is what
    // lets HAS_FULL be 1 here, so this module is proved with the same property
    // set as the register designs rather than a strictly weaker one.
    .CAPACITY   (QUEUE_SIZE - 2),
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


// Reset harness -- the elaboration top for this module's proofs.
//
// Jasper's `reset` takes a SIMPLE PIN constraint (compound expressions are
// rejected, ERS040) and pins it inactive for all time after initialisation. So
// `reset ~i_RSTn` makes a second reset unreachable: under that setup
// c_reset_reasserted was PROVEN UNREACHABLE in 0.00 s, which means every
// property in this effort was a statement about the post-first-reset run only,
// and any defect needing a mid-operation reset was invisible. The only way to
// keep i_RSTn free is a level above the DUT; driving it from
// (i_init_RSTn & i_RSTn) moves the pinning onto i_init_RSTn instead.
//
// It lives in this file rather than its own because bind/ is already the
// per-module formal glue. The bind above is unaffected: it targets the module
// TYPE, so it still attaches to u_dut, and property leaf names do not change.
module hwpq_rst_systolic_array #(
    parameter int QUEUE_SIZE = 8,
    parameter int DATA_WIDTH = 3
) (
    input  logic                  i_CLK,
    input  logic                  i_init_RSTn,
    input  logic                  i_RSTn,
    input  logic                  i_wrt,
    input  logic                  i_read,
    input  logic [DATA_WIDTH-1:0] i_data,
    output logic                  o_write_ready,
    output logic                  o_read_ready,
    output logic [DATA_WIDTH-1:0] o_data
);
  systolic_array #(
      .QUEUE_SIZE(QUEUE_SIZE), .DATA_WIDTH(DATA_WIDTH)
  ) u_dut (
      .i_CLK(i_CLK), .i_RSTn(i_init_RSTn & i_RSTn),
      .i_wrt(i_wrt), .i_read(i_read), .i_data(i_data),
      .o_write_ready(o_write_ready), .o_read_ready(o_read_ready), .o_data(o_data)
  );
endmodule
