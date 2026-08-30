// Attaches hwpq_spec and hwpq_tree_aux to register_tree_pipelined
//
// Port-map explicitly rather than `.*`, and pass every parameter explicitly.
//
// Same shape as register_tree: both readies gate on head_valid (:100-101), so
// HAS_BUSY=1, and head_valid is a countdown flop (:281) rather than a heap
// scan - so the timer-soundness lemma applies here too, unchanged.
//
// The timer bound differs though. register_tree takes the larger of
// CLIMB_CYCLES and SINK_CYCLES; this design uses one uniform SETTLE_CYCLES =
// TREE_DEPTH (:48), which is deeper. Reading it from the DUT's own localparam
// means the difference is picked up automatically instead of being transcribed.
//
// ASSUME_FILL_FIRST is wired the same way register_array_bind.sv and
// register_tree_bind.sv wire it. hwpq_spec.sv:152 guards the assumption on
// `!ENQ_ENA`, so it is inert in the ENQ_ENA=1 run above and this changes
// nothing there; it exists for the replace-only build, where without it F-1
// reproduces. Without the `ifdef the parameter would default to 1 and
// --ungated would silently leave the assumption ON -- green while checking
// nothing, which is the failure mode F-5 describes.
bind register_tree_pipelined hwpq_spec #(
    .QUEUE_SIZE (QUEUE_SIZE),
    .DATA_WIDTH (DATA_WIDTH),
    .ENQ_ENA    (ENQ_ENA),
    .HAS_BUSY   (1'b1),
    .MAX_SETTLE (SETTLE_CYCLES),
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

bind register_tree_pipelined hwpq_tree_aux #(
    .DATA_WIDTH  (DATA_WIDTH),
    .NODES_NEEDED(NODES_NEEDED)
) u_aux (
    .i_CLK     (i_CLK),
    .i_RSTn    (i_RSTn),
    .head_valid(head_valid),
    .queue     (queue)
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
module hwpq_rst_register_tree_pipelined #(
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
  register_tree_pipelined #(
      .QUEUE_SIZE(QUEUE_SIZE), .DATA_WIDTH(DATA_WIDTH), .ENQ_ENA(ENQ_ENA)
  ) u_dut (
      .i_CLK(i_CLK), .i_RSTn(i_init_RSTn & i_RSTn),
      .i_wrt(i_wrt), .i_read(i_read), .i_data(i_data),
      .o_write_ready(o_write_ready), .o_read_ready(o_read_ready), .o_data(o_data)
  );
endmodule
