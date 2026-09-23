`default_nettype none

/*******************************************************************************
  Module Name: systolic_array
  Date: 2026/06/18
  Description: A priority queue implementation using a systolic array of an
               input buffer (IB) and output buffer (OB). New nodes shift
               through the IB, swapping bubble-sort style with adjacent OB
               nodes so higher-priority (larger f) values migrate into the
               OB; dequeuing the OB head propagates a "bubble" back through
               the array to refill it.
  Parameters: QUEUE_SIZE - Maximum number of elements in the priority queue
              DATA_WIDTH - Bit width of the node's evaluation value (f)
  Inputs: i_CLK - System clock
          i_RSTn - Active-low reset signal
          i_wrt - Enqueue signal
          i_read - Dequeue signal
          i_data - Node data input
  Outputs: o_full - High when the queue is at maximum capacity (QUEUE_SIZE)
           o_empty - High when the queue is empty
           o_data - Node data output (highest priority element)
*******************************************************************************/

module systolic_array #(
    parameter int QUEUE_SIZE = 4,  // Size of the buffers (number of positions)
    parameter int DATA_WIDTH = 16  // Width of the node data (evaluation function value 'f')
) (
    input var logic                   i_CLK,
    input var logic                   i_RSTn,

    // Input
    input var logic                   i_wrt,   // Enqueue signal
    input var logic                   i_read,  // Dequeue signal
    input var logic [DATA_WIDTH-1:0]  i_data,  // Node data input

    // Output
    output var logic                  o_full,   // Queue is full
    output var logic                  o_empty,  // Queue is empty
    output var logic [DATA_WIDTH-1:0] o_data    // Node data output
);

  // Constant
  localparam int MIN_VALUE = 0;  // Represents the minimum value for a max-queue
  localparam int HALF_SIZE = QUEUE_SIZE / 2;

  // Input Buffer (IB) and Output Buffer (OB)
  logic   [DATA_WIDTH-1:0] IB                  [HALF_SIZE];
  logic   [DATA_WIDTH-1:0] OB                  [HALF_SIZE];

  // Registers to store comparison results
  logic                    IB_greater_than_OB     [HALF_SIZE];
  logic                    IB_greater_than_IB_next[HALF_SIZE-1];
  logic                    IB_greater_than_OB_next[HALF_SIZE-1];
  logic                    OB_next_greater_than_OB[HALF_SIZE-1];

  // Control signals
  int                      size;
  int                      size_next;
  logic                    full;
  logic                    empty;

  assign full  = (size >= QUEUE_SIZE);
  assign empty = (size <= 0);
  assign o_full  = full;
  assign o_empty = empty;
  assign o_data  = OB[0];

  // Sequential logic
  always_ff @(posedge i_CLK or negedge i_RSTn) begin
    if (!i_RSTn) begin  // Reset
      size <= 0;
      for (int i = 0; i < HALF_SIZE; i++) begin
        IB[i] <= MIN_VALUE;  // initialize IB to MIN_VALUE, since this is a max-queue
        OB[i] <= MIN_VALUE;  // initialize OB to MIN_VALUE, since this is a max-queue
      end
    end else begin

      // Dequeue operation
      if (i_read && !i_wrt && !empty) begin
        OB[0] <= MIN_VALUE;  // pop the head of OB
      end

      // Enqueue operation
      if (i_wrt && !i_read && !full) begin
        IB[0] <= i_data;  // insert the new node at the head of IB
      end

      // Replace operation
      if (i_wrt && i_read) begin
        if (full) begin
          OB[0] <= IB[0];   // replace OB with the head of IB
          IB[0] <= i_data;  // replace the head of IB
        end else if (empty) begin
          OB[0] <= i_data;  // insert the new node at the head of OB
        end else begin
          IB[0] <= i_data;  // replace the head of IB
          OB[0] <= MIN_VALUE;  // pop the head of OB
        end
      end

      // update size
      size <= size_next;

      // Sorting logic
      for (int i = 0; i < HALF_SIZE; i++) begin  // Iterate through each element
        priority case (1'b1)
          IB_greater_than_OB[i]: begin
            IB[i] <= OB[i];
            OB[i] <= IB[i];
          end

          OB_next_greater_than_OB[i] && (!(OB_next_greater_than_OB[i+1]) || i == HALF_SIZE - 2) && (!(IB_greater_than_OB[i+1])): begin  // OB[i+1] > OB[i]
            // Swap OB[i] and OB[i+1]
            OB[i+1] <= OB[i];
            OB[i]   <= OB[i+1];
          end

          IB_greater_than_OB_next[i] && (IB[i+1] == MIN_VALUE): begin
            // Move IB[i] to OB[i+1], and move OB[i+1] to IB[i+1]
            OB[i+1] <= IB[i];
            IB[i+1] <= OB[i+1];
            IB[i]   <= MIN_VALUE;
          end

          IB_greater_than_IB_next[i] && (!(IB_greater_than_IB_next[i+1]) || i == HALF_SIZE - 2) && (!(IB_greater_than_OB[i+1])): begin  // IB[i] > IB[i+1]
            // Swap IB[i] and IB[i+1]
            IB[i+1] <= IB[i];
            IB[i]   <= IB[i+1];
          end

          default: begin
            // No action needed
          end
        endcase
      end
    end
  end

  // Combinational logic
  always_comb begin
    // comparsion results
    for (int i = 0; i < QUEUE_SIZE; i++) begin
      IB_greater_than_OB[i] = IB[i] > OB[i];
    end
    for (int i = 0; i < QUEUE_SIZE - 1; i++) begin
      IB_greater_than_OB_next[i] = IB[i] > OB[i+1];
      IB_greater_than_IB_next[i] = IB[i] > IB[i+1];
      OB_next_greater_than_OB[i] = OB[i+1] > OB[i];
    end

    // compute size_next
    if (i_wrt && !i_read && !full) begin
      size_next = size + 1;
    end else if (!i_wrt && i_read && !empty) begin
      size_next = size - 1;
    end else if (i_wrt && i_read && !full && !empty) begin
      size_next = size;
    end else if (i_wrt && i_read && full && !empty) begin
      size_next = size;
    end else if (i_wrt && i_read && !full && empty) begin
      size_next = size + 1;
    end else begin
      size_next = size;
    end

  end

endmodule
