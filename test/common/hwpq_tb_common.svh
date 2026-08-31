// shared testbench body for the HWPQ modules

// One parameterized body `included by a thin per-module shim. Replaces the per-module testbenches.

/*
  WHAT THE SHIM MUST PROVIDE (before the include):
    localparam int QUEUE_SIZE;   // queue depth
    localparam int DATA_WIDTH;   // element width
    localparam bit ENQ_ENA;      // 1 => enqueue-capable run, 0 => replace-only run

  WHAT THE SHIM MUST PROVIDE (after the include):
    - the DUT instantiation, wired to the signals declared below
    - assign settled = o_write_ready || o_read_ready;
      The settle wire lives in the shim so a module without a real handshake
      can later synthesize it from a counter without touching this body.

  OPTIONAL SHIM OVERRIDES (before the include):
    `define TB_CAPACITY <expr>
      Defaults to QUEUE_SIZE. The number of elements the DUT actually holds, which
      is what the readies are checked against. systolic_array reserves two slots
      as shift-chain margin (F-9), so its shim sets QUEUE_SIZE-2.

    `define TB_TRACKS_FULL 0
      Defaults to 1. Set 0 for a DUT whose o_write_ready does NOT drop when full.
      A replace-only DUT with no enqueue path (e.g. bram_tree_pipelined) gates nothing
      on fullness, so it reports o_write_ready = !busy and never advertises full. The
      ENQ_ENA=0 program's post-fill "queue is full" fcheck reads !o_write_ready, which
      only holds for DUTs that advertise fullness; this flag skips it for those that don't.

  HOW A RUN IS JUDGED PASS/FAIL:
    run_sim.sh treats the simulator's exit status as the only pass signal, so a failing
    run MUST end in $fatal -- that is the one construct iverilog exits nonzero on.
    $error alone does not: it prints, then $finish still exits 0 and the run reports PASS.
    This body already does the right thing (errors accumulate in error_count, and the
    final block turns a nonzero count into $fatal). Any standalone tb added alongside
    these shims has to follow the same rule.

  KEY INVARIANTS:
    - Drive stimulus and poll `settled` on the NEGEDGE. Sampling in the same timestep
      as the posedge reads stale state before the DUT's non-blocking updates propagate       
    - settled == !busy. Gate everything on it, not on either ready alone:
      replace needs neither space nor data, only quiescence, so gating it on
      o_write_ready breaks the ENQ_ENA=0 modules
    - o_data == '0 holds only when EMPTY AND NOT BUSY. Mid-settle o_data is stale,
      so the zero-check is guarded by if (o_read_ready). 
*/

`ifndef TB_TRACKS_FULL
  `define TB_TRACKS_FULL 1
`endif

// Elements the DUT will actually hold. QUEUE_SIZE everywhere except
// systolic_array, whose `full` is (size >= QUEUE_SIZE - 2) -- the two reserved
// slots are the shift chain's margin, and one is provably not enough (F-9).
`ifndef TB_CAPACITY
  `define TB_CAPACITY QUEUE_SIZE
`endif

logic i_CLK;
logic i_RSTn;

logic                  i_wrt;
logic                  i_read;
logic [DATA_WIDTH-1:0] i_data;

logic                  o_write_ready;
logic                  o_read_ready;
logic [DATA_WIDTH-1:0] o_data;

logic settled;

logic [DATA_WIDTH-1:0] ref_queue [$:QUEUE_SIZE-1];
int                    ref_queue_size = 0;

// Is the readies-vs-model check in force? An ENQ_ENA=0 DUT boots physically full
// of '1 placeholders while size resets to 0, and o_read_ready is gated on the
// head not being one, so !o_read_ready and a non-empty model coexist legitimately
// until the fill completes. Formal scopes the same window with ASSUME_FILL_FIRST
// (CH-4). Enqueue-capable builds never seat a placeholder, so it is always set.
bit fill_complete = 0;

logic [DATA_WIDTH-1:0] ref_queue_prev [$:QUEUE_SIZE-1];
int                    ref_queue_prev_size = 0;

logic [DATA_WIDTH-1:0] o_data_prev;

logic [DATA_WIDTH-1:0] random_value;
int                    random_operation;
int                    error_count = 0;

int stress_test_iters = 100 >  2 * QUEUE_SIZE ? 100 : 2 * QUEUE_SIZE;

typedef enum int {
  ENQUEUE = 1,
  DEQUEUE = 2,
  REPLACE = 3
} operation_t;

always #5 i_CLK <= ~i_CLK;

// Free-running cycle counter for cycles/op measurement
int cycle = 0;
always @(posedge i_CLK) if (i_RSTn) cycle <= cycle + 1;

// Quiescence polling
localparam int SETTLE_TIMEOUT = 10000;

task automatic poll_settled();
  int guard;
  guard = 0;
  while (!settled) begin
    @(negedge i_CLK);
    guard++;
    if (guard > SETTLE_TIMEOUT) begin
      $fatal(1, "poll_settled: DUT never settled after %0d cycles (o_write_ready=%0b o_read_ready=%0b)",
             SETTLE_TIMEOUT, o_write_ready, o_read_ready);
    end
  end
endtask

// Cycles/op measurement (pure reporting)
// Latency of an accepted op = posedges from the command-capture edge until the DUT is quiescent again.
// Replaces the hardcoded PERFORMANCE_FACTORS constants

int meas_count [1:3];
int meas_sum   [1:3];
int meas_min   [1:3];
int meas_max   [1:3];

task automatic record(input operation_t op, input int latency);
  if (meas_count[op] == 0 || latency < meas_min[op]) meas_min[op] = latency;
  if (latency > meas_max[op]) meas_max[op] = latency;
  meas_sum[op]   += latency;
  meas_count[op] += 1;
endtask

task automatic report_measurements();
  string name;
  $display("\n--- measured cycles/op (QUEUE_SIZE=%0d, ENQ_ENA=%0b) ---", QUEUE_SIZE, ENQ_ENA);
  $display("  op        n     min    mean     max");
  for (int op = ENQUEUE; op <= REPLACE; op++) begin
    case (op)
      ENQUEUE: name = "enqueue";
      DEQUEUE: name = "dequeue";
      REPLACE: name = "replace";
    endcase
    if (meas_count[op] > 0) begin
      $display("  %-8s %4d   %5d   %5.2f   %5d", name, meas_count[op],
               meas_min[op], real'(meas_sum[op]) / real'(meas_count[op]), meas_max[op]);
    end
  end
endtask

//  Reference-model helpers

task automatic rsort();  // descending: ref_queue[0] is the max (head)
  logic [DATA_WIDTH-1:0] temp_val;
  for (int i = 0; i < ref_queue_size; i++) begin
    for (int j = i + 1; j < ref_queue_size; j++) begin
      if (ref_queue[i] < ref_queue[j]) begin
        temp_val      = ref_queue[i];
        ref_queue[i]  = ref_queue[j];
        ref_queue[j]  = temp_val;
      end
    end
  end
endtask

// Deassert all command lines off the active edge (negedge contract).
// Also clear i_data so no stale operand lingers on the bus between commands
task automatic clear_cmd();
  i_wrt  = 0;
  i_read = 0;
  i_data = 0;
endtask

//  The readies, checked against the model (SIMULATION.md recommendation 3)
//
// F-2: the model's updates used to be gated on the DUT's own ready signals, so
// it could not disagree with the DUT. "Refuses work it should accept" was
// structurally uncatchable -- which is exactly F-7, and why simulation missed it.
//
// This inverts the dependency. The model owns its occupancy and the readies are
// an assertion about it, not an input to it.
task automatic check_readies(input string where);
  begin
    if (fill_complete) begin
      assert (o_read_ready == (ref_queue_size != 0))
      else begin error_count++; $error("Readies (%s): o_read_ready=%0b but the model holds %0d element(s)",
                                       where, o_read_ready, ref_queue_size); end
      if (`TB_TRACKS_FULL) begin
        assert (o_write_ready == (ref_queue_size != `TB_CAPACITY))
        else begin error_count++; $error("Readies (%s): o_write_ready=%0b but the model holds %0d of %0d",
                                         where, o_write_ready, ref_queue_size, `TB_CAPACITY); end
      end
    end
  end
endtask

//  Stimulus tasks, gated on settled

task automatic enqueue(input logic [DATA_WIDTH-1:0] value);
  int  t0;
  bit  accepted;
  begin
    poll_settled();  // the DUT refuses commands while settling
    check_readies("before enqueue");
    // The MODEL decides whether there is room; o_write_ready is asserted against
    // that decision rather than consulted for it (F-2).
    accepted = 0;
    if (ref_queue_size != `TB_CAPACITY) begin
      i_wrt  = 1;
      i_read = 0;
      i_data = value;
      // ENQ_ENA=0 DUTs ignore the enqueue, so the model must not change either.
      if (ENQ_ENA) begin
        ref_queue[ref_queue_size] = value;
        ref_queue_size++;
        rsort();
        accepted = 1;
      end
    end else begin
      $display("Enqueue: model is full, skipping enqueue");
    end
    t0 = cycle;
    @(posedge i_CLK);  // DUT captures the command here
    @(negedge i_CLK);  // release it off the edge
    clear_cmd();
    poll_settled();
    check_readies("after enqueue");
    if (accepted) record(ENQUEUE, cycle - t0);
  end
endtask

task automatic dequeue();
  int  t0;
  bit  accepted;
  begin
    poll_settled();
    check_readies("before dequeue");
    // The MODEL decides whether there is data; o_read_ready is asserted against
    // that decision rather than consulted for it (F-2).
    accepted = 0;
    if (ref_queue_size != 0) begin
      i_wrt  = 0;
      i_read = 1;
      i_data = 0;

      for (int i = 0; i < ref_queue_size - 1; i++) begin
        ref_queue[i] = ref_queue[i+1];
      end
      ref_queue[ref_queue_size-1] = '0;
      ref_queue_size--;
      accepted = 1;
    end else begin
      $display("Dequeue: model is empty, skipping dequeue");
    end
    t0 = cycle;
    @(posedge i_CLK);
    @(negedge i_CLK);
    clear_cmd();
    poll_settled();
    check_readies("after dequeue");
    if (accepted) record(DEQUEUE, cycle - t0);
  end
endtask

task automatic replace(input logic [DATA_WIDTH-1:0] value);
  int t0;
  begin
    poll_settled();
    check_readies("before replace");
    i_wrt  = 1;
    i_read = 1;
    i_data = value;
    if (ref_queue_size == 0) begin
      // Empty queue: replace degenerates to an insert. Decided by the model, not
      // by o_read_ready (F-2).
      ref_queue[ref_queue_size] = value;
      ref_queue_size++;
    end else begin
      ref_queue[0] = value;
    end
    rsort();
    t0 = cycle;
    @(posedge i_CLK);
    @(negedge i_CLK);
    clear_cmd();
    poll_settled();
    check_readies("after replace");
    record(REPLACE, cycle - t0);
  end
endtask

// Init-only replace: drives the command but leaves ref bookkeeping to caller
// (used to fill an ENQ_ENA=0 queue that resets full of sentinels).
task automatic replace_init(input logic [DATA_WIDTH-1:0] value);
  begin
    poll_settled();
    i_wrt  = 1;
    i_read = 1;
    i_data = value;
    @(posedge i_CLK);
    @(negedge i_CLK);
    clear_cmd();
    poll_settled();
  end
endtask

//  Reset
task automatic apply_reset();
  begin
    i_RSTn = 0;
    @(posedge i_CLK);
    i_RSTn = 1;
    @(posedge i_CLK);
    @(negedge i_CLK);  // enter the negedge contract before any poll
    // An ENQ_ENA=0 DUT comes back physically full of placeholders, so the
    // readies-vs-model check is out of force until the fill completes.
    fill_complete = ENQ_ENA;
  end
endtask

//  Reset during operation (SIMULATION.md recommendation 1)
//
// apply_reset() runs once, before any stimulus, so a defect that needs a reset
// arriving while the queue holds data is unreachable by construction. bram_tree's
// F-29 -- reset never restoring the node memory -- is exactly that shape, and no
// amount of extra stimulus finds it. These tasks assert reset at points inside a
// live operation and check the DUT comes back genuinely empty.
//
// Formal (F-15) proves every proven architecture recovers from a reset at any
// reachable moment, so this phase is expected to pass everywhere. A failure here
// is a real finding.

// After a reset the model holds nothing in BOTH builds: an ENQ_ENA=0 DUT boots
// physically full of '1 placeholders but logically empty.
task automatic model_reset();
  begin
    ref_queue      = {};
    ref_queue_size = 0;
  end
endtask

// Fill a freshly reset queue to capacity.
// ONLY valid immediately after model_reset(): the ENQ_ENA=0 arm assumes every
// slot still holds a placeholder, and it must fill completely before any read,
// because a resident placeholder outranks the payload and gates o_read_ready
// low (F-1, the fill-before-read contract).
task automatic refill_after_reset();
  begin
    for (int i = 0; i < QUEUE_SIZE; i++) begin
      random_value = $urandom_range(1, 1023);
      if (ENQ_ENA) begin
        enqueue(random_value);
      end else begin
        ref_queue.push_back(random_value);
        ref_queue_size++;
        replace_init(random_value);
      end
    end
    rsort();
    fill_complete = 1;
    poll_settled();
  end
endtask

// Assert reset `delay` negedges after a command is captured, so it lands INSIDE
// the settle window rather than between operations. delay=0 is the negedge
// immediately following the capture edge.
task automatic reset_during(input operation_t op, input int delay);
  begin
    poll_settled();
    case (op)
      ENQUEUE: begin i_wrt = 1; i_read = 0; i_data = $urandom_range(1, 1023); end
      DEQUEUE: begin i_wrt = 0; i_read = 1; i_data = 0;                       end
      REPLACE: begin i_wrt = 1; i_read = 1; i_data = $urandom_range(1, 1023); end
    endcase
    @(posedge i_CLK);  // the DUT captures the command here
    @(negedge i_CLK);
    clear_cmd();
    repeat (delay) @(negedge i_CLK);
    apply_reset();
    model_reset();
  end
endtask

// A reset must leave the queue with nothing to hand back, whatever it was doing.
task automatic check_reset_emptied(input string what);
  begin
    poll_settled();
    assert (!o_read_ready)
    else begin error_count++; $error("Reset (%s): queue still advertises data after reset", what); end
  end
endtask

// Refill and drain the whole queue in order. A reset that left stale nodes behind
// shows up here and nowhere else -- the head alone cannot distinguish a clean heap
// from one still holding pre-reset elements.
task automatic refill_and_drain_check(input string what);
  begin
    refill_after_reset();
    for (int i = 0; i < QUEUE_SIZE; i++) begin
      dequeue();
      if (o_read_ready)
        assert (o_data == ref_queue[0])
        else begin error_count++; $error("Reset (%s): drain step %0d -> expected %d, got %d", what, i, ref_queue[0], o_data); end
      else
        assert (o_data == '0)
        else begin error_count++; $error("Reset (%s): drain step %0d, now empty -> expected 0, got %d", what, i, o_data); end
    end
    assert (!o_read_ready)
    else begin error_count++; $error("Reset (%s): queue did not empty after %0d dequeues", what, QUEUE_SIZE); end
  end
endtask

// One sub-case: start clean, fill, reset at the point under test, verify.
task automatic reset_case(input operation_t op, input int delay, input int predrain, input string what);
  begin
    apply_reset();
    model_reset();
    refill_after_reset();
    for (int i = 0; i < predrain; i++) dequeue();
    reset_during(op, delay);
    check_reset_emptied(what);
    refill_and_drain_check(what);
  end
endtask

//  Impolite stimulus (SIMULATION.md recommendation 2)
//
// The tb walks up to every handshake violation and turns around: enqueue()
// prints "Queue full, skipping enqueue" and dequeue() consults o_read_ready
// first. The largest single category in FINDINGS.md lives in the space that
// politeness excludes -- F-7, F-8, F-30 and F-31 are all "a refused command is
// not inert". These tasks issue the command anyway.
//
// Note the shape of the assertion: it asserts that NOTHING happens. A refused
// command doing nothing is the contract (the F-8 principle); a refused command
// doing something is the defect.

// Drive a raw command with no ready check and no model update, then settle.
task automatic poke(input logic wrt, input logic read, input logic [DATA_WIDTH-1:0] value);
  begin
    poll_settled();
    i_wrt  = wrt;
    i_read = read;
    i_data = value;
    @(posedge i_CLK);
    @(negedge i_CLK);
    clear_cmd();
    poll_settled();
  end
endtask

// The DUT must be inert across an illegal command: head and both readies
// unmoved. The caller checks afterwards that a legal operation still works.
task automatic check_inert(input logic wrt, input logic read, input string what);
  logic [DATA_WIDTH-1:0] head_before;
  logic                  wr_before, rd_before;
  begin
    poll_settled();
    head_before = o_data;
    wr_before   = o_write_ready;
    rd_before   = o_read_ready;
    poke(wrt, read, $urandom_range(1, 1023));
    assert (o_data == head_before)
    else begin error_count++; $error("Inert (%s): head moved %d -> %d", what, head_before, o_data); end
    assert (o_write_ready == wr_before && o_read_ready == rd_before)
    else begin error_count++; $error("Inert (%s): readies moved {w=%0b,r=%0b} -> {w=%0b,r=%0b}",
                                     what, wr_before, rd_before, o_write_ready, o_read_ready); end
  end
endtask

//  Test programs
task automatic test_enq_enabled();
  begin
    $display("\n=== Testing with ENQ_ENA enabled ===");

    $display("\nInitializing by enqueue");
    for (int i = 0; i < QUEUE_SIZE; i++) begin
      random_value = $urandom_range(1, 1023);
      enqueue(random_value);
    end
    assert (!o_write_ready)
    else begin error_count++; $error("The queue should be filled by the initialization!"); end

    $display("\nTest Case 1: Dequeue Test (ENQ_ENA enabled)");
    for (int i = 0; i < QUEUE_SIZE / 2; i++) begin
      dequeue();
      if (o_read_ready)
        assert (o_data == ref_queue[0])
        else begin error_count++; $error("Dequeue: mismatch -> expected %d, got %d", ref_queue[0], o_data); end
      else
        assert (o_data == '0)
        else begin error_count++; $error("Dequeue: mismatch -> expected %d, got %d", '0, o_data); end
    end

    $display("\nTest Case 2: Enqueue Test (ENQ_ENA enabled)");
    for (int i = 0; i < QUEUE_SIZE / 2; i++) begin
      random_value = $urandom_range(1, 1023);
      enqueue(random_value);
      assert (o_data == ref_queue[0])
      else begin error_count++; $error("Enqueue: mismatch -> expected %d, got %d", ref_queue[0], o_data); end
    end
    assert (!o_write_ready)
    else begin error_count++; $error("The queue should be filled after enqueue!"); end

    $display("\nTest Case 3: Replace Test (ENQ_ENA enabled)");
    for (int i = 0; i < QUEUE_SIZE / 2; i++) begin
      random_value = $urandom_range(1, 1023);
      replace(random_value);
      assert (o_data == ref_queue[0])
      else begin error_count++; $error("Replace: mismatch -> expected %d, got %d", ref_queue[0], o_data); end
    end

    $display("\nTest Case 4: Stress Test (ENQ_ENA enabled)");
    for (int i = 0; i < stress_test_iters; i++) begin
      random_operation = $urandom_range(1, 3);
      case (random_operation)
        ENQUEUE: begin
          random_value = $urandom_range(1, 1023);
          enqueue(random_value);
          assert (o_data == ref_queue[0])
          else begin error_count++; $error("Random Enqueue: mismatch -> expected %d, got %d", ref_queue[0], o_data); end
        end
        DEQUEUE: begin
          dequeue();
          if (o_read_ready)
            assert (o_data == ref_queue[0])
            else begin error_count++; $error("Random Dequeue: mismatch -> expected %d, got %d", ref_queue[0], o_data); end
          else
            assert (o_data == '0)
            else begin error_count++; $error("Random Dequeue: mismatch -> expected %d, got %d", '0, o_data); end
        end
        REPLACE: begin
          random_value = $urandom_range(1, 1023);
          replace(random_value);
          assert (o_data == ref_queue[0])
          else begin error_count++; $error("Random Replace: mismatch -> expected %d, got %d", ref_queue[0], o_data); end
        end
      endcase
    end
  end
endtask

task automatic test_enq_disabled();
  begin
    $display("\n=== Testing with ENQ_ENA disabled ===");

    $display("\nInitializing by replace");
    for (int i = 0; i < QUEUE_SIZE; i++) begin
      random_value = $urandom_range(1, 1023);
      ref_queue.push_back(random_value);
      ref_queue_size++;
      replace_init(random_value);
    end
    rsort();
    fill_complete = 1;
    poll_settled();

    $display("\nTest Case 5: Dequeue Test (ENQ_ENA disabled)");
    // Only DUTs that advertise fullness drop o_write_ready when full (see TB_TRACKS_FULL).
    if (`TB_TRACKS_FULL) begin
      assert (!o_write_ready)
      else begin error_count++; $error("The queue should be filled by the initialization!"); end
    end
    for (int i = 0; i < QUEUE_SIZE / 2; i++) begin
      dequeue();
      if (o_read_ready)
        assert (o_data == ref_queue[0])
        else begin error_count++; $error("Dequeue: mismatch -> expected %d, got %d", ref_queue[0], o_data); end
      else
        assert (o_data == 'd0)
        else begin error_count++; $error("Dequeue: mismatch -> expected %d, got %d", 'd0, o_data); end
    end

    $display("\nTest Case 6: Enqueue Test (ENQ_ENA disabled — should be a no-op)");
    o_data_prev         = o_data;
    ref_queue_prev      = ref_queue;
    ref_queue_prev_size = ref_queue_size;
    for (int i = 0; i < QUEUE_SIZE / 2; i++) begin
      random_value = $urandom_range(1, 1023);
      enqueue(random_value);
      assert (o_data == ref_queue[0])
      else begin error_count++; $error("Enqueue: mismatch -> expected %d, got %d", ref_queue[0], o_data); end
    end
    assert (o_data == o_data_prev)
    else begin error_count++; $error("The queue should not have changed!"); end
    begin
      bit error_flag;
      error_flag = 0;
      if (ref_queue_size != ref_queue_prev_size) begin
        error_flag = 1;
      end else begin
        for (int i = 0; i < ref_queue_size; i++)
          if (ref_queue[i] != ref_queue_prev[i]) error_flag = 1;
      end
      assert (!error_flag)
      else begin error_count++; $error("The queue should not have changed!"); end
    end
    assert (o_write_ready && o_read_ready)
    else begin error_count++; $error("The queue should not do anything!"); end

    $display("\nTest Case 7: Replace Test (ENQ_ENA disabled)");
    for (int i = 0; i < QUEUE_SIZE / 2; i++) begin
      random_value = $urandom_range(1, 1023);
      replace(random_value);
      assert (o_data == ref_queue[0])
      else begin error_count++; $error("Replace: mismatch -> expected %d, got %d", ref_queue[0], o_data); end
    end

    $display("\nTest Case 8: Stress Test (ENQ_ENA disabled)");
    for (int i = 0; i < stress_test_iters; i++) begin
      random_operation = $urandom_range(2, 3);
      case (random_operation)
        DEQUEUE: begin
          dequeue();
          if (o_read_ready)
            assert (o_data == ref_queue[0])
            else begin error_count++; $error("Random Dequeue: mismatch -> expected %d, got %d", ref_queue[0], o_data); end
          else
            assert (o_data == '0)
            else begin error_count++; $error("Random Dequeue: mismatch -> expected %d, got %d", '0, o_data); end
        end
        REPLACE: begin
          random_value = $urandom_range(1, 1023);
          replace(random_value);
          assert (o_data == ref_queue[0])
          else begin error_count++; $error("Random Replace: mismatch -> expected %d, got %d", ref_queue[0], o_data); end
        end
      endcase
    end
  end
endtask

task automatic test_reset_midstream();
  begin
    $display("\nTest Case 9: Reset during operation");

    // Quiescent reset with the queue full.
    apply_reset();
    model_reset();
    refill_after_reset();
    apply_reset();
    model_reset();
    check_reset_emptied("full, quiescent");
    refill_and_drain_check("full, quiescent");

    // Reset landing inside a live operation, at three depths into the settle.
    for (int d = 0; d < 3; d++) begin
      int delay;
      delay = (d == 2) ? 3 : d;
      reset_case(DEQUEUE, delay, 0, $sformatf("mid-dequeue, delay %0d", delay));
      reset_case(REPLACE, delay, 0, $sformatf("mid-replace, delay %0d", delay));
      // An enqueue on a full queue is refused, so make room first. ENQ_ENA=0
      // DUTs have no enqueue datapath and a half-filled one sits behind the
      // fill-before-read contract, so this arm is enqueue-capable builds only.
      if (ENQ_ENA)
        reset_case(ENQUEUE, delay, QUEUE_SIZE / 2, $sformatf("mid-enqueue, delay %0d", delay));
    end
  end
endtask

task automatic test_impolite();
  begin
    $display("\nTest Case 10: Commands the DUT says it will not accept");

    // A dequeue on an empty queue. ENQ_ENA=1 boots all-zero; ENQ_ENA=0 boots
    // physically full of '1 placeholders but logically empty and gates
    // o_read_ready on the head not being one (F-1). Both must refuse the read.
    apply_reset();
    model_reset();
    assert (!o_read_ready)
    else begin error_count++; $error("Impolite: a freshly reset queue advertises data"); end
    for (int i = 0; i < 3; i++) check_inert(1'b0, 1'b1, "dequeue on empty");
    refill_and_drain_check("after dequeue-on-empty");

    // An enqueue on a full queue. Only meaningful where !o_write_ready really
    // means full -- see TB_TRACKS_FULL. An ENQ_ENA=0 DUT has no enqueue
    // datapath, so the check is trivially true there and kept for uniformity.
    if (`TB_TRACKS_FULL) begin
      apply_reset();
      model_reset();
      refill_after_reset();
      assert (!o_write_ready)
      else begin error_count++; $error("Impolite: the queue did not fill, so enqueue-on-full is untested"); end
      for (int i = 0; i < 3; i++) check_inert(1'b1, 1'b0, "enqueue on full");
      // A clobbering enqueue leaves a valid-looking heap of the wrong contents,
      // so drain the whole thing in order rather than reading the head.
      for (int i = 0; i < QUEUE_SIZE; i++) begin
        dequeue();
        if (o_read_ready)
          assert (o_data == ref_queue[0])
          else begin error_count++; $error("Impolite: post enqueue-on-full drain step %0d -> expected %d, got %d", i, ref_queue[0], o_data); end
        else
          assert (o_data == '0)
          else begin error_count++; $error("Impolite: post enqueue-on-full drain step %0d, now empty -> expected 0, got %d", i, o_data); end
      end
      assert (!o_read_ready)
      else begin error_count++; $error("Impolite: queue did not empty after enqueue-on-full"); end
    end
  end
endtask

// Terminal drain phase, runs for both ENQ_ENA modes. Empties the queue completely to
// exercise the empty-state o_data branch and the replace-into-empty insert path, which
// the fixed-length stress loop cannot reliably reach on the larger queues
task automatic test_drain();
  begin
    $display("\nDrain Phase: dequeue to empty");
    // Bounded to QUEUE_SIZE+1 iterations (iverilog -g2012 has no break)
    for (int i = 0; o_read_ready && i <= QUEUE_SIZE; i++) begin
      dequeue();
      if (o_read_ready)
        assert (o_data == ref_queue[0])
        else begin error_count++; $error("Drain dequeue: mismatch -> expected %d, got %d", ref_queue[0], o_data); end
      else
        assert (o_data == '0)
        else begin error_count++; $error("Drain dequeue (now empty): expected 0, got %d", o_data); end
    end

    assert (!o_read_ready)
    else begin error_count++; $error("Drain: queue did not empty / o_read_ready should be low"); end
    assert (o_data == '0)
    else begin error_count++; $error("Drain: empty o_data should be 0, got %d", o_data); end

    random_value = $urandom_range(1, 1023);
    replace(random_value);
    assert (o_read_ready)
    else begin error_count++; $error("Drain: replace on empty should insert (o_read_ready stayed low)"); end
    assert (o_data == random_value)
    else begin error_count++; $error("Drain: replace on empty -> expected %d, got %d", random_value, o_data); end

    dequeue();
    assert (!o_read_ready)
    else begin error_count++; $error("Drain: queue should be empty after removing the inserted element"); end
    assert (o_data == '0)
    else begin error_count++; $error("Drain: empty o_data should be 0 after final dequeue, got %d", o_data); end
  end
endtask

initial begin
  i_CLK  = 0;
  i_wrt  = 0;
  i_read = 0;
  i_data = 0;
  ref_queue      = {};
  ref_queue_prev = {};

  apply_reset();

  if (ENQ_ENA) test_enq_enabled();
  else         test_enq_disabled();

  test_reset_midstream();

  test_impolite();

  test_drain();

  report_measurements();

  if (error_count == 0) begin
    $display("\nTest completed!");
    $finish;
  end else begin
    $display("\n%0d error(s) detected during simulation.", error_count);
    $fatal(1, "Test FAILED with %0d error(s).", error_count);
  end
end
