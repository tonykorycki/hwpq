// Equal-mix cycle profiler for hybrid_systolic_heap: N enqueues, then M ops drawn 1/3 each
// enqueue, dequeue and replace. Prints mean cycles per op and the dequeue cost split by the op
// before it (RESULT), and what each cycle a read waits is waiting on, per read and split by the
// op before it (WAIT_after_<op>), all as key=value pairs. Run by equal_mix.sh.
//
// An op's cost is the cycles it is presented until accepted: it is driven at a negedge, its ready
// is sampled 1 ns later, and the DUT accepts it at the next posedge. A stall is charged to the op
// that waits on it, and the next op is driven in the cycle after an acceptance.
//
//   N, M, CAP   fill depth, measured op count, and capacity (all required)
//   MONO=1/-1   each value >= / <= the one before, in steps of 0 to STEP (3); otherwise uniform
// Run with +seed=<n> to pick the random sequence.
`timescale 1ns/1ps
import bram_tree_pkg::*;
module equal_mix_tb;
`ifndef STEP
  `define STEP 3
`endif
  int seed = 0;
  initial if ($value$plusargs("seed=%d", seed)) repeat (seed) void'($urandom);

  logic                  clk = 0, rstn = 0, wrt = 0, rd = 0;
  logic [DATA_WIDTH-1:0] din = 0;
  wire                   wrdy, rrdy;
  wire  [DATA_WIDTH-1:0] dout;
  always #5 clk = ~clk;

  hybrid_systolic_heap dut (
    .i_CLK(clk), .i_RSTn(rstn), .i_wrt(wrt), .i_read(rd), .i_data(din),
    .o_write_ready(wrdy), .o_read_ready(rrdy), .o_data(dout));

  typedef enum int {ENQ = 0, DEQ = 1, REP = 2} op_t;

  // Never the reserved all-zeros or all-ones.
  logic [DATA_WIDTH-1:0] last_value = {2'b01, {(DATA_WIDTH - 2){1'b0}}};
  function automatic logic [DATA_WIDTH-1:0] next_value();
    logic [DATA_WIDTH-1:0] v;
`ifdef MONO
    if (`MONO > 0) last_value = last_value + $urandom_range(0, `STEP);
    else           last_value = last_value - $urandom_range(0, `STEP);
    v = last_value;
`else
    v = {4{$urandom}};
`endif
    if (v == 0 || &v) v = 1;
    return v;
  endfunction

  task automatic run_op(input op_t kind, output int cycles);
    logic accepted;
    wrt = (kind != DEQ);
    rd  = (kind != ENQ);
    din = next_value();
    cycles   = 0;
    accepted = 0;
    while (!accepted) begin
      #1;
      accepted = rd ? rrdy : wrdy;
      cycles++;
      @(posedge clk); @(negedge clk);
    end
    wrt = 0;
    rd  = 0;
  endtask

  longint total [3], count [3];
  longint deq_total [3], deq_count [3];  // dequeues, by the op before them
  longint reads_after [3];                // dequeues and replaces, by the op before them
  op_t    prev = ENQ;
  logic   measuring = 0;

  // Why a read waits: first match wins, in the order of the terms of the read-ready decode.
  localparam int N_CAUSES = 7;
  function automatic string cause_name(int c);
    case (c)
      0: return "own_buffer_settling";
      1: return "other_buffer_settling";
      2: return "input_slot_busy";
      3: return "tree_top_moving";
      4: return "tree_max_above_head_tree_busy";
      5: return "tree_max_above_head_tree_idle";
      default: return "other";
    endcase
  endfunction

  function automatic int cause();
    logic from_heap;
    from_heap = dut.output_from_heap_systolic;
    if (from_heap ? dut.h_dequeue_pending : dut.m_dequeue_pending) return 0;
    if (from_heap ? !(dut.systolic_empty || dut.m_rd_rdy)
                  : !(dut.heap_systolic_empty || dut.h_rd_rdy))     return 1;
    if (!(from_heap ? dut.h_ib0_free : dut.m_ib0_free))             return 2;
    if (dut.top_moved_rd)                                           return 3;
    if (!(from_heap ? dut.h_ge_max : dut.m_ge_max))
      return dut.heap_ready[dut.max_idx_q] ? 5 : 4;
    return 6;
  endfunction

  longint waits [3][N_CAUSES];  // [op before][cause]
  // Sampled after run_op's own sample point, while the op is still on the pins.
  always @(negedge clk) begin
    #2;
    if (measuring && rd && !rrdy) waits[prev][cause()]++;
  end

  initial begin
    op_t kind;
    int  cycles, occupancy;

    // Reset, then wait out the tree memory initialisation, during which no command is accepted.
    #1;
    repeat (4) @(negedge clk);
    rstn = 1;
    while (!wrdy) @(negedge clk);
    @(negedge clk);

    for (int i = 0; i < `N; i++) run_op(ENQ, cycles);
    occupancy = `N;
    measuring = 1;
    for (int i = 0; i < `M; i++) begin
      kind = op_t'($urandom_range(0, 2));
      // At full an enqueue becomes a replace and at empty a read becomes an enqueue, so no op
      // waits on a ready that cannot rise. Only a small queue reaches either bound.
      if (kind == ENQ && occupancy == `CAP) kind = REP;
      if (kind != ENQ && occupancy == 0) kind = ENQ;
      occupancy += (kind == ENQ) - (kind == DEQ);
      run_op(kind, cycles);
      total[kind] += cycles;
      count[kind]++;
      if (kind == DEQ) begin
        deq_total[prev] += cycles;
        deq_count[prev]++;
      end
      if (kind != ENQ) reads_after[prev]++;
      prev = kind;
    end
    measuring = 0;

    $display("RESULT enq=%.4f deq=%.4f rep=%.4f overall=%.4f",
             real'(total[ENQ]) / count[ENQ], real'(total[DEQ]) / count[DEQ],
             real'(total[REP]) / count[REP], real'(total[ENQ] + total[DEQ] + total[REP]) / `M);
    $display("RESULT deq_after_enq=%.4f deq_after_deq=%.4f deq_after_rep=%.4f",
             real'(deq_total[ENQ]) / deq_count[ENQ], real'(deq_total[DEQ]) / deq_count[DEQ],
             real'(deq_total[REP]) / deq_count[REP]);
    for (int p = 0; p < 3; p++) begin
      $write("WAIT_after_%s", p == ENQ ? "enq" : (p == DEQ ? "deq" : "rep"));
      for (int c = 0; c < N_CAUSES; c++)
        $write(" %s=%.4f", cause_name(c), real'(waits[p][c]) / reads_after[p]);
      $write("\n");
    end
    $finish;
  end

  initial begin
    #100000000;
    $fatal(1, "TIMEOUT");
  end
endmodule
