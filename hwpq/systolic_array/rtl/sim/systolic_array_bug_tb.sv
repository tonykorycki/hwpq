module systolic_array_tb;
  // Parameters matching the module under test
  parameter int QUEUE_SIZE = 8;
  parameter int DATA_WIDTH = 16;

  // Clock and reset signals
  logic                  CLK;
  logic                  RSTn;

  // Input signals
  logic                  i_wrt;
  logic                  i_read;
  logic [DATA_WIDTH-1:0] i_data;

  // Output signals
  logic                  o_full;
  logic                  o_empty;
  logic [DATA_WIDTH-1:0] o_data;

  // Reference array for verification
  logic [DATA_WIDTH-1:0] ref_queue        [$:QUEUE_SIZE-1];
  int                    ref_size = 0;
  logic [DATA_WIDTH-1:0] tmp;

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
      .i_CLK(CLK),
      .i_RSTn(RSTn),
      .i_wrt(i_wrt),
      .i_read(i_read),
      .i_data(i_data),
      .o_full(o_full),
      .o_empty(o_empty),
      .o_data(o_data)
  );

  // Clock generation: 10ns period
  always #5 CLK <= ~CLK;

  int error_count = 0;

  initial begin
    // Initialize signals
    CLK = 0;
    RSTn = 0;
    i_wrt = 0;
    i_read = 0;
    i_data = 0;

    // Reset the module
    @(posedge CLK);
    RSTn = 1;
    @(posedge CLK);

    // Test Case 1: Successive decreasing numbers in IB
    $display("\nTest Case 1: Successive decreasing numbers in IB");
    ref_queue.delete();

    /* Icarus Verilog (12.0) cannot force an unpacked array, so the DUT buffers are seeded
      one element at a time with plain hierarchical assignments instead of
        `force u_SystolicArray.IB = '{16'd1, 16'd6, 16'd4, 16'd2};`
      which fails with "Assignment to an entire array or to an array slice is not yet supported".
      Forcing a single word fails too with "cannot force to the word of a variable array". 
      The same applies to the other test cases below. */
    
    u_SystolicArray.IB[0] = 16'd1;
    u_SystolicArray.IB[1] = 16'd6;
    u_SystolicArray.IB[2] = 16'd4;
    u_SystolicArray.IB[3] = 16'd2;
    u_SystolicArray.OB[0] = 16'd12;
    u_SystolicArray.OB[1] = 16'd11;
    u_SystolicArray.OB[2] = 16'd10;
    u_SystolicArray.OB[3] = 16'd9;
    u_SystolicArray.size = 4'd8;
    u_SystolicArray.size_next = 4'd8;

    @(posedge CLK);

    ref_queue.push_back(16'd1);
    ref_queue.push_back(16'd6);
    ref_queue.push_back(16'd4);
    ref_queue.push_back(16'd2);
    ref_queue.push_back(16'd12);
    ref_queue.push_back(16'd11);
    ref_queue.push_back(16'd10);
    ref_queue.push_back(16'd9);
    ref_size = 8;
    for (int i = 0; i < ref_size; i++) begin
      for (int j = i + 1; j < ref_size; j++) begin
        if (ref_queue[i] < ref_queue[j]) begin
          tmp = ref_queue[i];
          ref_queue[i] = ref_queue[j];
          ref_queue[j] = tmp;
        end
      end
    end
    repeat (10) @(posedge CLK);

    for (int i = 0; i < 8; i++) begin
      dequeue();
      if (!o_empty) begin
        assert (o_data == ref_queue[0])
        else begin error_count++; $error("Dequeue: Node f value mismatch -> expected %d, got %d", ref_queue[0], o_data); end;
      end else begin
        assert (o_data == '0)
        else begin error_count++; $error("Dequeue: Node f value mismatch -> expected %d, got %d", '0, o_data); end;
      end
    end

    // Test Case 2: Successive decreasing numbers in IB
    $display("\nTest Case 2: Successive increasing numbers in OB");
    ref_queue.delete();

    u_SystolicArray.IB[0] = 16'd1;
    u_SystolicArray.IB[1] = 16'd2;
    u_SystolicArray.IB[2] = 16'd4;
    u_SystolicArray.IB[3] = 16'd6;
    u_SystolicArray.OB[0] = 16'd12;
    u_SystolicArray.OB[1] = 16'd9;
    u_SystolicArray.OB[2] = 16'd10;
    u_SystolicArray.OB[3] = 16'd11;
    u_SystolicArray.size = 4'd8;
    u_SystolicArray.size_next = 4'd8;

    @(posedge CLK);

    ref_queue.push_back(16'd1);
    ref_queue.push_back(16'd6);
    ref_queue.push_back(16'd4);
    ref_queue.push_back(16'd2);
    ref_queue.push_back(16'd12);
    ref_queue.push_back(16'd11);
    ref_queue.push_back(16'd10);
    ref_queue.push_back(16'd9);

    ref_size = 8;
    for (int i = 0; i < ref_size; i++) begin
      for (int j = i + 1; j < ref_size; j++) begin
        if (ref_queue[i] < ref_queue[j]) begin
          tmp = ref_queue[i];
          ref_queue[i] = ref_queue[j];
          ref_queue[j] = tmp;
        end
      end
    end
    repeat (10) @(posedge CLK);

    for (int i = 0; i < 8; i++) begin
      dequeue();
      if (!o_empty) begin
        assert (o_data == ref_queue[0])
        else begin error_count++; $error("Dequeue: Node f value mismatch -> expected %d, got %d", ref_queue[0], o_data); end;
      end else begin
        assert (o_data == '0)
        else begin error_count++; $error("Dequeue: Node f value mismatch -> expected %d, got %d", '0, o_data); end;
      end
    end

    // Test Case 3: Successive decreasing numbers from IB to OB+1
    $display("\nTest Case 3: Successive decreasing numbers from IB to OB+1");
    ref_queue.delete();
    u_SystolicArray.IB[0] = 16'd1;
    u_SystolicArray.IB[1] = 16'd2;
    u_SystolicArray.IB[2] = 16'd11;
    u_SystolicArray.IB[3] = 16'd10;
    u_SystolicArray.OB[0] = 16'd17;
    u_SystolicArray.OB[1] = 16'd16;
    u_SystolicArray.OB[2] = 16'd15;
    u_SystolicArray.OB[3] = 16'd9;
    u_SystolicArray.size = 4'd8;
    u_SystolicArray.size_next = 4'd8;

    @(posedge CLK);

    ref_queue.push_back(16'd1);
    ref_queue.push_back(16'd2);
    ref_queue.push_back(16'd11);
    ref_queue.push_back(16'd10);
    ref_queue.push_back(16'd17);
    ref_queue.push_back(16'd16);
    ref_queue.push_back(16'd15);
    ref_queue.push_back(16'd9);

    ref_size = 8;
    for (int i = 0; i < ref_size; i++) begin
      for (int j = i + 1; j < ref_size; j++) begin
        if (ref_queue[i] < ref_queue[j]) begin
          tmp = ref_queue[i];
          ref_queue[i] = ref_queue[j];
          ref_queue[j] = tmp;
        end
      end
    end
    repeat (10) @(posedge CLK);

    for (int i = 0; i < 8; i++) begin
      dequeue();
      if (!o_empty) begin
        assert (o_data == ref_queue[0])
        else begin error_count++; $error("Dequeue: Node f value mismatch -> expected %d, got %d", ref_queue[0], o_data); end;
      end else begin
        assert (o_data == '0)
        else begin error_count++; $error("Dequeue: Node f value mismatch -> expected %d, got %d", '0, o_data); end;
      end
    end

    // Test Case 4: Successive increasing numbers in OB to IB+1
    $display("\nTest Case 4: Successive decreasing numbers from OB to IB+1");
    ref_queue.delete();
    
    u_SystolicArray.IB[0] = 16'd1;
    u_SystolicArray.IB[1] = 16'd2;
    u_SystolicArray.IB[2] = 16'd7;
    u_SystolicArray.IB[3] = 16'd13;
    u_SystolicArray.OB[0] = 16'd17;
    u_SystolicArray.OB[1] = 16'd16;
    u_SystolicArray.OB[2] = 16'd10;
    u_SystolicArray.OB[3] = 16'd11;
    u_SystolicArray.size = 4'd8;
    u_SystolicArray.size_next = 4'd8;

    @(posedge CLK);

    ref_queue.push_back(16'd1);
    ref_queue.push_back(16'd2);
    ref_queue.push_back(16'd7);
    ref_queue.push_back(16'd13);
    ref_queue.push_back(16'd17);
    ref_queue.push_back(16'd16);
    ref_queue.push_back(16'd10);
    ref_queue.push_back(16'd11);

    ref_size = 8;
    for (int i = 0; i < ref_size; i++) begin
      for (int j = i + 1; j < ref_size; j++) begin
        if (ref_queue[i] < ref_queue[j]) begin
          tmp = ref_queue[i];
          ref_queue[i] = ref_queue[j];
          ref_queue[j] = tmp;
        end
      end
    end
    repeat (10) @(posedge CLK);

    for (int i = 0; i < 8; i++) begin
      dequeue();
      if (!o_empty) begin
        assert (o_data == ref_queue[0])
        else begin error_count++; $error("Dequeue: Node f value mismatch -> expected %d, got %d", ref_queue[0], o_data); end;
      end else begin
        assert (o_data == '0)
        else begin error_count++; $error("Dequeue: Node f value mismatch -> expected %d, got %d", '0, o_data); end;
      end
    end

    if (error_count == 0) begin
      $display("\nTest completed!");
      $finish;
    end else begin
      $display("\n%0d error(s) detected during simulation.", error_count);
      $fatal(1, "Test FAILED with %0d error(s).", error_count);
    end
  end

  // Task to read root node
  task automatic dequeue();
    begin
      if (!o_empty) begin
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
      @(posedge CLK);
      i_wrt  = 0;
      i_read = 0;
      repeat (3) @(posedge CLK);
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
      
      @(posedge CLK);
      i_wrt  = 0;
      i_read = 0;
      repeat (2) @(posedge CLK); 
    end
  endtask

endmodule