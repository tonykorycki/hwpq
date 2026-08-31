// White-box addendum for bram_tree: the power-up contents of the node memory.
//
// WHY THIS EXISTS. The BRAM has no reset port, and the `initial` block in
// rams_tdp_rf_rf.sv that lays down the empty-tree fill is simulation-only --
// Jasper says so on every run:
//
//     [WARN (VERI-1060)] rams_tdp_rf_rf.sv(46): 'initial' construct is ignored
//
// Without an assumption the memory therefore starts ARBITRARY: arbitrary
// `active` flags, arbitrary values, and -- worst of all for this module --
// arbitrary `capacity` fields, which carry the free-space accounting the whole
// design rests on. Ordering and occupancy properties then fail for reasons that
// say nothing about the design. This is hole CH-6, in bram_tree's own instance.
//
// SCOPED TO CYCLE 0, DELIBERATELY. The tcl applies it as
//
//     assume -bound 1 {u_bram_aux.fill_intact}
//
// which constrains the first cycle and nothing after it. A LATER reset stays
// free, which is exactly what leaves the "reset does not restore the memory"
// defect reachable. An assumption phrased over every reset would hide it and
// look identical in the summary table -- that is how F-25 was found on
// bram_tree_pipelined, and the same trap is set here.
//
// It cannot be written as an SVA assume: Jasper's initial state is already
// post-reset, so an antecedent predicated on the harness reset being low is
// never true at an observed posedge and the precondition comes back UNREACHABLE
// with the memories still free.
module hwpq_bram_tree_aux #(
    parameter int QUEUE_SIZE    = 7,
    parameter int DATA_WIDTH    = 3,
    parameter int NODES_NEEDED  = 7,
    parameter int ADDRESS_WIDTH = 3,
    parameter int MEM_WIDTH     = 1 + DATA_WIDTH + ADDRESS_WIDTH
) (
    input logic                 i_CLK,
    input logic                 i_init_RSTn,
    input logic                 i_RSTn,
    input logic [MEM_WIDTH-1:0] ram [NODES_NEEDED-1:0]
);

  // The capacity a node powers up holding is the size of the subtree it roots.
  // rams_tdp_rf_rf computes it as ((DEPTH+1) >> level) - 1 with
  // level = $clog2(i+2) - 1, which for a 0-rooted heap is the node's depth,
  // floor(log2(i+1)). Computed with a shift loop rather than $clog2 because the
  // argument is not a constant here and $clog2 on a non-constant is not portable.
  function automatic int unsigned node_level(input int unsigned i);
    int unsigned n;
    int unsigned lvl;
    n   = i + 1;
    lvl = 0;
    while (n > 1) begin
      n   = n >> 1;
      lvl = lvl + 1;
    end
    return lvl;
  endfunction

  function automatic int unsigned node_capacity(input int unsigned i);
    return ((NODES_NEEDED + 1) >> node_level(i)) - 1;
  endfunction

  // The empty-tree fill: every node inactive, value zero, capacity = subtree size.
  logic fill_intact;
  always_comb begin
    fill_intact = 1'b1;
    for (int unsigned i = 0; i < NODES_NEEDED; i++) begin
      if (ram[i] != {{(MEM_WIDTH-ADDRESS_WIDTH){1'b0}},
                     ADDRESS_WIDTH'(node_capacity(i))}) begin
        fill_intact = 1'b0;
      end
    end
  end

  // Anti-vacuity: if this were never satisfiable the assume would strangle the
  // design silently and every assert would prove for free.
  c_fill_intact_reachable : cover property (@(posedge i_CLK) fill_intact);

endmodule
