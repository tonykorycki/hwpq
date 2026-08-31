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

  `define TB_CHECK_INTERNAL check_tree_invariants(); check_deep_heap();

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
  // SIMULATION.md recommendation 4, the BRAM follow-up.
  //
  // The top two levels of this design are registers rather than memory, so the
  // interesting invariants are reachable without decoding the RAM. All three are
  // transcribed verbatim from formal/spec/hwpq_bram_aux.sv, where they are
  // proven, and all three are gated on sift_done exactly as the properties are --
  // the walk is mid-flight otherwise, and F-17 was a whole retracted finding
  // caused by a window that opened one cycle too early.
  //
  // Nothing here is invented for simulation. The heap invariant over the deeper
  // levels lives in the BRAM and is deliberately left out: it is not proven for
  // this module, and an unproven interior check is how false findings get made.
  task automatic check_tree_invariants();
    if (u_dut.sift_done) begin
      // a_queue_size_bounded
      assert (u_dut.queue_size <= QUEUE_SIZE)
      else begin error_count++; $error("Occupancy: queue_size=%0d exceeds QUEUE_SIZE=%0d",
                                       u_dut.queue_size, QUEUE_SIZE); end

      // a_root_outranks_children
      assert (u_dut.level_0 >= u_dut.level_1[0] && u_dut.level_0 >= u_dut.level_1[1])
      else begin error_count++; $error("Heap: root %d outranked by children {%d, %d}",
                                       u_dut.level_0, u_dut.level_1[0], u_dut.level_1[1]); end

      // a_no_placeholder_at_capacity -- every placeholder has been evicted by the
      // time the queue is full, so the root holds real data there.
      if (u_dut.queue_size == QUEUE_SIZE)
        assert (u_dut.level_0 !== '1)
        else begin error_count++; $error("Placeholder: root still holds the '1 placeholder at capacity"); end
    end
  endtask

  // The heap invariant over the WHOLE tree, including the BRAM levels.
  //
  // NOT proven for this module, and that is precisely why it belongs here.
  // Formal reaches this design only at QUEUE_SIZE=7 -- TREE_DEPTH=3, exactly one
  // BRAM level, so a defect needing two levels is out of scope -- and 15 does
  // not converge at all (F-18). It also runs at DATA_WIDTH=2, where ordering
  // properties cannot distinguish degrees among three or more payloads. This
  // testbench runs QUEUE_SIZE=15 and DATA_WIDTH=16: two BRAM levels and a real
  // payload alphabet. That region is unreachable by proof by construction, so
  // simulation is the only thing that can cover it -- the division of labour
  // SIMULATION.md sets out.
  //
  // LAYOUT, read off the RTL. Levels 0 and 1 are registers (level_0, level_1[2]);
  // levels 2..TREE_DEPTH-1 are one rams_tdp_rf_rf per level in the gen_bram
  // generate loop, each indexed by the node's index WITHIN its level. Children of
  // (L, i) are (L+1, 2i) and (L+1, 2i+1) -- confirmed by next_addr_a[2] =
  // 2*parent_idx at :324. The word is a bare value, no active flag: '1 is the
  // max-priority placeholder and outranks everything, so it sits at the top and
  // the invariant holds through the fill phase too.
  //
  // A hierarchical reference into gen_bram[] needs a CONSTANT index, so the
  // levels are flattened into one array by a generate loop and the walk reads
  // the copy.
  //
  // Gated on sift_done && !filling, matching the proven properties above. F-17
  // was a whole retracted finding caused by a window that opened inside the
  // reset sweep, and sift_done resets HIGH, so !filling is load-bearing here.
  localparam int BTP_TREE_DEPTH = $clog2(QUEUE_SIZE + 1);
  localparam int BTP_MAX_LVL_N  = 1 << (BTP_TREE_DEPTH - 1);

  logic [DATA_WIDTH-1:0] btp_node [BTP_TREE_DEPTH][BTP_MAX_LVL_N];

  assign btp_node[0][0] = u_dut.level_0;
  assign btp_node[1][0] = u_dut.level_1[0];
  assign btp_node[1][1] = u_dut.level_1[1];

  genvar gl, gi;
  generate
    for (gl = 2; gl < BTP_TREE_DEPTH; gl = gl + 1) begin : g_lvl
      for (gi = 0; gi < (1 << gl); gi = gi + 1) begin : g_idx
        assign btp_node[gl][gi] = u_dut.gen_bram[gl].bram_inst.ram[gi];
      end
    end
  endgenerate

  task automatic check_deep_heap();
    if (u_dut.sift_done && !u_dut.filling) begin
      for (int lvl = 0; lvl < BTP_TREE_DEPTH - 1; lvl++) begin
        for (int idx = 0; idx < (1 << lvl); idx++) begin
          assert (btp_node[lvl][idx] >= btp_node[lvl+1][2*idx])
          else begin error_count++; $error("Heap: node (%0d,%0d)=%d outranked by left child (%0d,%0d)=%d",
                                           lvl, idx, btp_node[lvl][idx], lvl+1, 2*idx, btp_node[lvl+1][2*idx]); end
          assert (btp_node[lvl][idx] >= btp_node[lvl+1][2*idx+1])
          else begin error_count++; $error("Heap: node (%0d,%0d)=%d outranked by right child (%0d,%0d)=%d",
                                           lvl, idx, btp_node[lvl][idx], lvl+1, 2*idx+1, btp_node[lvl+1][2*idx+1]); end
        end
      end
    end
  endtask

endmodule
