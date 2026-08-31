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
    input var logic                  filling,    // the post-reset placeholder sweep
    input var logic                  cmd_replace,

    // interface
    input var logic                  o_write_ready,
    input var logic                  o_read_ready,
    input var logic [DATA_WIDTH-1:0] o_data,

    // the top two levels are registers, not memory
    input var logic [DATA_WIDTH-1:0] level_0,
    input var logic [DATA_WIDTH-1:0] level_1 [2],

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
  // bram_seq resets parent_lvl, parent_idx, level_0, level_1 and every BRAM port
  // register -- but not the BRAM contents. Nothing rewrote them, so a reset
  // asserted while the queue held data left the memory holding stale nodes while
  // queue_size reported 0. Fixed by the reset fill sequencer (`filling`).
  //
  // THE ORIGINAL FORM OF THIS PROPERTY WAS UNSATISFIABLE. It read
  //
  //     a_reset_restores_fill : !i_RSTn |=> fill_intact;
  //
  // which demands the whole memory read all-ones ONE cycle after reset asserts --
  // a single-cycle bulk clear that no BRAM can do. It named a real defect and
  // could not have gone green against any correct implementation; see F-20. The
  // achievable contract is that the sweep has finished before the module will
  // take a command, which is what these two say together.
  a_reset_restores_fill : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      $fell(filling) |-> fill_intact);

  // ...and nothing may be accepted until it has.
  a_no_ready_while_filling : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      filling |-> !o_write_ready && !o_read_ready);

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
  //
  // The right-hand side gained `&& !filling` with the reset fix: the port now
  // means quiescent AND initialised. Both terms belong in it -- the design decodes
  // commands off exactly this expression, so writing the property against anything
  // narrower would reopen the ready/accept gap that F-7 records.
  a_wready_is_quiescence : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      o_write_ready == (sift_done && !filling));

  // ---------------------------------------------------------------------------
  // Covers that HAS_FULL=0 drops from the portable spec
  // ---------------------------------------------------------------------------
  //
  // g_full_covers is gated on HAS_FULL, so c_reaches_full and c_deq_from_full do
  // not exist in this build. The states are still reachable and still worth
  // demonstrating, so they are recovered here against queue_size directly rather
  // than against a fullness the port never advertises.
  // These replace c_reaches_full and c_deq_from_full, which g_full_covers drops
  // because HAS_FULL=0 -- but deliberately NOT at full depth.
  //
  // The natural form, "sift_done && queue_size == QUEUE_SIZE", needs seven
  // replaces at up to fourteen cycles each: roughly a hundred cycles of bounded
  // reachability, against a deepest witness of twenty-one anywhere else in this
  // suite. Written that way it does not converge at all rather than converging
  // slowly -- two runs were killed, one after 4.7 hours. A cover whose witness is
  // out of reach is not evidence; it is a hang.
  //
  // So the shallow form is proved here and the deep one is left to simulation,
  // which fills the queue every run and reports the cycles/op it took. That
  // division is worth stating: formal decides invariants over every reachable
  // state, simulation demonstrates that specific deep states are reached.
  c_occupancy_grows : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      sift_done && (queue_size > 1));

  // The window is 20, not 6. A dequeue on this module takes 6 to 18 cycles
  // (simulation measures min 6, mean 9.5, max 18), so 6 cannot span one. It was
  // nonetheless REACHABLE until the RAM model was fixed, because a multiply-driven
  // memory let queue_size move along paths the real design has not got -- see
  // F-21. The bound was measured against that model and inherited its error.
  c_occupancy_shrinks : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      sift_done && (queue_size > 1) ##[1:20] (sift_done && (queue_size == 1)));

  // root_done really does lead sift_done, which is the premise of the
  // ready/accept finding below.
  c_root_before_sift : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      root_done && !sift_done);

  // ---------------------------------------------------------------------------
  // Is the DESIGN wrong, or is the spec's model of it wrong?
  // ---------------------------------------------------------------------------
  //
  // Six portable-spec properties fail together: a_occ_bounded, a_occ_empty_agrees,
  // a_no_loss, a_head_is_max, a_head_present and a_head_not_placeholder. That is
  // either one cause or six, and the spec cannot tell which, because everything it
  // knows comes through the same six ports.
  //
  // F-7 is the precedent: four spec asserts failed on systolic_array and the cause
  // turned out to be the SPEC undercounting, not the design misbehaving. The way
  // that was settled was to state the same claims white-box, against the design's
  // own signals, and see which version survives.

  // Occupancy, asked of the design's own counter rather than of the spec's model.
  // If this proves while a_occ_bounded fails, the spec is miscounting this
  // module's replaces -- the prime suspect being the o_data == '1 eviction arm
  // (:420), which has no full guard and which the spec scores as an insert every
  // time a placeholder reaches the root.
  a_queue_size_bounded : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      sift_done |-> queue_size <= QUEUE_SIZE);

  // The heap property at the top of the tree, stated locally. a_head_is_max is a
  // claim about the whole queue reconstructed from the interface; this is the
  // design's own invariant. If this proves while a_head_is_max fails, the ordering
  // is sound and the spec's reconstruction is not.
  a_root_outranks_children : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      sift_done |-> (level_0 >= level_1[0]) && (level_0 >= level_1[1]));

  // A placeholder at the root is the ORDINARY fill mechanism -- all-ones is the
  // maximum, so it floats to the root and each replace evicts one. This cover
  // therefore fires on every normal fill and proves nothing on its own. It is kept
  // only as the baseline for the one below it.
  c_root_placeholder_nonempty : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      sift_done && (queue_size > 0) && (level_0 == '1));

  // Every placeholder has been evicted by the time the queue is full, so the root
  // holds real data there. This was a COVER while the state looked reachable, and
  // it was -- but only against the multiply-driven RAM model, which let Jasper
  // choose memory contents (F-21). On a sound model the state cannot occur, so the
  // knowledge is kept as the invariant it actually is rather than deleted.
  a_no_placeholder_at_capacity : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      sift_done && (queue_size == QUEUE_SIZE) |-> level_0 != '1);

  // ---------------------------------------------------------------------------
  // Conservation -- which side of the disagreement is wrong
  // ---------------------------------------------------------------------------
  //
  // c_placeholder_at_capacity is reachable and a_queue_size_bounded proves, so the
  // counter and the contents disagree without the counter ever exceeding its
  // bound. That leaves two candidates and the covers cannot separate them: either
  // the sift network duplicates or drops a node, or the counter moves when the
  // contents do not. These two properties decide it by direction.
  //
  // Both sentinels mark a free slot -- '1 is the reset placeholder and '0 is what
  // DEQUEUE writes into the root (:410) -- and neither is a legal payload
  // (am_payload_legal), so the node count holding real data is exactly QUEUE_SIZE
  // minus the free ones. At TREE_DEPTH=3 the tree is level_0, level_1[0..1] and
  // four level-2 nodes.
  localparam int L2_NODES = 2 ** (TREE_DEPTH - 1);

  logic [3:0] occupied;
  always_comb begin
    occupied = '0;
    if (level_0    != '1 && level_0    != '0) occupied = occupied + 1;
    if (level_1[0] != '1 && level_1[0] != '0) occupied = occupied + 1;
    if (level_1[1] != '1 && level_1[1] != '0) occupied = occupied + 1;
    for (int k = 0; k < L2_NODES; k++)
      if (ram_l2[k] != '1 && ram_l2[k] != '0) occupied = occupied + 1;
  end

  // SAMPLING POINT. Not sift_done, which is a cycle too early to read the tree.
  // addr/din/we are registered from their next_* forms (:264-268), so a level-2
  // write reaches the memory two cycles after WRITE_MEM, while level_0 and
  // level_1 land after one -- and sift_done, registered the same way, rises in
  // between. Sampled on sift_done alone both properties below fail in BOTH
  // directions at 13 and 15 cycles, which is the register/memory skew and not a
  // defect. Three consecutive quiet cycles put every write in the memory.
  // Delayed explicitly rather than with $past, which needs a clocking context a
  // continuous assign does not have (VERI-1841).
  logic sift_done_d1, sift_done_d2;
  always_ff @(posedge i_CLK or negedge i_RSTn) begin
    if (!i_RSTn) begin
      sift_done_d1 <= 1'b0;
      sift_done_d2 <= 1'b0;
    end else begin
      sift_done_d1 <= sift_done;
      sift_done_d2 <= sift_done_d1;
    end
  end
  wire quiesced = sift_done && sift_done_d1 && sift_done_d2;

  // Vacuity guard: the window has to be reachable with the queue non-trivial, or
  // both properties below prove by never being evaluated.
  c_quiesced_nonempty : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      quiesced && (queue_size > 1));

  // The replace-over-empty-marker case, which counts CORRECTLY. Worth stating
  // because it looks like it should not: queue_size_comb increments on
  // `o_data == '1` or on `queue_size == 0 && i_data != 0`, and neither arm mentions
  // '0, the empty marker DEQUEUE writes into the root. Reading the source suggests
  // a replace evicting a '0 adds an element and counts nothing, which is exactly
  // the shape of a_size_not_understated.
  //
  // It was written as a hypothesis to be judged by a run rather than by a reader,
  // and the run rejected it: c_replace_over_zero is reachable at 175 cycles, so a
  // replace really does evict a '0, and the increment fires anyway -- the
  // `queue_size == 0` arm covers the case that matters. Kept as a proven invariant
  // so the next reader does not re-derive the same wrong idea.
  c_replace_over_zero : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      cmd_replace && (level_0 == '0));

  a_replace_over_zero_counts : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      (cmd_replace && (level_0 == '0) && (queue_size < QUEUE_SIZE))
      |=> queue_size == $past(queue_size) + 1);

  // The counter claims more elements than the tree holds: data was dropped by the
  // sift, or an increment fired without an insert.
  a_size_not_overstated : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      quiesced |-> queue_size <= occupied);

  // The tree holds more elements than the counter claims: the sift duplicated a
  // node, or an insert fired without an increment.
  a_size_not_understated : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      quiesced |-> queue_size >= occupied);

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
