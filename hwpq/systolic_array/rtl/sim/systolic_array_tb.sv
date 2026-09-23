`default_nettype none

module systolic_array_tb;
  // Parameters matching the module under test
  parameter int QUEUE_SIZE = 8;
  parameter int DATA_WIDTH = 16;

  // Clock and reset signals
  logic                  i_CLK;
  logic                  i_RSTn;

  // Input signals
  logic                  i_wrt;
  logic                  i_read;
  logic [DATA_WIDTH-1:0] i_data;

  // Output signals
  logic                  o_write_ready;
  logic                  o_read_ready;
  logic [DATA_WIDTH-1:0] o_data;

  // Reference array for verification
  logic [DATA_WIDTH-1:0] ref_queue        [$:QUEUE_SIZE-1];
  int                    ref_size = 0;

  // Test variables
  logic [DATA_WIDTH-1:0] random_value;

  typedef enum int {
    ENQUEUE = 1,
    DEQUEUE = 2,
    REPLACE = 3
  } t_operation;
  t_operation random_operation;

  // Instantiate the register_tree module
  systolic_array #(
      .QUEUE_SIZE(QUEUE_SIZE),
      .DATA_WIDTH(DATA_WIDTH)
  ) u_SystolicArray (
      .i_CLK(i_CLK),
      .i_RSTn(i_RSTn),
      .i_wrt(i_wrt),
      .i_read(i_read),
      .i_data(i_data),
      .o_write_ready(o_write_ready),
      .o_read_ready(o_read_ready),
      .o_data(o_data)
  );

  // Clock generation: 10ns period
  always #5 i_CLK <= ~i_CLK;

  int error_count = 0;

  initial begin
    // Initialize signals
    i_CLK = 0;
    i_RSTn = 0;
    i_wrt = 0;
    i_read = 0;
    i_data = 0;

    // Reset the module
    @(posedge i_CLK);
    i_RSTn = 1;
    @(posedge i_CLK);

    // Initialize the queue, fill it up to QUEUE_SIZE with random values
    for (int i = 0; i < QUEUE_SIZE; i++) begin
      random_value = $urandom_range(0, 1024);
      enqueue(random_value);
      repeat (5) @(posedge i_CLK);  // to make sure that the queue is correctly initialized
    end
    repeat (5) @(posedge i_CLK);  // wait for the queue to stabilize

    // Test Case 1: Dequeue nodes
    // Dequeue nodes for QUEUE_SIZE times
    $display("\nTest Case 1: Dequeue Test");
    for (int i = 0; i < QUEUE_SIZE; i++) begin
      dequeue();
      if (o_read_ready) begin
        assert (o_data == ref_queue[0])
        else begin error_count++; $error("Dequeue: Node f value mismatch -> expected %d, got %d", ref_queue[0], o_data); end;
      end else begin
        assert (o_data == '0)
        else begin error_count++; $error("Dequeue: Node f value mismatch -> expected %d, got %d", '0, o_data); end;
      end
    end

    // Test Case 2: Enqueue nodes
    // Enqueue random values for QUEUE_SIZE times
    $display("\nTest Case 2: Enqueue Test");
    for (int i = 0; i < QUEUE_SIZE; i++) begin
      random_value = $urandom_range(0, 1024);
      enqueue(random_value);
      assert (o_data == ref_queue[0])
      else begin error_count++; $error("Enqueue: Node f value mismatch -> expected %d, got %d", ref_queue[0], o_data); end;
    end

    // Test Case 3: Replace nodes
    // Replace root node for QUEUE_SIZE times
    $display("\nTest Case 3: Replace Test");
    for (int i = 0; i < QUEUE_SIZE; i++) begin
      random_value = $urandom_range(0, 1024);
      replace(random_value);
      assert (o_data == ref_queue[0])
      else begin error_count++; $error("Replace: Node f value mismatch -> expected %d, got %d", ref_queue[0], o_data); end;
    end

    // Test Case 4: Stress Test
    // stress test, mix operations

    $display("\nTest Case 4: Stress Test");
    for (int i = 0; i < 100; i++) begin
      random_value = $urandom_range(0, 1024);
      random_operation = t_operation'($urandom_range(1, 3));  
      case (random_operation)
        ENQUEUE: begin
          enqueue(random_value);
          assert (o_data == ref_queue[0])
          else
            begin error_count++; $error("Enqueue: Node f value mismatch -> expected %d, got %d", ref_queue[0], o_data); end;
        end

        DEQUEUE: begin
          dequeue();
          if (o_read_ready) begin
            assert (o_data == ref_queue[0])
            else
              begin error_count++; $error("Dequeue: Node f value mismatch -> expected %d, got %d", ref_queue[0], o_data); end;
          end else begin
            assert (o_data == '0)
            else begin error_count++; $error("Dequeue: Node f value mismatch -> expected %d, got %d", '0, o_data); end;
          end
        end

        REPLACE: begin
          replace(random_value);
          assert (o_data == ref_queue[0])
          else
            begin error_count++; $error("Replace: Node f value mismatch -> expected %d, got %d", ref_queue[0], o_data); end;
        end

        default: begin
          $display("Invalid operation: %d", random_operation);
        end
      endcase
    end

    if (error_count == 0) begin
      $display("\nTest completed!");
      $finish;
    end else begin
      $display("\n%0d error(s) detected during simulation.", error_count);
      $fatal(1, "Test FAILED with %0d error(s).", error_count);
    end
  end

  // Task to write to the end of the queue
  task automatic enqueue(input logic [DATA_WIDTH-1:0] value);
    logic [DATA_WIDTH-1:0] tmp;
    begin
      if (o_write_ready) begin
        i_wrt  = 1;
        i_read = 0;
        i_data = value;
        
        ref_queue[ref_size] = value;
        ref_size++;
        
        for (int i = 0; i < ref_size; i++) begin
          for (int j = i + 1; j < ref_size; j++) begin
            if (ref_queue[i] < ref_queue[j]) begin
              tmp = ref_queue[i];
              ref_queue[i] = ref_queue[j];
              ref_queue[j] = tmp;
            end
          end
        end
      end else begin
        $display("Enqueue: Queue full, skipping enqueue");
      end
      @(posedge i_CLK);
      i_wrt  = 0;
      i_read = 0;
      repeat (2) @(posedge i_CLK); 
    end
  endtask

  // Task to read root node
  task automatic dequeue();
    begin
      if (o_read_ready) begin
        i_wrt  = 0;
        i_read = 1;
        for (int i = 0; i < ref_size - 1; i++) begin
          ref_queue[i] = ref_queue[i+1];
        end
        ref_queue[ref_size-1] = '0; 
        ref_size--;
        
      end else begin
        $display("Dequeue: Queue empty, skipping dequeue");
      end
      @(posedge i_CLK);
      i_wrt  = 0;
      i_read = 0;
      repeat (3) @(posedge i_CLK);
    end
  endtask

  // Task to replace root node
  task automatic replace(input logic [DATA_WIDTH-1:0] value);
    logic [DATA_WIDTH-1:0] tmp;
    begin
      if (ref_size > 0) begin
        i_wrt  = 1;
        i_read = 1;
        i_data = value;
        ref_queue[0] = value;
        for (int i = 0; i < ref_size; i++) begin
          for (int j = i + 1; j < ref_size; j++) begin
            if (ref_queue[i] < ref_queue[j]) begin
              tmp = ref_queue[i];
              ref_queue[i] = ref_queue[j];
              ref_queue[j] = tmp;
            end
          end
        end
      end else begin
        $display("Replace: Queue empty, skipping replace");
      end
      
      @(posedge i_CLK);
      i_wrt  = 0;
      i_read = 0;
      repeat (2) @(posedge i_CLK); 
    end
  endtask

endmodule
