// Attaches hwpq_spec to bram_tree
//
// Port-map explicitly rather than `.*`, and pass every parameter explicitly.
//
// This module is the OPPOSITE of bram_tree_pipelined on two of the three
// questions, so nothing here should be copied from that bind by reflex:
//
//   ENQ_ENA=1. bram_tree HAS an enqueue datapath, so both command forms are
//   live. The pipelined module is replace-only.
//
//   HAS_FULL=1. o_write_ready is (queue_size != QUEUE_SIZE) && ...
//   (bram_tree.sv:559), so !o_write_ready genuinely does mean full. The
//   pipelined module never advertises full at all.
//
//   HAS_BUSY=1 is the one they share: both readies are ANDed with a quiescence
//   term, so they drop together while the sift walk runs.
//
// MAX_SETTLE=8: TRANSCRIBED, not read from the design -- no localparam holds it,
// so unlike register_tree's SETTLE_MAX it cannot track QUEUE_SIZE if the walk
// changes. Flagged the way F-4 flags the tree timers. The structure is roughly
// two cycles per level plus accept and return, i.e. 2*TREE_DEPTH+2 = 8 at
// QUEUE_SIZE=7, and simulation measures a maximum op latency of 7 at that size
// (replace) and 7 at QUEUE_SIZE=15. Re-derive it once the run gets past the
// multiple-driver gate; it is a guess until a_progress has actually judged it.
//
// KNOWN: this bind is expected to produce a VACUOUS run once it elaborates,
// because o_write_ready and o_read_ready are ANDed with !(i_read || i_wrt)
// (bram_tree.sv:558). Fed to am_no_cmd_while_busy that reads "if a command is
// issued then no command is issued", so Jasper issues none and every assert
// proves for free. The command covers are what detect it. That is the point of
// running this before touching the readies -- the vacuity gets demonstrated
// rather than asserted in prose.
bind bram_tree hwpq_spec #(
    .QUEUE_SIZE (QUEUE_SIZE),
    .DATA_WIDTH (DATA_WIDTH),
    .ENQ_ENA    (1'b1),
    .HAS_BUSY   (1'b1),
    .MAX_SETTLE (8),
    .HAS_FULL   (1'b1),
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


// Reset harness -- the elaboration top for this module's proofs.
//
// Jasper's `reset` takes a SIMPLE PIN constraint (compound expressions are
// rejected, ERS040) and pins it inactive for all time after initialisation, so
// `reset ~i_RSTn` makes a second reset unreachable (F-14). Driving the DUT from
// (i_init_RSTn & i_RSTn) moves the pinning onto i_init_RSTn and leaves i_RSTn
// free.
//
// It matters more here than on any module so far: bram_tree's per-node capacity
// fields live in the RAM, the RAM has no reset port, and its `initial` fill is
// simulation-only -- so the reset defect this harness makes reachable is the one
// that carries the whole free-space accounting.
module hwpq_rst_bram_tree #(
    parameter int QUEUE_SIZE = 7,
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
  bram_tree #(
      .QUEUE_SIZE(QUEUE_SIZE), .DATA_WIDTH(DATA_WIDTH)
  ) u_dut (
      .i_CLK(i_CLK), .i_RSTn(i_init_RSTn & i_RSTn),
      .i_wrt(i_wrt), .i_read(i_read), .i_data(i_data),
      .o_write_ready(o_write_ready), .o_read_ready(o_read_ready), .o_data(o_data)
  );
endmodule
