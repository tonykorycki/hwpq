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

  `define TB_CHECK_INTERNAL check_root_capacity(); check_bram_heap();

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
  // SIMULATION.md recommendation 4, the BRAM follow-up.
  //
  // This is the one interior check in the suite with a DEMONSTRATED defect class
  // behind it. F-32 -- the replace-on-empty arm computing top_level.capacity + 1,
  // which is 7 + 1 truncated to 0 in three bits -- left this module GREEN against
  // the entire black-box formal spec. All ten interface asserts passed with the
  // defect in place, because the design keeps two occupancy mechanisms and only
  // the correct one reaches the ports. No amount of port-level checking finds it.
  //
  // Transcribed verbatim from a_root_capacity_agrees in
  // formal/spec/hwpq_bram_tree_aux.sv, which is proven, so the invariant is not
  // being invented here. Sampling is gated on fsm_idle exactly as the property
  // is: the capacity field is mid-update during a descent, and a check that
  // reads it there is F-19 all over again.
  task automatic check_root_capacity();
    if (u_dut.fsm_idle)
      assert (u_dut.top_level.capacity == QUEUE_SIZE - u_dut.queue_size)
      else begin
        error_count++;
        $error("Root capacity: idle with top_level.capacity=%0d but %0d of %0d held (expected %0d)",
               u_dut.top_level.capacity, u_dut.queue_size, QUEUE_SIZE,
               QUEUE_SIZE - u_dut.queue_size);
      end
  endtask

  // The heap invariant over the node memory.
  //
  // NOT proven for this module, and that is the reason it belongs here rather
  // than a reason to leave it out. Formal reaches this design only at
  // DATA_WIDTH=2 -- two legal payloads once both sentinels are reserved, so an
  // ordering property can tell a maximum from a non-maximum but cannot
  // distinguish degrees among three or more. Simulation runs at DATA_WIDTH=16.
  // Ordering among many distinct values is exactly the region the proofs cannot
  // enter, which is what the division of labour in SIMULATION.md says the
  // testbench should own.
  //
  // LAYOUT, read off the RTL rather than assumed. bram_inst.ram is indexed by
  // heap position, children of p are 2p+1 and 2p+2, and the word is the packed
  // struct {active, value[DATA_WIDTH-1:0], capacity[ADDRESS_WIDTH-1:0]}, so the
  // active flag is the MSB. Position 0 is DEAD: the root lives in the top_level
  // register, and ram[0] only ever holds what the reset sweep wrote. Comparing
  // against ram[0] instead of top_level would be a false finding generator.
  //
  // Gated on fsm_idle, like every other check here. Mid-descent the memory is
  // half-rewritten, and a window that opens while its signals are moving is F-19.
  localparam int BT_TREE_DEPTH = $clog2(QUEUE_SIZE + 1);
  localparam int BT_NODES      = (1 << BT_TREE_DEPTH) - 1;
  localparam int BT_ADDR_W     = $clog2(BT_NODES);
  localparam int BT_MEM_W      = 1 + DATA_WIDTH + BT_ADDR_W;

  function automatic logic bt_active(input int idx);
    return u_dut.bram_inst.ram[idx][BT_MEM_W-1];
  endfunction

  function automatic logic [DATA_WIDTH-1:0] bt_value(input int idx);
    return u_dut.bram_inst.ram[idx][BT_MEM_W-2 -: DATA_WIDTH];
  endfunction

  task automatic check_bram_heap();
    int par;
    logic par_active;
    logic [DATA_WIDTH-1:0] par_value;
    if (u_dut.fsm_idle) begin
      for (int c = 1; c < BT_NODES; c++) begin
        par = (c - 1) / 2;
        // The root is the register, not ram[0].
        par_active = (par == 0) ? u_dut.top_level.active : bt_active(par);
        par_value  = (par == 0) ? u_dut.top_level.value  : bt_value(par);
        if (bt_active(c) && par_active)
          assert (par_value >= bt_value(c))
          else begin
            error_count++;
            $error("Heap: node %0d (%d) outranked by child %0d (%d)",
                   par, par_value, c, bt_value(c));
          end
      end
    end
  endtask

endmodule
