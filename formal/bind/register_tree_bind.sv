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
module hwpq_rst_register_tree #(
    parameter int QUEUE_SIZE = 7,
    parameter int DATA_WIDTH = 3,
    parameter bit ENQ_ENA    = 1
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
  register_tree #(
      .QUEUE_SIZE(QUEUE_SIZE), .DATA_WIDTH(DATA_WIDTH), .ENQ_ENA(ENQ_ENA)
  ) u_dut (
      .i_CLK(i_CLK), .i_RSTn(i_init_RSTn & i_RSTn),
      .i_wrt(i_wrt), .i_read(i_read), .i_data(i_data),
      .o_write_ready(o_write_ready), .o_read_ready(o_read_ready), .o_data(o_data)
  );
endmodule
