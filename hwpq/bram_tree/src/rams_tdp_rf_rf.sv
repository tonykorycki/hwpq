// Dual-Port Block RAM with Two Write Ports
// File: rams_tdp_rf_rf.v
//
// Parameterized 2026-08-30 alongside bram_tree. It used to `import bram_tree_pkg`
// for its widths and carry bram_tree_mem_t on its ports; once QUEUE_SIZE and
// DATA_WIDTH became module parameters the struct became module-local, so this
// model takes plain packed vectors and is told the field widths it needs.
//
// CAP_WIDTH is needed only by the power-up fill below, which has to place the
// per-node capacity in the low field of the word.

(* ram_style = "block"*)
module rams_tdp_rf_rf #(
    parameter integer WIDTH     = 20,  // full word width, i.e. $bits(bram_tree_mem_t)
    parameter integer DEPTH     = 7,   // NODES_NEEDED
    parameter integer CAP_WIDTH = 3    // width of the capacity field, i.e. ADDRESS_WIDTH
) (
    input logic clka,
    input logic ena,
    input logic wea,
    input logic [$clog2(DEPTH)-1:0] addra,
    input logic [WIDTH-1:0] dia,
    output logic [WIDTH-1:0] doa,
    input logic clkb,
    input logic enb,
    input logic web,
    input logic [$clog2(DEPTH)-1:0] addrb,
    input logic [WIDTH-1:0] dib,
    output logic [WIDTH-1:0] dob
);
  logic [WIDTH-1:0] ram [DEPTH-1:0];

  // Power-up contents: every node inactive, value zero, capacity set to the size
  // of the subtree it roots. SIMULATION ONLY -- synthesis takes this as a
  // bitstream init value and a formal tool ignores it outright (VERI-1060), so
  // nothing restores it on a reset. The high (WIDTH-CAP_WIDTH) bits are the
  // `active` flag and the value field, both zero.
  initial begin
    int level;
    int node_capacity;
    for (int i = 0; i < DEPTH; i++) begin
      level         = $clog2(i + 2) - 1;
      node_capacity = ((DEPTH + 1) >> level) - 1;
      ram[i] = {{(WIDTH-CAP_WIDTH){1'b0}}, CAP_WIDTH'(node_capacity)};
    end
  end

  // Both write ports drive `ram` from a SINGLE process. Splitting them across two
  // always blocks -- as the vendor template does, and as this file used to --
  // makes every bit of the array multiply driven:
  //
  //   [WARN (VDB-1000)] rams_tdp_rf_rf.sv(53): net 'ram[6][6]' is constantly
  //                     driven from multiple places
  //   INFO (IMDS005): Number of multiple-driven bits in design: 49
  //
  // (49 = DEPTH x WIDTH at DATA_WIDTH=3, i.e. all of it.) Simulation is
  // unaffected, because the two ports write different addresses and the
  // non-blocking assignments land on different elements. A formal tool has to
  // resolve the drivers instead, and the result is that writes are not reliably
  // observable in the array -- a write to address 0 need not be there on the next
  // cycle. Every memory-dependent property would be proved against that.
  //
  // This is the same defect as F-21, in bram_tree's own copy of the file. It is
  // fixed here the same way: merging is sound because bram_tree ties clka and
  // clkb to i_CLK, and a genuinely dual-clock instance would need a different
  // model. The read paths stay per-port and per-clock, and read-first ordering is
  // preserved -- the outputs still sample `ram` before this cycle's writes land,
  // because every assignment here is non-blocking.
  always @(posedge clka) begin
    if (ena && wea) ram[addra] <= dia;
    if (enb && web) ram[addrb] <= dib;
  end

  always @(posedge clka) begin
    if (ena) doa <= ram[addra];
  end

  always @(posedge clkb) begin
    if (enb) dob <= ram[addrb];
  end

endmodule
