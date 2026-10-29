// Mixed-load profiler: N enqueues, then M ops, each a dequeue with probability 1/RATIO and an
// enqueue otherwise. Prints cycles per op by type and percentiles of the dequeue cost.
// An op's cost is the cycles it is presented until accepted, so a stall is charged to the op
// that waits on it. The master issues the next op in the cycle after an acceptance.
`timescale 1ns/1ps
import bram_tree_pkg::*;
module mix_tb;
`ifndef RATIO
  `define RATIO 6
`endif
  int sd = 0; initial if ($value$plusargs("seed=%d", sd)) repeat (sd) void'($urandom);
  int hist [0:255]; initial for (int k = 0; k < 256; k++) hist[k] = 0;
  logic clk = 0, rstn = 0, wrt = 0, rd = 0;
  logic [DATA_WIDTH-1:0] din = 0;
  wire wrdy, rrdy; wire [DATA_WIDTH-1:0] dout;
  always #5 clk = ~clk;

  hybrid_systolic_heap dut (.i_CLK(clk), .i_RSTn(rstn), .i_wrt(wrt), .i_read(rd), .i_data(din),
    .o_write_ready(wrdy), .o_read_ready(rrdy), .o_data(dout));

  // Never the reserved all-zeros or all-ones.
  function automatic logic [DATA_WIDTH-1:0] rnd();
    logic [DATA_WIDTH-1:0] v;
    v = {4{$urandom}};
    if (v == 0 || &v) v = 1;
    return v;
  endfunction

  // Drive at the negedge, sample the ready 1 ns later; the DUT accepts at the next posedge.
  task automatic op(input logic w, input logic r, output int cyc);
    logic ok;
    cyc = 0;
    wrt = w; rd = r; din = rnd();
    ok = 0;
    while (!ok) begin
      #1;
      ok = (w && r) ? rrdy : (r ? rrdy : wrdy);
      cyc++;
      @(posedge clk); @(negedge clk);
    end
    wrt = 0; rd = 0;
  endtask

  int c;
  initial begin
    #1; repeat (4) @(negedge clk); rstn = 1;
    // The tree memory initialises after reset; no command is accepted until it is done.
    while (!wrdy) @(negedge clk);
    @(negedge clk);
    for (int i = 0; i < `N; i++) op(1, 0, c);
    begin
      longint tw, tr, nw, nr; tw = 0; tr = 0; nw = 0; nr = 0;
      for (int i = 0; i < `M; i++) begin
        if ($urandom_range(0, `RATIO - 1) == 0) begin
          op(0, 1, c); tr += c; nr++; hist[c > 255 ? 255 : c]++;
        end else begin
          op(1, 0, c); tw += c; nw++;
        end
      end
      $display("PROF mix from depth %0d: %0d ops, %.3f cycles/op overall | enq %.2f (n=%0d) | read %.2f (n=%0d)",
               `N, `M, real'(tw + tr) / `M, real'(tw) / nw, nw, real'(tr) / nr, nr);
      begin
        longint acc; int p50, p90, p99, mx; acc = 0; p50 = -1; p90 = -1; p99 = -1; mx = 0;
        for (int k = 0; k < 256; k++) if (hist[k]) begin
          mx = k; acc += hist[k];
          if (p50 < 0 && acc * 2 >= nr) p50 = k;
          if (p90 < 0 && acc * 10 >= nr * 9) p90 = k;
          if (p99 < 0 && acc * 100 >= nr * 99) p99 = k;
        end
        $display("HIST read cycles p50 %0d p90 %0d p99 %0d max %0d", p50, p90, p99, mx);
      end
    end
    $finish;
  end
  initial begin #100000000; $display("PROF TIMEOUT"); $finish; end
endmodule
