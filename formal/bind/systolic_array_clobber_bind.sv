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
