`default_nettype none
// bram_tree_pipelined shim for the shared testbench body (test/common/hwpq_tb_common.svh).
//
// bram_tree_pipelined uses the standard settle contract. It did not always: while
// o_read_ready exposed root_done, which rises one walk earlier than sift_done,
// OR-ing it into settled released the next command mid-sift and the DUT dropped
// it, so this shim used `settled = o_write_ready` alone. o_read_ready is now
// gated on sift_done in the RTL, so the shared form is correct here.
module bram_tree_pipelined_tb;
  localparam int QUEUE_SIZE = 15;
  localparam int DATA_WIDTH = 16;
  localparam bit ENQ_ENA    = 0;

  // o_write_ready == sift_done here (no enqueue path, so it never advertises full);
  // skip the ENQ_ENA=0 program's "!o_write_ready == full" post-fill check.
  `define TB_TRACKS_FULL 0

  `include "hwpq_tb_common.svh"

  bram_tree_pipelined #(
      .QUEUE_SIZE(QUEUE_SIZE),
      .DATA_WIDTH(DATA_WIDTH)
  ) u_dut (
      .i_CLK(i_CLK),
      .i_RSTn(i_RSTn),
      .i_wrt(i_wrt),
      .i_read(i_read),
      .i_data(i_data),
      .o_write_ready(o_write_ready),
      .o_read_ready(o_read_ready),
      .o_data(o_data)
  );

  assign settled = o_write_ready || o_read_ready;
endmodule
