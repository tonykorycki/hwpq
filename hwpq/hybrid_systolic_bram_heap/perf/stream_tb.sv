// Streamed profiler: N back-to-back enqueues (fill), N dequeues (drain), a refill, then N
// replaces. Prints cycles per op for each phase; costs are counted as in mix_tb.
`timescale 1ns/1ps
import bram_tree_pkg::*;
module stream_tb;
  int sd = 0; initial if ($value$plusargs("seed=%d", sd)) repeat (sd) void'($urandom);
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

  int c; longint tot;
  initial begin
    #1; repeat (4) @(negedge clk); rstn = 1;
    while (!wrdy) @(negedge clk);
    @(negedge clk);
    tot = 0; for (int i = 0; i < `N; i++) begin op(1, 0, c); tot += c; end
    $display("PROF fill    %0d ops  %.2f cycles/op", `N, real'(tot) / `N);
    tot = 0; for (int i = 0; i < `N; i++) begin op(0, 1, c); tot += c; end
    $display("PROF drain   %0d ops  %.2f cycles/op", `N, real'(tot) / `N);
    for (int i = 0; i < `N; i++) op(1, 0, c);
    tot = 0; for (int i = 0; i < `N; i++) begin op(1, 1, c); tot += c; end
    $display("PROF replace %0d ops  %.2f cycles/op", `N, real'(tot) / `N);
    $finish;
  end
  initial begin #100000000; $display("PROF TIMEOUT"); $finish; end
endmodule
