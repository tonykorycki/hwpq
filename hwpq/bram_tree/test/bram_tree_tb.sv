`default_nettype none
// bram_tree shim for the shared testbench body (test/common/hwpq_tb_common.svh).
// It is enqueue-capable and single-instance, so ENQ_ENA=1 selects the
// enqueue-enabled program.
//
// This shim used to import bram_tree_pkg, because the module was pkg-locked to
// one size. Now that QUEUE_SIZE and DATA_WIDTH are module parameters it supplies
// them the same way every other shim in the suite does. The values are the ones
// the package used to fix, so the run is unchanged.

module bram_tree_tb;
  localparam int QUEUE_SIZE = 7;   // must be 2^k - 1
  localparam int DATA_WIDTH = 16;
  localparam bit ENQ_ENA    = 1;

  `include "hwpq_tb_common.svh"

  bram_tree #(
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
