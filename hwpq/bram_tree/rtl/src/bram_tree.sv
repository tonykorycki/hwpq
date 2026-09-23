/*******************************************************************************
  Module Name: bram_tree
  Date: 2025/03/05
  Description: A priority queue implementation using a binary max-heap structure
               stored in block RAM (BRAM). Supports enqueue, dequeue, and replace
               operations.
  Parameters: QUEUE_SIZE - Maximum number of elements in the priority queue
              DATA_WIDTH - Bit width of data elements
  Inputs: CLK - System clock
          RSTn - Active-low reset signal
          i_wrt - Write/insert command (enqueue operation)
          i_read - Read/pop command (dequeue operation)
          i_data - Input data to be enqueued
  Outputs: o_full - High when the queue is at maximum capacity (QUEUE_SIZE)
           o_empty - High when the queue is empty
           o_data - Output data from the highest priority element
*******************************************************************************/

package bram_tree_pkg;
  localparam integer DATA_WIDTH = 16;
  localparam integer QUEUE_SIZE = 7;
  localparam integer TREE_DEPTH    = $clog2(QUEUE_SIZE + 1);
  localparam integer NODES_NEEDED  = (1 << TREE_DEPTH) - 1; 
  localparam integer ADDRESS_WIDTH = $clog2(NODES_NEEDED);

  // Define your structs here so all modules can see them
  typedef struct packed {
    logic active;
    logic [DATA_WIDTH-1:0] value;
    logic [ADDRESS_WIDTH-1:0] capacity;
  } bram_tree_mem_t;

  typedef struct packed {
    logic [DATA_WIDTH-1:0] value;
    logic [ADDRESS_WIDTH-1:0] position;
    logic [ADDRESS_WIDTH-1:0] capacity;
  } bram_tree_curr_t;
endpackage

module bram_tree #(
		parameter integer QUEUE_SIZE = bram_tree_pkg::QUEUE_SIZE,
    parameter integer DATA_WIDTH = bram_tree_pkg::DATA_WIDTH
)(
    input  logic                  CLK,
    input  logic                  RSTn,
    // Inputs
    input  logic                  i_wrt,    // Write/insert command
    input  logic                  i_read,   // Read/pop command
    input  logic [DATA_WIDTH-1:0] i_data,   // Input data
    // Outputs
    output logic                  o_full,   // High if the heap is full
    output logic                  o_empty,  // High if the heap is empty
    output logic [DATA_WIDTH-1:0] o_data    // Output data (Root node)
);

  import bram_tree_pkg::*;

  typedef enum logic [3:0] {
    IDLE                       = 4'd0,
    // Enqueue 
    ENQUEUE_COMPARE_ROOT    = 4'd1,
    ENQUEUE_READ_CHILD      = 4'd2,
    ENQUEUE_COMPARE_CHILD   = 4'd3,
    // Dequeue
    DEQUEUE_READ_ROOT_CHILDREN = 4'd4,
    DEQUEUE_COMPARE_ROOT    = 4'd5,
    DEQUEUE_READ_CHILD      = 4'd6,
    DEQUEUE_COMPARE_CHILD   = 4'd7,
    // Replace
    REPLACE_READ_ROOT    = 4'd8,
    REPLACE_COMPARE_ROOT = 4'd9,
    REPLACE_READ_CHILD   = 4'd10,
    REPLACE_COMPARE_CHILD = 4'd11
  } state_t;

  // Keep track if the node is active, it's value and how much available nodes are under it
  typedef struct packed {
    logic active;
    logic [DATA_WIDTH-1:0] value;
    logic [ADDRESS_WIDTH-1:0]  capacity;
  } bram_tree_mem_t;

  // Keep track of the current node's value and position
  typedef struct packed {
    logic [DATA_WIDTH-1:0] value;
    logic [ADDRESS_WIDTH-1:0] position;
    logic [ADDRESS_WIDTH-1:0] capacity;
  } bram_tree_curr_t;

  state_t state, next_state;
  bram_tree_curr_t curr, next;
  logic [ADDRESS_WIDTH:0] parent_idx, child_idx_left, child_idx_right;
  integer queue_size, next_queue_size;
  logic ready;

  // BRAM signals
  logic [ADDRESS_WIDTH-1:0] addr_a;
  logic [ADDRESS_WIDTH-1:0] addr_b;
  bram_tree_mem_t     din_a;
  bram_tree_mem_t     din_b;
  logic                     we_a;
  logic                     we_b;
  bram_tree_mem_t     dout_a;
  bram_tree_mem_t     dout_b;

  logic [DATA_WIDTH-1:0] parent,     next_parent;
  logic [DATA_WIDTH-1:0] left_child,  next_left_child;
  logic [DATA_WIDTH-1:0] right_child, next_right_child;
  logic [DATA_WIDTH-1:0] out_reg, next_out_reg;
  logic [DATA_WIDTH-1:0] second_greatest, next_second_greatest;

  rams_tdp_rf_rf bram_inst (
    .clka (CLK), .ena(1'b1), .wea(we_a), .addra(addr_a), .dia(din_a), .doa(dout_a),
    .clkb (CLK), .enb(1'b1), .web(we_b), .addrb(addr_b), .dib(din_b), .dob(dout_b)
  );

  always_ff @(posedge CLK or negedge RSTn) begin : fsm_seq
    if (!RSTn) begin
      state         <= IDLE;
      queue_size    <= 0;
      curr          <= '0;
      parent        <= '0;
      left_child    <= '0;
      right_child   <= '0;
      out_reg       <= '0;
      second_greatest <= '0;
    end else begin
      state         <= next_state;
      queue_size    <= next_queue_size;
      curr          <= next;
      parent        <= next_parent;
      left_child    <= next_left_child;
      right_child   <= next_right_child;
      out_reg       <= next_out_reg;
      second_greatest <= next_second_greatest;
    end
  end

  always @* begin : fsm_comb
    next_state       = state;
    next_queue_size  = queue_size;
    next             = curr;
    addr_a = 1'b0;
    addr_b = 1'b0;
    din_a = '0;
    din_b = '0;
    we_a        = 1'b0;
    we_b        = 1'b0;
    next_parent      = parent;
    next_left_child  = left_child;
    next_right_child = right_child;
    next_out_reg     = out_reg;
    next_second_greatest = second_greatest;

    parent_idx = (curr.position - 1) >> 1;
    child_idx_left  = curr.position * 2 + 1;
    child_idx_right = curr.position * 2 + 2;

    case (state)
      IDLE: begin
        if (i_wrt && !i_read && !o_full) begin // --- ENQUEUE ---
          if (queue_size == 0) begin
            addr_a = 0;
            we_a = 1;

            din_a.active   = 1'b1;
            din_a.value    = i_data;
            din_a.capacity = QUEUE_SIZE - 1;

            next_out_reg = i_data;
            next_state = IDLE;
          end else begin
            next.value    = i_data;
            next.position = 0;
            next.capacity = 'x;

            addr_a = 0;
            next_state = ENQUEUE_COMPARE_ROOT;
          end
          next_queue_size = queue_size + 1;
        end else if (!i_wrt && i_read && !o_empty) begin // --- DEQUEUE ---
          addr_a = 0;
          we_a = 1;

          din_a.active   = 1'b0;
          din_a.value    = second_greatest;
          din_a.capacity = 'x;

          next.value   = 1'b0;
          next.position    = '0;
          next.capacity = 'x;

          next_out_reg = second_greatest; //tentatively set it to be second greatest
          next_queue_size = queue_size - 1;
          next_state = DEQUEUE_READ_ROOT_CHILDREN;
        end else if (i_wrt && i_read) begin // --- REPLACE ---

          next.position   = 1'b0;
          next.value    = i_data;
          next.capacity = 'x;

          next_out_reg = i_data;
          next_state = REPLACE_READ_ROOT;
          next_queue_size = queue_size;
        end
      end

      ENQUEUE_COMPARE_ROOT: begin
        //swap here, then continue writing down the heap
        if (curr.value > dout_a.value) begin
          addr_a = curr.position;
          we_a = 1;

          din_a.active   = 1'b1;
          din_a.value    = i_data;
          din_a.capacity = dout_a.capacity - 1;

          next.value    = dout_a.value;
          next.position = '0;
          next.capacity = dout_a.capacity - 1;

          next_out_reg = curr.value;
          next_second_greatest = dout_a.value;
        end else begin
          addr_a = curr.position;
          we_a = 1;

          din_a.active   = 1'b1;
          din_a.value    = dout_a.value;
          din_a.capacity = dout_a.capacity - 1;

          next.value    = curr.value;
          next.position = '0;
          next.capacity = dout_a.capacity - 1;

          next_out_reg = dout_a.value;
        end
        next_state = ENQUEUE_READ_CHILD;
      end

      ENQUEUE_READ_CHILD: begin
        //read child_idx_left and child_idx_right
        addr_a = child_idx_left;
        addr_b = child_idx_right;
        next_state = ENQUEUE_COMPARE_CHILD;
      end

      ENQUEUE_COMPARE_CHILD: begin
        //if inactive we write into it, if active we check, if greater than we swap, if less than we traverse down the cheaper route
        if (!dout_a.active && (dout_a.capacity > 0)) begin
          //Write into left
          addr_a = child_idx_left;
          we_a   = 1;

          din_a.active   = 1'b1;
          din_a.value    = curr.value;
          din_a.capacity = dout_a.capacity - 1;

          if (curr.value > second_greatest) next_second_greatest = curr.value;
          next_state = IDLE;
        end else if (!dout_b.active && (dout_b.capacity > 0)) begin
          //Write into right
          addr_b = child_idx_right;
          we_b   = 1;

          din_b.active   = 1'b1;
          din_b.value    = curr.value;
          din_b.capacity = dout_b.capacity - 1;

          if (curr.value > second_greatest) next_second_greatest = curr.value;
          next_state = IDLE;
        end else if (dout_a.active && (dout_a.capacity > 0) && (curr.value <= dout_a.value)) begin
          // Check children of left next
          addr_a = child_idx_left;
          we_a   = 1;

          din_a.active   = 1'b1;
          din_a.value    = dout_a.value;
          din_a.capacity = dout_a.capacity - 1;

          next.value    = curr.value;
          next.position = child_idx_left;
          next.capacity = dout_a.capacity - 1;

          if (dout_a.value > second_greatest) next_second_greatest = dout_a.value;
          next_state = ENQUEUE_READ_CHILD; 
        end else if (dout_b.active && (dout_b.capacity > 0) && (curr.value <= dout_b.value)) begin
          // Check children of right next
          addr_b = child_idx_right;
          we_b   = 1;

          din_b.active   = 1'b1;
          din_b.value    = dout_b.value;
          din_b.capacity = dout_b.capacity - 1;

          next.value    = curr.value;
          next.position = child_idx_right;
          next.capacity = dout_b.capacity - 1;

          if (dout_b.value > second_greatest) next_second_greatest = dout_b.value;
          next_state = ENQUEUE_READ_CHILD; 
        end else if (dout_a.active && (dout_a.capacity > 0) && (curr.value > dout_a.value) && ((dout_a.value <= dout_b.value) || (dout_b.capacity == 0))) begin
          //swap Left and Curr, check children of right
          addr_a = child_idx_left;
          we_a   = 1;

          din_a.active   = 1'b1;
          din_a.value    = curr.value;
          din_a.capacity = dout_a.capacity - 1;

          next.value    = dout_a.value;
          next.position = child_idx_left;
          next.capacity = dout_a.capacity - 1;

          if (curr.value > second_greatest) next_second_greatest = curr.value;
          next_state = ENQUEUE_READ_CHILD; 
        end else if (dout_b.active && (dout_b.capacity > 0) && (curr.value > dout_b.value) && ((dout_a.value > dout_b.value) || (dout_a.capacity == 0))) begin
          //swap Right and Curr, check children of left
          addr_b = child_idx_right;
          we_b   = 1;
          
          din_b.active   = 1'b1;
          din_b.value    = curr.value;
          din_b.capacity = dout_b.capacity - 1;

          next.value    = dout_b.value;
          next.position = child_idx_right;
          next.capacity = dout_b.capacity - 1;

          if (curr.value > second_greatest) next_second_greatest = curr.value;
          next_state = ENQUEUE_READ_CHILD; 
        end
      end

      DEQUEUE_READ_ROOT_CHILDREN: begin
        //read nodes 1 and 2
        next.value    = '0;
        next.position = 0;
        next.capacity = dout_a.capacity + 1;

        addr_a = child_idx_left;
        addr_b = child_idx_right;
        next_state = DEQUEUE_COMPARE_ROOT;
      end

      DEQUEUE_COMPARE_ROOT: begin
        //if both nodes are inactive or we are at the end, we go to idle next, because this is root, we set the next max out
        if ((!dout_a.active && !dout_b.active) || (child_idx_left > QUEUE_SIZE) || (child_idx_right > QUEUE_SIZE)) begin
          addr_a = curr.position;
          we_a = 1;
          
          din_a.active   = 1'b0;
          din_a.value    = '0;
          din_a.capacity = QUEUE_SIZE;
          
          next_state = IDLE;
        end else begin
          // if only one is inactive we pull that value
          if (dout_a.active && !dout_b.active) begin
            addr_a = curr.position;
            we_a = 1;
            
            din_a.active   = 1'b1;
            din_a.value    = dout_a.value;
            din_a.capacity = curr.capacity;

            addr_b = child_idx_left;
            we_b = 1;
            
            din_b.active   = 1'b0;
            din_b.value    = '0;
            din_b.capacity = dout_a.capacity + 1;

            next.value    = curr.value;
            next.position = child_idx_left;
            next.capacity = dout_a.capacity + 1;
            
            next_out_reg = dout_a.value;
            next_second_greatest = 'x;
          end else if (dout_b.active && !dout_a.active) begin
            addr_b = curr.position;
            we_b = 1;
            
            din_b.active   = 1'b1;
            din_b.value    = dout_b.value;
            din_b.capacity = curr.capacity;

            addr_a = child_idx_right;
            we_a = 1;
            
            din_a.active   = 1'b0;
            din_a.value    = '0;
            din_a.capacity = dout_b.capacity + 1;

            next.value    = curr.value;
            next.position = child_idx_right;
            next.capacity = dout_b.capacity + 1;
            
            next_out_reg = dout_b.value;
            next_second_greatest = 'x;
          end else if (dout_a.active && dout_b.active) begin
            if (dout_a.value >= dout_b.value) begin
              addr_a = curr.position;
              we_a = 1;
              
              din_a.active   = 1'b1;
              din_a.value    = dout_a.value;
              din_a.capacity = curr.capacity;

              addr_b = child_idx_left;
              we_b = 1;
              
              din_b.active   = 1'b0;
              din_b.value    = '0;
              din_b.capacity = dout_a.capacity + 1;

              next.value    = curr.value;
              next.position = child_idx_left;
              next.capacity = dout_a.capacity + 1;
              
              next_out_reg = dout_a.value;
              next_second_greatest = dout_b.value;
            end else begin
              addr_b = curr.position;
              we_b = 1;
              
              din_b.active   = 1'b1;
              din_b.value    = dout_b.value;
              din_b.capacity = curr.capacity;

              addr_a = child_idx_right;
              we_a = 1;
              
              din_a.active   = 1'b0;
              din_a.value    = '0;
              din_a.capacity = dout_b.capacity + 1;

              next.value    = curr.value;
              next.position = child_idx_right;
              next.capacity = dout_b.capacity + 1;
              
              next_out_reg = dout_b.value;
              next_second_greatest = dout_a.value;
            end
          end
          next_state = DEQUEUE_READ_CHILD;
        end
      end

      DEQUEUE_READ_CHILD: begin
        //read child_idx_left and child_idx_right
        if ((child_idx_left > QUEUE_SIZE) || (child_idx_right > QUEUE_SIZE)) begin
          next_state = IDLE;
        end else begin
          addr_a = child_idx_left;
          addr_b = child_idx_right;
          next_state = DEQUEUE_COMPARE_CHILD;
        end
      end

      DEQUEUE_COMPARE_CHILD: begin
        //if both nodes are inactive or we are at the end, we go to idle next
        if ((!dout_a.active && !dout_b.active) || (child_idx_left > QUEUE_SIZE) || (child_idx_right > QUEUE_SIZE)) begin
          next_state = IDLE;
        end else begin
          // if only one is inactive we pull that value
          if (dout_a.active && !dout_b.active) begin
            addr_a = curr.position;
            we_a = 1;
            
            din_a.active   = 1'b1;
            din_a.value    = dout_a.value;
            din_a.capacity = curr.capacity;

            addr_b = child_idx_left;
            we_b = 1;
            
            din_b.active   = 1'b0;
            din_b.value    = '0;
            din_b.capacity = dout_a.capacity + 1;

            next.value    = curr.value;
            next.position = child_idx_left;
            next.capacity = dout_a.capacity + 1;
          end else if (dout_b.active && !dout_a.active) begin
            addr_b = curr.position;
            we_b = 1;
            
            din_b.active   = 1'b1;
            din_b.value    = dout_b.value;
            din_b.capacity = curr.capacity;

            addr_a = child_idx_right;
            we_a = 1;
            
            din_a.active   = 1'b0;
            din_a.value    = '0;
            din_a.capacity = dout_b.capacity + 1;

            next.value    = curr.value;
            next.position = child_idx_right;
            next.capacity = dout_b.capacity + 1;
          end else if (dout_a.active && dout_b.active) begin
            if (dout_a.value >= dout_b.value) begin
              addr_a = curr.position;
              we_a = 1;
              
              din_a.active   = 1'b1;
              din_a.value    = dout_a.value;
              din_a.capacity = curr.capacity;

              addr_b = child_idx_left;
              we_b = 1;
              
              din_b.active   = 1'b0;
              din_b.value    = '0;
              din_b.capacity = dout_a.capacity + 1;

              next.value    = curr.value;
              next.position = child_idx_left;
              next.capacity = dout_a.capacity + 1;
            end else begin
              addr_b = curr.position;
              we_b = 1;
              
              din_b.active   = 1'b1;
              din_b.value    = dout_b.value;
              din_b.capacity = curr.capacity;

              addr_a = child_idx_right;
              we_a = 1;
              
              din_a.active   = 1'b0;
              din_a.value    = '0;
              din_a.capacity = dout_b.capacity + 1;

              next.value    = curr.value;
              next.position = child_idx_right;
              next.capacity = dout_b.capacity + 1;
            end
          end
          next_state = DEQUEUE_READ_CHILD;
        end
      end

      REPLACE_READ_ROOT: begin
        //get the current capacity, and then read the children
        addr_a = child_idx_left;
        addr_b = child_idx_right;
        
        next.value    = curr.value;
        next.position = 0;
        next.capacity = dout_a.capacity;
        
        next_state = REPLACE_COMPARE_ROOT;
      end

      REPLACE_COMPARE_ROOT: begin
        //if the current node is the only node or the greatest node, we just write into it and go back to idle
        if ((!dout_a.active && !dout_b.active) || (child_idx_left > QUEUE_SIZE) || (child_idx_right > QUEUE_SIZE) || ((curr.value >= dout_a.value) && (curr.value >= dout_b.value))) begin
          addr_a = curr.position;
          we_a = 1;
          
          din_a.active   = 1'b1;
          din_a.value    = curr.value;
          din_a.capacity = curr.capacity;
          
          next_out_reg = curr.value;
          next_state = IDLE;
        end else begin
          // otherwise swap with the higher priority node
          // swap with A
          if ((dout_a.active && !dout_b.active) || (dout_a.value >= dout_b.value)) begin
            addr_a = curr.position;
            we_a = 1;
            
            din_a.active   = 1'b1;
            din_a.value    = dout_a.value;
            din_a.capacity = curr.capacity;

            addr_b = child_idx_left;
            we_b = 1;
            
            din_b.active   = 1'b1;
            din_b.value    = curr.value;
            din_b.capacity = dout_a.capacity;

            next.value    = curr.value;
            next.position = child_idx_left;
            next.capacity = dout_a.capacity;
            
            next_out_reg = dout_a.value;
          end else if ((dout_b.active && !dout_a.active) || (dout_b.value >= dout_a.value)) begin
            addr_b = curr.position;
            we_b = 1;
            
            din_b.active   = 1'b1;
            din_b.value    = dout_b.value;
            din_b.capacity = curr.capacity;

            addr_a = child_idx_right;
            we_a = 1;
            
            din_a.active   = 1'b1;
            din_a.value    = curr.value;
            din_a.capacity = dout_b.capacity;

            next.value    = curr.value;
            next.position = child_idx_right;
            next.capacity = dout_b.capacity;
            
            next_out_reg = dout_b.value;
          end
          next_state = REPLACE_READ_CHILD;
        end
      end

      REPLACE_READ_CHILD: begin
        //read child_idx_left and child_idx_right
        if ((child_idx_left > QUEUE_SIZE) || (child_idx_right > QUEUE_SIZE)) begin
          next_state = IDLE;
        end else begin
          addr_a = child_idx_left;
          addr_b = child_idx_right;
          next_state = REPLACE_COMPARE_CHILD;
        end
      end
      
      REPLACE_COMPARE_CHILD: begin
        if ((!dout_a.active && !dout_b.active) || (child_idx_left > QUEUE_SIZE) || (child_idx_right > QUEUE_SIZE) || ((curr.value >= dout_a.value) && (curr.value >= dout_b.value))) begin
          addr_a = curr.position;
          we_a = 1;
          
          din_a.active   = 1'b1;
          din_a.value    = curr.value;
          din_a.capacity = curr.capacity;
          
          next_state = IDLE;
        end else begin
          // otherwise swap with the higher priority node
          // swap with A
          if ((dout_a.active && !dout_b.active) || (dout_a.value >= dout_b.value)) begin
            addr_a = curr.position;
            we_a = 1;
            
            din_a.active   = 1'b1;
            din_a.value    = dout_a.value;
            din_a.capacity = curr.capacity;

            addr_b = child_idx_left;
            we_b = 1;
            
            din_b.active   = 1'b1;
            din_b.value    = curr.value;
            din_b.capacity = dout_a.capacity;

            next.value    = curr.value;
            next.position = child_idx_left;
            next.capacity = dout_a.capacity;
          end else if ((dout_b.active && !dout_a.active) || (dout_b.value >= dout_a.value)) begin
            addr_b = curr.position;
            we_b = 1;
            
            din_b.active   = 1'b1;
            din_b.value    = dout_b.value;
            din_b.capacity = curr.capacity;

            addr_a = child_idx_right;
            we_a = 1;
            
            din_a.active   = 1'b1;
            din_a.value    = curr.value;
            din_a.capacity = dout_b.capacity;

            next.value    = curr.value;
            next.position = child_idx_right;
            next.capacity = dout_b.capacity;
          end
          next_state = REPLACE_READ_CHILD;
        end
      end
    endcase
  end

  assign o_full  = (queue_size == QUEUE_SIZE);
  assign o_empty = (queue_size == 0);
  assign o_data  = (queue_size == 0) ? 0 : out_reg;
  assign ready   = (state == IDLE);
endmodule
