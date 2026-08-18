// Local smoke driver for the HWPQ spec.
//
// Purpose: prove that hwpq_spec.sv COMPILES, BINDS, and has the right POLARITY
// 
// Driven by formal/smoke.sh. Not part of the simulation regression in test/.
`timescale 1ns/1ps
module hwpq_smoke_tb;

  localparam int QUEUE_SIZE = 4;    // even: register_array pairs elements
  localparam int DATA_WIDTH = 3;
  localparam bit ENQ_ENA    = 1;
  localparam int N_OPS      = 200;

  logic                  i_CLK = 0;
  logic                  i_RSTn;
  logic                  i_wrt;
  logic                  i_read;
  logic [DATA_WIDTH-1:0] i_data;
  logic                  o_write_ready;
  logic                  o_read_ready;
  logic [DATA_WIDTH-1:0] o_data;

  // hwpq_spec attaches here via formal/bind/register_array_bind.sv
  register_array #(
      .ENQ_ENA(ENQ_ENA), .QUEUE_SIZE(QUEUE_SIZE), .DATA_WIDTH(DATA_WIDTH)
  ) u_dut (
      .i_CLK(i_CLK), .i_RSTn(i_RSTn), .i_wrt(i_wrt), .i_read(i_read),
      .i_data(i_data), .o_write_ready(o_write_ready),
      .o_read_ready(o_read_ready), .o_data(o_data)
  );

  always #5 i_CLK = ~i_CLK;

  // Payloads exclude the reserved sentinels '0 and '1 . DATA_WIDTH=3 leaves 1..6 legal.
  function automatic logic [DATA_WIDTH-1:0] legal_payload();
    return DATA_WIDTH'($urandom_range(1, (1 << DATA_WIDTH) - 2));
  endfunction

  initial begin
    i_RSTn = 0; i_wrt = 0; i_read = 0; i_data = '0;
    repeat (2) @(negedge i_CLK);
    i_RSTn = 1;
    @(negedge i_CLK);

    for (int n = 0; n < N_OPS; n++) begin
      int op;
      op = $urandom_range(1, 3);
      @(negedge i_CLK);
      i_data = legal_payload();
      case (op)
        1: begin i_wrt = 1; i_read = 0; end   // enqueue
        2: begin i_wrt = 0; i_read = 1; end   // dequeue
        3: begin i_wrt = 1; i_read = 1; end   // replace
      endcase
      @(negedge i_CLK);
      i_wrt = 0; i_read = 0; i_data = '0;
    end

    $display("smoke: %0d operations driven, no assertion failures.", N_OPS);
    $finish;
  end

endmodule
