/*******************************************************************************
  Module Name: bram_tree
  Date: 2025/03/05
  Description: A priority queue implementation using a binary max-heap structure
               stored in block RAM (BRAM). Supports enqueue, dequeue, and replace
               operations.
  Parameters: QUEUE_SIZE - Maximum number of elements in the priority queue
              DATA_WIDTH - Bit width of data elements
  Inputs: i_CLK - System clock
          i_RSTn - Active-low reset signal
          i_wrt - Write/insert command (enqueue operation)
          i_read - Read/pop command (dequeue operation)
          i_data - Input data to be enqueued
  Outputs: o_write_ready - High when the queue has room to accept a write
           o_read_ready - High when the queue holds data available to read
           o_data - Output data from the highest priority element

  Cleanup notes (relative to original):
    - Removed parent_idx and the parent/left_child/right_child registers
      (next_state logic never wrote or read them).
    - Removed three unreachable states: ENQUEUE_COMPARE_ROOT,
      DEQUEUE_READ_ROOT_CHILDREN, REPLACE_READ_ROOT.
    - Factored the repeated "are we past the last valid child / are both
      children inactive" checks into children_out_of_range and
      both_children_inactive.
    - Factored the repeated "(state == IDLE) && !(i_read || i_wrt)" term
      used by all three ready/valid outputs into idle_and_no_new_request.
      The "&& !(i_read || i_wrt)" half was REMOVED 2026-08-30 and the term
      renamed fsm_idle -- see the comment at the ready assignments.
    - Replaced all `'{field: value, ...}` assignment-pattern struct literals
      with field-by-field assignment (next.value = ...; next.position = ...;
      etc.) for Icarus Verilog compatibility. Plain '0 fills are unaffected.
  Reserved payloads: '0 and all-ones are sentinels, not data. '0 is the empty
           slot and the dequeue mechanism (write it into the head and let the
           sort network sink it); all-ones is the max-priority placeholder an
           ENQ_ENA=0 build resets into. Neither may be driven on i_data, in
           EITHER build -- the legal alphabet is 2**DATA_WIDTH - 2 everywhere,
           so one rule covers the whole library. Behaviour when they ARE driven
           is outside the supported input range.
*******************************************************************************/

module bram_tree #(
    // QUEUE_SIZE and DATA_WIDTH were localparams in an in-file `bram_tree_pkg`,
    // so this module built at exactly ONE size: `elaborate -parameter` cannot
    // reach a localparam, and the Vivado parameter sweep could not drive it
    // either -- which is why bram_tree is absent from the sweep results the rest
    // of the library publishes. The two struct typedefs came with them, because
    // their field widths depend on the parameters and a package typedef cannot.
    //
    // QUEUE_SIZE must be 2^k - 1, as for every tree design in this library.
    parameter integer QUEUE_SIZE = 7,
    parameter integer DATA_WIDTH = 16
) (
    input  logic                  i_CLK,
    input  logic                  i_RSTn,
    // Inputs
    input  logic                  i_wrt,    // Write/insert command
    input  logic                  i_read,   // Read/pop command
    input  logic [DATA_WIDTH-1:0] i_data,   // Input data
    // Outputs
    output logic                  o_write_ready,   // High if the heap is full
    output logic                  o_read_ready,  // High if the heap is empty
    output logic [DATA_WIDTH-1:0] o_data   // Output data (Root node)
);

  localparam integer TREE_DEPTH    = $clog2(QUEUE_SIZE + 1);
  localparam integer NODES_NEEDED  = (1 << TREE_DEPTH) - 1;
  localparam integer ADDRESS_WIDTH = $clog2(NODES_NEEDED);

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

  typedef enum logic [3:0] {
    IDLE                    = 4'd0,
    // Enqueue
    ENQUEUE_READ_CHILD      = 4'd1,
    ENQUEUE_COMPARE_CHILD   = 4'd2,
    // Dequeue
    DEQUEUE_COMPARE_ROOT    = 4'd3,
    DEQUEUE_READ_CHILD      = 4'd4,
    DEQUEUE_COMPARE_CHILD   = 4'd5,
    // Replace
    REPLACE_COMPARE_ROOT    = 4'd6,
    REPLACE_READ_CHILD      = 4'd7,
    REPLACE_COMPARE_CHILD   = 4'd8
  } state_t;

  state_t state, next_state;
  bram_tree_curr_t curr, next;
  bram_tree_mem_t  top_level, next_top_level;
  logic [ADDRESS_WIDTH:0] child_idx_left, child_idx_right;
  integer queue_size, next_queue_size;
  logic empty;

  logic children_out_of_range;
  logic both_children_inactive;
  logic fsm_idle;

  // Reset fill. The BRAM has no reset port, and the `initial` block in
  // rams_tdp_rf_rf.sv is simulation-only -- synthesis takes it as a power-up
  // value and a formal tool ignores it outright (VERI-1060). So nothing restored
  // the empty-tree fill: a reset arriving with data in the queue cleared
  // queue_size and top_level but left every node holding its stale `active` flag
  // and, worse, its stale `capacity`.
  //
  // Simulation cannot check this: the testbench resets once, at time zero. The
  // defect needs a SECOND reset, which is why it went untested until
  // a_reset_restores_fill was written -- it fails at 14 cycles.
  //
  // The sweep rewrites all NODES_NEEDED nodes on EVERY reset. Capacity is not a
  // constant here: node i roots a subtree of ((NODES_NEEDED+1) >> level(i)) - 1
  // with level(i) = floor(log2(i+1)), so rather than compute a log per node the
  // sweep carries the level and steps it at the boundaries 1, 3, 7, ...
  logic                            filling;
  logic [ADDRESS_WIDTH-1:0]        fill_cnt;
  logic [$clog2(TREE_DEPTH+1)-1:0] fill_level;
  logic [ADDRESS_WIDTH+1:0]        fill_bound;
  logic [ADDRESS_WIDTH-1:0]        fill_cap;

  assign fill_cap = ADDRESS_WIDTH'(((NODES_NEEDED + 1) >> fill_level) - 1);


  // BRAM signals
  logic [ADDRESS_WIDTH-1:0] addr_a;
  logic [ADDRESS_WIDTH-1:0] addr_b;
  bram_tree_mem_t     din_a;
  bram_tree_mem_t     din_b;
  logic                     we_a;
  logic                     we_b;
  bram_tree_mem_t     dout_a;
  bram_tree_mem_t     dout_b;

  // The RAM now takes plain packed vectors rather than the struct type, because
  // the struct is module-local once the widths are parameters. The conversions
  // are explicit in both directions rather than relying on implicit struct/vector
  // port coercion: this file has to compile under iverilog (CI) and Xcelium
  // (CEPool) as well as Jasper, and an explicit cast is the one form all three
  // agree on.
  localparam integer MEM_WIDTH = $bits(bram_tree_mem_t);

  logic [MEM_WIDTH-1:0] ram_din_a, ram_din_b, ram_dout_a, ram_dout_b;

  assign ram_din_a = din_a;
  assign ram_din_b = din_b;
  assign dout_a    = bram_tree_mem_t'(ram_dout_a);
  assign dout_b    = bram_tree_mem_t'(ram_dout_b);

  rams_tdp_rf_rf #(
      .WIDTH    (MEM_WIDTH),
      .DEPTH    (NODES_NEEDED),
      .CAP_WIDTH(ADDRESS_WIDTH)
  ) bram_inst (
    .clka (i_CLK), .ena(1'b1), .wea(we_a), .addra(addr_a), .dia(ram_din_a), .doa(ram_dout_a),
    .clkb (i_CLK), .enb(1'b1), .web(we_b), .addrb(addr_b), .dib(ram_din_b), .dob(ram_dout_b)
  );

  always_ff @(posedge i_CLK or negedge i_RSTn) begin : fsm_seq
    if (!i_RSTn) begin
      state      <= IDLE;
      queue_size <= 0;
      curr       <= '0;
      top_level.active   <= 1'b0;
      top_level.value    <= '0;
      top_level.capacity <= QUEUE_SIZE;
    end else begin
      state      <= next_state;
      queue_size <= next_queue_size;
      curr       <= next;
      top_level  <= next_top_level;
    end
  end

  // Reset fill sequencer. Runs after EVERY reset, not just the first. No command
  // is accepted while it runs (fsm_idle is gated on !filling), so it cannot race
  // the descent.
  always_ff @(posedge i_CLK or negedge i_RSTn) begin : fill_seq
    if (!i_RSTn) begin
      filling    <= 1'b1;
      fill_cnt   <= '0;
      fill_level <= '0;
      fill_bound <= 'd1;
    end else if (filling) begin
      if (fill_cnt == ADDRESS_WIDTH'(NODES_NEEDED - 1)) begin
        filling <= 1'b0;
      end else begin
        fill_cnt <= fill_cnt + 1'b1;
        if ((fill_cnt + 1'b1) == fill_bound[ADDRESS_WIDTH-1:0]) begin
          fill_level <= fill_level + 1'b1;
          fill_bound <= (fill_bound << 1) + 'd1;
        end
      end
    end
  end

  always @* begin : fsm_comb
    next_state      = state;
    next_queue_size = queue_size;
    next            = curr;
    addr_a = '0;
    addr_b = '0;
    din_a  = '0;
    din_b  = '0;
    we_a   = 1'b0;
    we_b   = 1'b0;
    next_top_level = top_level;

    child_idx_left  = curr.position * 2 + 1;
    child_idx_right = curr.position * 2 + 2;

    children_out_of_range  = (child_idx_left > QUEUE_SIZE) || (child_idx_right > QUEUE_SIZE);
    both_children_inactive = !dout_a.active && !dout_b.active;

    if (filling) begin
      // Park the walk and drive the sweep. IDLE would otherwise decode whatever
      // command is asserted, and the descent would run against a half-rewritten
      // memory.
      next_state     = IDLE;
      addr_a         = fill_cnt;
      we_a           = 1'b1;
      din_a.active   = 1'b0;
      din_a.value    = '0;
      din_a.capacity = fill_cap;
      we_b           = 1'b0;
    end else begin
    case (state)
      IDLE: begin
        // WHAT PASSING LOOKS LIKE: a_no_enq_when_full says the DUT must not accept
        // an enqueue it does not advertise. With this guard the arm does not fire
        // on a full queue, the chain falls through, and the command is inert --
        // the same F-8 principle as the dequeue guard below. Without it the arm
        // ran the descent and drove next_queue_size past QUEUE_SIZE.
        // Demonstrated at the previous commit: cex in 32 cycles, which is roughly
        // the cost of filling a 7-element queue before the violation is even
        // expressible. Simulation cannot reach it -- the testbench prints
        // "Queue full, skipping enqueue" and declines to issue the command.
        if (i_wrt && !i_read && (queue_size != QUEUE_SIZE)) begin // --- ENQUEUE ---
          if (queue_size == 0) begin
            next_top_level.active   = 1'b1;
            next_top_level.value    = i_data;
            next_top_level.capacity = QUEUE_SIZE - 1;
            next_state = IDLE;
          end else begin
            if(i_data > top_level.value) begin
              next_top_level.active   = 1'b1;
              next_top_level.value    = i_data;
              next_top_level.capacity = top_level.capacity - 1;

              next.value    = top_level.value;
              next.position = '0;
              next.capacity = top_level.capacity - 1;
            end else begin
              next_top_level.active   = 1'b1;
              next_top_level.value    = top_level.value;
              next_top_level.capacity = top_level.capacity - 1;

              next.value    = i_data;
              next.position = 0;
              next.capacity = top_level.capacity - 1;
            end
            addr_a = 1;
            addr_b = 2;
            next_state = ENQUEUE_COMPARE_CHILD;
          end
          next_queue_size = queue_size + 1;
        // WHAT PASSING LOOKS LIKE: a_no_deq_when_empty says the DUT must not
        // accept a dequeue it does not advertise. With this guard the arm does
        // not fire on an empty queue, the chain falls through, next_state stays
        // IDLE and next_queue_size stays put -- the command is INERT, which is
        // the F-8 principle. Without it the arm ran the whole descent and drove
        // next_queue_size to queue_size - 1, underflowing the counter.
        // Demonstrated at the previous commit: cex in 10 cycles. Simulation
        // cannot reach it -- the testbench gates every dequeue on o_read_ready.
        end else if (!i_wrt && i_read && (queue_size != 0)) begin // --- DEQUEUE ---
          next_top_level.active   = 1'b0;
          next_top_level.value    = '0;
          next_top_level.capacity = top_level.capacity + 1;

          next.value    = '0;
          next.position = 0;
          next.capacity = top_level.capacity + 1;

          addr_a = 1;
          addr_b = 2;
          next_queue_size = queue_size - 1;
          next_state = DEQUEUE_COMPARE_ROOT;
        end else if (i_wrt && i_read) begin // --- REPLACE ---
          next.value    = i_data;
          next.position = 0;
          next.capacity = (empty) ? top_level.capacity + 1 : top_level.capacity;

          if (queue_size == 0) begin
            next_top_level.active   = 1'b1;
            next_top_level.value    = i_data;
            next_top_level.capacity = top_level.capacity + 1;
            next_state = IDLE;
          end else begin
            next_top_level.active   = 1'b0;
            next_top_level.value    = '0;
            next_top_level.capacity = top_level.capacity;
            next_state = REPLACE_COMPARE_ROOT;
          end
          addr_a = 1;
          addr_b = 2;
          next_queue_size = (empty) ? queue_size + 1 : queue_size;
        end
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
          next_state = IDLE;
        end else if (!dout_b.active && (dout_b.capacity > 0)) begin
          //Write into right
          addr_b = child_idx_right;
          we_b   = 1;
          din_b.active   = 1'b1;
          din_b.value    = curr.value;
          din_b.capacity = dout_b.capacity - 1;
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
          next_state = ENQUEUE_READ_CHILD;
        end
      end

      DEQUEUE_COMPARE_ROOT: begin
        //if both nodes are inactive or we are past the end, this is root: reset next max out
        if (both_children_inactive || children_out_of_range) begin
          next_top_level.active   = 1'b0;
          next_top_level.value    = '0;
          next_top_level.capacity = QUEUE_SIZE;
          next_state = IDLE;
        end else begin
          // if only one is inactive we pull that value
          if (dout_a.active && !dout_b.active) begin
            addr_b = child_idx_left;
            we_b = 1;
            din_b.active   = 1'b0;
            din_b.value    = '0;
            din_b.capacity = dout_a.capacity + 1;

            next.value    = curr.value;
            next.position = child_idx_left;
            next.capacity = dout_a.capacity + 1;

            next_top_level.active   = 1'b1;
            next_top_level.value    = dout_a.value;
            next_top_level.capacity = curr.capacity;
          end else if (dout_b.active && !dout_a.active) begin
            addr_a = child_idx_right;
            we_a = 1;
            din_a.active   = 1'b0;
            din_a.value    = '0;
            din_a.capacity = dout_b.capacity + 1;

            next.value    = curr.value;
            next.position = child_idx_right;
            next.capacity = dout_b.capacity + 1;

            next_top_level.active   = 1'b1;
            next_top_level.value    = dout_b.value;
            next_top_level.capacity = curr.capacity;
          end else if (dout_a.active && dout_b.active) begin
            if (dout_a.value >= dout_b.value) begin
              addr_b = child_idx_left;
              we_b = 1;
              din_b.active   = 1'b0;
              din_b.value    = '0;
              din_b.capacity = dout_a.capacity + 1;

              next.value    = curr.value;
              next.position = child_idx_left;
              next.capacity = dout_a.capacity + 1;

              next_top_level.active   = 1'b1;
              next_top_level.value    = dout_a.value;
              next_top_level.capacity = curr.capacity;
            end else begin
              addr_a = child_idx_right;
              we_a = 1;
              din_a.active   = 1'b0;
              din_a.value    = '0;
              din_a.capacity = dout_b.capacity + 1;

              next.value    = curr.value;
              next.position = child_idx_right;
              next.capacity = dout_b.capacity + 1;

              next_top_level.active   = 1'b1;
              next_top_level.value    = dout_b.value;
              next_top_level.capacity = curr.capacity;
            end
          end
          next_state = DEQUEUE_READ_CHILD;
        end
      end

      DEQUEUE_READ_CHILD: begin
        //read child_idx_left and child_idx_right
        if (children_out_of_range) begin
          next_state = IDLE;
        end else begin
          addr_a = child_idx_left;
          addr_b = child_idx_right;
          next_state = DEQUEUE_COMPARE_CHILD;
        end
      end

      DEQUEUE_COMPARE_CHILD: begin
        //if both nodes are inactive or we are past the end, we go to idle next
        if (both_children_inactive || children_out_of_range) begin
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

      REPLACE_COMPARE_ROOT: begin
        //if the current node is the only node or the greatest node, we just write into it and go back to idle
        if (both_children_inactive || children_out_of_range || ((curr.value >= dout_a.value) && (curr.value >= dout_b.value))) begin
          next_top_level.active   = 1'b1;
          next_top_level.value    = curr.value;
          next_top_level.capacity = curr.capacity;
          next_state = IDLE;
        end else begin
          // otherwise swap with the higher priority node
          // swap with A
          if ((dout_a.active && !dout_b.active) || (dout_a.value >= dout_b.value)) begin
            addr_b = child_idx_left;
            we_b = 1;
            din_b.active   = 1'b1;
            din_b.value    = curr.value;
            din_b.capacity = dout_a.capacity;

            next.value    = curr.value;
            next.position = child_idx_left;
            next.capacity = dout_a.capacity;

            next_top_level.active   = 1'b1;
            next_top_level.value    = dout_a.value;
            next_top_level.capacity = curr.capacity;
          end else if ((dout_b.active && !dout_a.active) || (dout_b.value >= dout_a.value)) begin
            addr_a = child_idx_right;
            we_a = 1;
            din_a.active   = 1'b1;
            din_a.value    = curr.value;
            din_a.capacity = dout_b.capacity;

            next.value    = curr.value;
            next.position = child_idx_right;
            next.capacity = dout_b.capacity;

            next_top_level.active   = 1'b1;
            next_top_level.value    = dout_b.value;
            next_top_level.capacity = curr.capacity;
          end
          next_state = REPLACE_READ_CHILD;
        end
      end

      REPLACE_READ_CHILD: begin
        //read child_idx_left and child_idx_right
        if (children_out_of_range) begin
          next_state = IDLE;
        end else begin
          addr_a = child_idx_left;
          addr_b = child_idx_right;
          next_state = REPLACE_COMPARE_CHILD;
        end
      end

      REPLACE_COMPARE_CHILD: begin
        if (both_children_inactive || children_out_of_range || ((curr.value >= dout_a.value) && (curr.value >= dout_b.value))) begin
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
  end

  // The readies are a function of STATE ALONE. They used to be
  //
  //     assign idle_and_no_new_request = (state == IDLE) && !(i_read || i_wrt);
  //
  // so asserting either command drove both readies low in the same cycle. Two
  // consequences, one practical and one that made the module unprovable:
  //
  //   Ready and valid could never be high together, so a conventional master --
  //   assert valid, hold it, wait for ready -- deadlocks, because holding valid
  //   is exactly what forces ready low.
  //
  //   Fed to the formal spec's `settled = o_write_ready || o_read_ready` and its
  //   am_no_cmd_while_busy, the assumption read "if a command is issued then no
  //   command is issued". Jasper therefore issued none: at 26adf6d the run
  //   reported 9 asserts proven with 15 of 20 covers UNREACHABLE, including all
  //   three command covers. Every one of those proofs was vacuous.
  //
  // Removing the term cannot change what the design DOES: the acceptance path
  // never reads the readies. The FSM accepts inside `case (state) IDLE: if
  // (i_wrt && !i_read)`, branching on the state and the raw command bits. This
  // changes only what the ports advertise, and simulation confirms it: every
  // functional check passes and the operation counts and MAXIMA are unchanged at
  // both QUEUE_SIZE 7 and 15.
  //
  // Two measured numbers DO move, and they move because this fix corrects them.
  // The minimum enqueue and replace latency drops from 2 cycles to 1:
  //
  //     QUEUE_SIZE=7    enqueue min 2 -> 1, mean 3.59 -> 3.50
  //                     replace min 2 -> 1, mean 2.65 -> 2.62
  //                     dequeue UNCHANGED
  //
  // Dequeue is the tell. An enqueue or replace on an EMPTY queue sets
  // next_state = IDLE and really does finish in one cycle; a dequeue always goes
  // to DEQUEUE_COMPARE_ROOT and never can. Exactly the two ops that can be
  // single-cycle are the two whose minimum moved.
  //
  // The old figure was a measurement artifact caused by this very defect. The
  // testbench calls clear_cmd() and then poll_settled() in the same timestep;
  // while a ready depended combinationally on i_wrt, that read could take the
  // stale pre-clear value, see !settled, and burn one extra negedge before
  // returning. A multi-cycle op is genuinely busy then, so the wait was absorbed
  // and only the minima were inflated. With the readies derived from registered
  // state the read is stable and the reported latency is the real one.
  //
  // NOTE FOR ANY PUBLISHED NUMBER: bram_tree's minimum enqueue/replace latency
  // was over-reported by one cycle before this commit. The design did not get
  // faster.
  //
  // Simulation could never have caught the original, and that is structural
  // rather than bad luck. The shared testbench polls `settled` on the negedge
  // with both commands cleared, then asserts a command -- so it only ever samples
  // a ready in a cycle where no command is asserted, which is precisely where the
  // removed term was harmlessly 1. It never holds valid waiting for ready. The
  // ready signals and that polling protocol were written in the same commit
  // (73d7b62), so the harness was shaped around this behaviour rather than
  // independently checking it.
  assign fsm_idle      = (state == IDLE) && !filling;
  assign o_write_ready = (queue_size != QUEUE_SIZE) && fsm_idle;
  assign o_read_ready  = (queue_size != 0)          && fsm_idle;
  assign o_data        = (queue_size == 0) ? 0 : top_level.value;
  assign empty          = (queue_size == 0);
endmodule