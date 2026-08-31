// Attaches hwpq_spec and hwpq_bram_aux to bram_tree_pipelined
//
// Port-map explicitly rather than `.*`, and pass every parameter explicitly.
//
// HAS_BUSY=1: sift_done drops for the whole walk, so both readies can be low
// together and the settle contract is real.
//
// HAS_FULL=0, CAPACITY=QUEUE_SIZE: these answer different questions and here
// they land on different answers, which is the F-10 lesson rather than the F-10
// trap. The module has no enqueue datapath at all -- the word "full" does not
// occur in the source -- and no command it accepts has fullness as a
// precondition, since a replace on a populated queue is size-neutral. So
// o_write_ready = sift_done reports quiescence and never capacity, and
// !o_write_ready genuinely does not mean full. Capacity is still QUEUE_SIZE,
// reached by evicting every placeholder, so a_occ_bounded stays meaningful.
// hwpq_bram_aux states what the port does mean (a_wready_is_quiescence) and
// recovers the two covers HAS_FULL=0 drops, so nothing goes silently missing.
//
// MAX_SETTLE=14: TRANSCRIBED, not read from the design. The structure gives
// 4*TREE_DEPTH + 2 -- four cycles per level plus accept and return -- which is 14
// at QUEUE_SIZE=7 (and 18 at the QUEUE_SIZE=15 the testbench runs, where the
// simulation log records a dequeue maximum of 18 and a minimum of 6 = 4*1 + 2).
// No localparam holds it, so unlike register_tree's
// SETTLE_MAX this number cannot track the design if the walk changes. Flagged
// the way F-4 flags the tree timers.
bind bram_tree_pipelined hwpq_spec #(
    .QUEUE_SIZE (QUEUE_SIZE),
    .DATA_WIDTH (DATA_WIDTH),
    .ENQ_ENA    (1'b0),
    .HAS_BUSY   (1'b1),
    .MAX_SETTLE (14),
    .HAS_FULL   (1'b0),
    .CAPACITY   (QUEUE_SIZE),
`ifdef HWPQ_UNGATED
    // run.sh --ungated: drop the workaround and reproduce the recorded defect.
    .ASSUME_FILL_FIRST (1'b0)
`else
    .ASSUME_FILL_FIRST (1'b1)
`endif
) u_spec (
    .i_CLK        (i_CLK),
    .i_RSTn       (i_RSTn),
    .i_wrt        (i_wrt),
    .i_read       (i_read),
    .i_data       (i_data),
    .o_write_ready(o_write_ready),
    .o_read_ready (o_read_ready),
    .o_data       (o_data)
);


// The white-box addendum binds to the HARNESS, not to the DUT: it needs
// i_init_RSTn to tell the first reset from a later one, and that only exists one
// level up. Everything from the design arrives by hierarchical reference through
// these port connections.
bind hwpq_rst_bram_tree_pipelined hwpq_bram_aux #(
    .QUEUE_SIZE   (QUEUE_SIZE),
    .DATA_WIDTH   (DATA_WIDTH),
    .TREE_DEPTH   (3),
    .NODES_NEEDED (7)
) u_bram_aux (
    .i_CLK        (i_CLK),
    .i_init_RSTn  (i_init_RSTn),
    .i_RSTn       (i_RSTn),
    .state        (u_dut.state),
    .parent_lvl   (u_dut.parent_lvl),
    .parent_idx   (u_dut.parent_idx),
    .queue_size   (u_dut.queue_size),
    .sift_done    (u_dut.sift_done),
    .root_done    (u_dut.root_done),
    .filling      (u_dut.filling),
    .cmd_replace  (u_dut.cmd_replace),
    .cmd_dequeue  (u_dut.cmd_dequeue),
    .o_write_ready(o_write_ready),
    .o_read_ready (o_read_ready),
    .o_data       (o_data),
    .level_0      (u_dut.level_0),
    .level_1      (u_dut.level_1),
    .ram_l2       (u_dut.gen_bram[2].bram_inst.ram)
);


// Reset harness -- the elaboration top for this module's proofs.
//
// Jasper's `reset` takes a SIMPLE PIN constraint (compound expressions are
// rejected, ERS040) and pins it inactive for all time after initialisation, so
// `reset ~i_RSTn` makes a second reset unreachable (F-14). Driving the DUT from
// (i_init_RSTn & i_RSTn) moves the pinning onto i_init_RSTn and leaves i_RSTn
// free. It matters more here than anywhere else: the whole reset defect this
// module is being proved for is only reachable once a second reset is.
//
// It lives in this file rather than its own because bind/ is already the
// per-module formal glue. The binds above are unaffected: the spec targets the
// module TYPE, so it still attaches to u_dut.
module hwpq_rst_bram_tree_pipelined #(
    parameter int QUEUE_SIZE = 15,
    parameter int DATA_WIDTH = 3
) (
    input  logic                  i_CLK,
    input  logic                  i_init_RSTn,
    input  logic                  i_RSTn,
    input  logic                  i_wrt,
    input  logic                  i_read,
    input  logic [DATA_WIDTH-1:0] i_data,
    output logic                  o_write_ready,
    output logic                  o_read_ready,
    output logic [DATA_WIDTH-1:0] o_data
);
  bram_tree_pipelined #(
      .QUEUE_SIZE(QUEUE_SIZE), .DATA_WIDTH(DATA_WIDTH)
  ) u_dut (
      .i_CLK(i_CLK), .i_RSTn(i_init_RSTn & i_RSTn),
      .i_wrt(i_wrt), .i_read(i_read), .i_data(i_data),
      .o_write_ready(o_write_ready), .o_read_ready(o_read_ready), .o_data(o_data)
  );
endmodule
