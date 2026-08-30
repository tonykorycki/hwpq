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
