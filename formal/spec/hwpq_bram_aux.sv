// White-box addendum for bram_tree_pipelined.
//
// The portable spec (hwpq_spec.sv) binds to this module unchanged and says
// everything it can from the six-port interface. Three things it cannot see live
// here, all of them below the port list:
//
//   1. CH-6 -- the BRAM contents at power-up. Jasper ignores the `initial` block
//      in rams_tdp_rf_rf.sv (VERI-1060: 'initial' construct is ignored), so the
//      memories start ARBITRARY and every ordering property would fail for
//      reasons that say nothing about the design. The all-ones fill is assumed
//      for cycle 0 ONLY, by `assume -bound 1` in the tcl -- see the CH-6 note
//      below for why it cannot live here.
//
//   2. Whether a later reset restores that fill. It does not: bram_seq resets
//      level_0 and level_1 but nothing rewrites the BRAMs. That is the reset
//      defect, and a_reset_restores_fill is written to fail on it rather than to
//      be assumed away.
//
//   3. Whether the out-of-range index expressions Jasper warns about are ever
//      actually reached. Elaboration only says "this MIGHT lead to an
//      out-of-bound access" (VERI-9005, ten sites); the a_*_index_in_range
//      properties decide it.
//
// It binds to the RESET HARNESS rather than to bram_tree_pipelined, because
// distinguishing the first reset from a later one needs i_init_RSTn, which only
// exists one level up. Everything from the DUT arrives through the bind's port
// connections, in the same style as hwpq_systolic_aux.sv.
//
// Written for TREE_DEPTH=3 (QUEUE_SIZE=7), where the generate produces exactly
// one BRAM level: an unpacked-array port cannot be generated over a parameter,
// so each level would need its own port. Proof sizes are pinned per module
// anyway -- hole CH-3.

module hwpq_bram_aux #(
    parameter int QUEUE_SIZE   = 7,
    parameter int DATA_WIDTH   = 3,
    parameter int TREE_DEPTH   = 3,
    parameter int NODES_NEEDED = 7
) (
    input var logic i_CLK,
    input var logic i_init_RSTn,  // the harness reset: low only during initialisation
    input var logic i_RSTn,       // the DUT's reset: free, so it may be re-asserted

    // FSM observables
    input var logic [2:0]            state,
    input var logic [31:0]           parent_lvl,
    input var logic [2:0]            parent_idx,
    input var logic [31:0]           queue_size,
    input var logic                  sift_done,
    input var logic                  root_done,

    // interface
    input var logic                  o_write_ready,
    input var logic                  o_read_ready,
    input var logic [DATA_WIDTH-1:0] o_data,

    // the BRAM level, reached hierarchically by the bind. gen_bram runs
    // i = 2 .. TREE_DEPTH-1, so at QUEUE_SIZE=7 there is exactly one.
    input var logic [DATA_WIDTH-1:0] ram_l2 [NODES_NEEDED-1:0]
);

  // bram_tree_pipelined.sv:111-118. Mirrored rather than imported: the typedef
  // is local to the DUT and a bind cannot reach a type.
  localparam logic [2:0] ST_READ_MEM     = 3'd1;
  localparam logic [2:0] ST_COMPARE_SWAP = 3'd2;
  localparam logic [2:0] ST_WRITE_MEM    = 3'd3;

  // Does the whole memory hold the all-ones placeholder fill?
  logic fill_intact;
  always_comb begin
    fill_intact = 1'b1;
    for (int k = 0; k < NODES_NEEDED; k++) begin
      if (ram_l2[k] !== '1) fill_intact = 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // CH-6 -- the power-up fill, assumed once
  // ---------------------------------------------------------------------------
  //
  // The assumption itself is NOT here: it is `assume -bound 1 {...fill_intact}`
  // in formal/tcl/bram_tree_pipelined.tcl, because it has to apply at cycle 0 and
  // SVA cannot say that. The obvious spec-side phrasing
  //
  //     am_initial_fill : assume property (!i_init_RSTn |-> fill_intact);
  //
  // was tried first and is VACUOUS: Jasper's initial state is already
  // post-reset, so !i_init_RSTn is never true at an observed posedge and
  // am_initial_fill:precondition1 comes back UNREACHABLE. The memories stayed
  // free and ten properties failed for reasons that said nothing about the
  // design. `-bound 1` constrains cycle 0 and nothing after it, which is exactly
  // the "first reset only" scoping CH-6 needs -- a later reset stays free to
  // expose that nothing restores the fill.

  // ---------------------------------------------------------------------------
  // The reset defect
  // ---------------------------------------------------------------------------
  //
  // bram_seq (:239-256) resets parent_lvl, parent_idx, level_0, level_1 and every
  // BRAM port register -- but not the BRAM contents, and nothing else rewrites
  // them. So a reset asserted while the queue holds data leaves the memory
  // holding stale nodes while queue_size reports 0.
  //
  // Deliberately NOT disabled on !i_RSTn: the claim is about what reset itself
  // does, so the reset window is the interesting one.
  a_reset_restores_fill : assert property (@(posedge i_CLK)
      !i_RSTn |=> fill_intact);

  c_reset_with_data : cover property (@(posedge i_CLK)
      (queue_size > 0) ##1 !i_RSTn);


  // ---------------------------------------------------------------------------
  // The deepest level is reached, which is why the guards were needed
  // ---------------------------------------------------------------------------
  //
  // addr_a/b, din_a/b, dout_a/b and we_a/b are declared [2:TREE_DEPTH-1] (:57-70)
  // and eight sites indexed them at [parent_lvl+1]; Jasper warned on all of them
  // (VERI-9005) but elaborated, so the question was whether the design ever got
  // there.
  //
  // It is a COVER and not an assert, deliberately. The tempting form is
  //
  //     (state == ST_READ_MEM) && (parent_lvl > 1) |-> parent_lvl < TREE_DEPTH-1
  //
  // but that asks whether the deepest level is ever reached, which it
  // legitimately is on every walk that sifts to the bottom -- so it fails
  // whether or not the accesses are guarded, and says nothing either way. A
  // reachability assert is not a bounds check.
  //
  // This cover firing is the evidence the guards are needed: these are exactly
  // the cycles in which [parent_lvl+1] is evaluated, and without a guard that
  // index is out of range.
  c_deepest_level_walked : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      (state == ST_COMPARE_SWAP) && (parent_lvl == TREE_DEPTH - 1));

  // level_1 is two entries; parent_idx is three bits wide. This one IS a real
  // bound question -- nothing structural stops parent_idx exceeding 1 -- and it
  // proves.
  a_level1_index_in_range : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      (parent_lvl == 1) |-> parent_idx < 2);

  // ---------------------------------------------------------------------------
  // What o_write_ready actually means here
  // ---------------------------------------------------------------------------
  //
  // The module has no enqueue datapath at all, and no command it accepts has
  // fullness as a precondition -- a replace on a populated queue is size-neutral.
  // So o_write_ready is a QUIESCENCE signal wearing a capacity signal's name,
  // forced to exist by the shared six-port interface. The spec binds with
  // HAS_FULL=0 for exactly this reason; stating it here is what stops that
  // parameter from being an unexamined inheritance (F-10).
  a_wready_is_quiescence : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      o_write_ready == sift_done);

  // ---------------------------------------------------------------------------
  // Covers that HAS_FULL=0 drops from the portable spec
  // ---------------------------------------------------------------------------
  //
  // g_full_covers is gated on HAS_FULL, so c_reaches_full and c_deq_from_full do
  // not exist in this build. The states are still reachable and still worth
  // demonstrating, so they are recovered here against queue_size directly rather
  // than against a fullness the port never advertises.
  c_reaches_capacity : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      sift_done && (queue_size == QUEUE_SIZE));

  c_deq_from_capacity : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      (sift_done && (queue_size == QUEUE_SIZE)) ##[1:$] (sift_done && (queue_size < QUEUE_SIZE)));

  // root_done really does lead sift_done, which is the premise of the
  // ready/accept finding below.
  c_root_before_sift : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      root_done && !sift_done);

  // ---------------------------------------------------------------------------
  // The advertised read the module then refuses
  // ---------------------------------------------------------------------------
  //
  // o_read_ready is (queue_size != 0) && root_done (:483) but cmd_dequeue needs
  // sift_done (:465). root_done rises on the root write-back, the FIRST of the
  // walk, so between the two the module advertises a read and silently discards
  // the i_read it receives.
  a_read_ready_is_acceptable : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      o_read_ready |-> sift_done);

endmodule
