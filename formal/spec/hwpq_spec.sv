`default_nettype none
// portable specification for the HWPQ library
//
// Bound to a DUT from outside (formal/bind/). Reads just the six shared
// interface ports, so the same file attaches to every architecture in the library
//
// Portability Notes:
// - Every property carries its own explicit `@(posedge i_CLK)` and
//   `disable iff (!i_RSTn)` instead of using `default clocking` / `default disable iff`,
//   to avoid relying on tool support, and unblock local testing
// - `var` on the inputs keeps the ports single-driver under `default_nettype none`.
//
// CONTENTS:
//   the interface contract we promise the DUT (assumptions)
//   progress and handshake asserts
//   occupancy, against the spec's own count of resident elements
//   ordering, via a symbolic tracked value
//   the anti-vacuity cover set

module hwpq_spec #(
    // These must match the elaborated DUT. The bind file passes them
    // explicitly - dont rely on the defaults here
    parameter int QUEUE_SIZE = 4,
    parameter int DATA_WIDTH = 3,
    parameter bit ENQ_ENA    = 1,

    // Does the DUT have a busy state
    // 0 = single-cycle design; `settled` is constant 1
    // 1 = sequential design; `settled` drops while an operation is in flight
    parameter bit HAS_BUSY = 1,

    // Upper bound, in cycles, on how long the DUT may stay unsettled
    parameter int MAX_SETTLE = 1,

    // Applies am_no_cmd_while_busy, which hides any bug needing a command
    // mid-operation (hole CH-2). Set 0 for a second, ungated run.
    parameter bit NO_CMD_WHILE_BUSY = 1,

    // Assume a replace-only queue is filled before anything is read from it -
    // the initialisation convention its callers are expected to follow. Set 0
    // to drop the assumption and reproduce F-1. Ignored when ENQ_ENA=1, which
    // has a real enqueue path and no placeholders to strand.
    parameter bit ASSUME_FILL_FIRST = 1,

    // Does o_write_ready actually drop when the queue is full. The mirror of
    // the testbench's TB_TRACKS_FULL: a replace-only DUT with no enqueue path
    // gates nothing on fullness and reports o_write_ready = !busy. Not the same
    // question as ENQ_ENA - register_array with ENQ_ENA=0 still tracks full.
    parameter bit HAS_FULL = 1
) (
    input var logic                  i_CLK,
    input var logic                  i_RSTn,
    input var logic                  i_wrt,
    input var logic                  i_read,
    input var logic [DATA_WIDTH-1:0] i_data,
    input var logic                  o_write_ready,
    input var logic                  o_read_ready,
    input var logic [DATA_WIDTH-1:0] o_data
);

  // A module is either idle - in which case it cannot be simultaneously full
  // and empty, so at least one ready is high - or it is mid-operation, in which case
  // the sequential designs drop both. Same wire the simulation harness uses
  wire settled = o_write_ready || o_read_ready;

  // Command decode, straight off {i_wrt, i_read}. `replace` deliberately needs
  // NEITHER ready - only quiescence - so it is never gated on one.
  wire cmd_enqueue = i_wrt && !i_read;
  wire cmd_dequeue = !i_wrt && i_read;
  wire cmd_replace = i_wrt && i_read;


  // ---------------------------------------------------------------------------
  // The interface contract (assumptions)
  //
  // EVERY ASSUMPTION IS A HOLE. Over-assume and the design can no longer reach
  // the interesting states, every assert passes vacuously, and the summary
  // table looks identical to a real proof. The cover set below is the detector.
  // ---------------------------------------------------------------------------

  // '0 and all-ones are reserved sentinels, not payloads. Hole CH-1; the
  // behaviour when they ARE driven is characterised in Appendix A.
  am_payload_legal : assume property (@(posedge i_CLK) disable iff (!i_RSTn)
      i_data != '0 && i_data != '1);

  generate
    // Guarded on HAS_BUSY as well as the parameter: with no busy state the
    // antecedent is unsatisfiable, so this constrains nothing and only leaves
    // an UNREACHABLE precondition cover behind.
    if (HAS_BUSY && NO_CMD_WHILE_BUSY) begin : g_no_cmd_while_busy
      am_no_cmd_while_busy : assume property (@(posedge i_CLK) disable iff (!i_RSTn)
          !settled |-> !i_wrt && !i_read);
    end

    // A replace-only build has no enqueue datapath, so a bare write is not a
    // command it has. Keeps the reachable command set honest.
    if (!ENQ_ENA) begin : g_replace_only
      am_no_enqueue_cmd : assume property (@(posedge i_CLK) disable iff (!i_RSTn)
          !cmd_enqueue);
    end

    // The initialisation convention, as an assumption: do not read from a
    // replace-only queue until it has been filled once.
    //
    // A replace-only queue boots full of all-ones placeholders with size 0, and
    // a payload sorts BELOW them, so until the placeholders are evicted a
    // dequeue pops a placeholder rather than data - while `size` decrements
    // anyway. That is F-1. This assumption keeps the proof inside the region
    // the library actually supports; it does not make the behaviour go away.
    //
    // HOLE CH-4: any bug that needs a read during the fill phase is now
    // unreachable. Set ASSUME_FILL_FIRST=0 for an ungated run.
    if (!ENQ_ENA && ASSUME_FILL_FIRST) begin : g_fill_first
      // `settled &&` is load-bearing. o_write_ready is !full AND not-busy, so a
      // bare !o_write_ready also latches on the first BUSY cycle - which on a
      // sequential module means the latch fires almost immediately and the
      // assumption stops constraining anything. Gating on settled is what makes
      // this mean "reported full while quiescent". It made no difference on the
      // combinational modules, which is exactly why it survived there.
      logic filled_once;
      always_ff @(posedge i_CLK or negedge i_RSTn) begin
        if (!i_RSTn) filled_once <= 1'b0;
        else if (settled && !o_write_ready) filled_once <= 1'b1;
      end

      am_fill_before_read : assume property (@(posedge i_CLK) disable iff (!i_RSTn)
          !filled_once |-> !cmd_dequeue);
    end
  endgenerate


  // ---------------------------------------------------------------------------
  // Progress and handshake
  // ---------------------------------------------------------------------------

  // "At the first settled cycle at or after the next one, `cond` holds."
  //
  // This is what keeps the handshake asserts portable: a plain |=> is only
  // sound at MAX_SETTLE 1, and on a sequential module lands on a busy cycle
  // where the consequent is trivially true. Collapses back to |=> when
  // `settled` is constant, so do NOT fork it per HAS_BUSY.
  property p_at_next_settle(trigger, cond);
    @(posedge i_CLK) disable iff (!i_RSTn)
    trigger |=> (!settled)[*0:MAX_SETTLE] ##1 (settled && cond);
  endproperty

  // PROGRESS: the DUT always returns to a commandable state within MAX_SETTLE.
  // The property simulation is worst at, and a deadlock invalidates every other
  // result - a wedged queue trivially satisfies "the head is always correct".
  //
  // Only meaningful with a busy state; a_plumbing below is the stronger
  // statement that replaces it when there is none. Exactly one of the two
  // exists in any given build.
  generate
    if (HAS_BUSY) begin : g_progress
      a_progress : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
          !settled |-> ##[1:MAX_SETTLE] settled);
    end
  endgenerate

  // A refused command has no effect: the ready does not flip in your favour.
  // There is no "accepted" signal on the interface and we do not need one -
  // occupancy modelling is a separate concern. Both exclude `replace` by
  // construction, which is what stops them fighting the ENQ_ENA=0 modules.
  generate
    // Needs both: the command has to exist, and !o_write_ready has to actually
    // mean "full" rather than "busy" or the antecedent is unreachable.
    if (ENQ_ENA && HAS_FULL) begin : g_enq_handshake
      a_no_enq_when_full : assert property (p_at_next_settle(
          settled && !o_write_ready && cmd_enqueue, !o_write_ready));
    end
  endgenerate

  a_no_deq_when_empty : assert property (p_at_next_settle(
      settled && !o_read_ready && cmd_dequeue, !o_read_ready));


  // For a DUT with no busy state, `settled` is constant 1. Proves the bind
  // attached and the DUT is reachable at all.
  generate
    if (!HAS_BUSY) begin : g_plumbing
      a_plumbing : assert property (@(posedge i_CLK) disable iff (!i_RSTn) settled);
    end
  endgenerate

`ifdef HWPQ_SELFTEST
  // Deliberately unprovable, and present in EVERY build. run.sh --selftest
  // relies on this to show the harness can still report failure.
  //
  // It used to work by inverting a_plumbing, which only exists when HAS_BUSY=0 -
  // so on a sequential module there was nothing to break, --selftest proved
  // everything, exited 0, and reported that the harness could not report
  // failure. Keying the check to a configuration-specific property skipped it
  // on exactly the modules where a proof is hardest to trust.
  a_selftest_must_fail : assert property (@(posedge i_CLK) disable iff (!i_RSTn) 1'b0);
`endif


  // ---------------------------------------------------------------------------
  // Accepted commands
  //
  // The DUTs gate acceptance internally on the matching ready, so the same
  // decode reconstructs it from outside. `replace` needs neither ready, only
  // quiescence. Everything below counts on these and nothing else.
  // ---------------------------------------------------------------------------

  wire acc_enq = settled && ENQ_ENA && cmd_enqueue && o_write_ready;
  wire acc_deq = settled && cmd_dequeue && o_read_ready;
  wire acc_rep = settled && cmd_replace;

  // Does the head hold a real element, as opposed to a padding '0 or one of the
  // all-ones placeholders an ENQ_ENA=0 build resets into. Both sentinels are
  // excluded from the payload alphabet, so this one predicate covers every
  // build: a replace that evicts a non-element is an insert, not a swap.
  wire head_is_element = (o_data != '0) && (o_data != '1);


  // ---------------------------------------------------------------------------
  // Occupancy
  //
  // How many elements the spec believes are resident, from accepted commands
  // alone, checked against what the DUT advertises. Catches over-acceptance at
  // the moment it happens, and - unlike the ordering properties below, which
  // say nothing about o_write_ready - catches a DUT that refuses work while it
  // still has room.
  // ---------------------------------------------------------------------------

  // One bit of headroom past QUEUE_SIZE so over-acceptance is observable
  // instead of wrapping around into a legal-looking value.
  localparam int OCC_W = $clog2(QUEUE_SIZE + 1) + 1;

  logic [OCC_W-1:0] occ, occ_next;

  always_comb begin
    occ_next = occ;
    // A dequeue only removes an ELEMENT if the head was one. In a replace-only
    // build the head can still be an all-ones placeholder, and popping that
    // costs the queue no user data.
    if (acc_enq) occ_next = occ + OCC_W'(1);
    else if (acc_deq && head_is_element && occ > 0) occ_next = occ - OCC_W'(1);
    else if (acc_rep && !head_is_element) occ_next = occ + OCC_W'(1);
  end

  always_ff @(posedge i_CLK or negedge i_RSTn) begin
    if (!i_RSTn) occ <= '0;
    else occ <= occ_next;
  end

  a_occ_bounded : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled |-> occ <= OCC_W'(QUEUE_SIZE));

  a_occ_empty_agrees : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled |-> ((occ == 0) == !o_read_ready));

  generate
    if (HAS_FULL) begin : g_occ_full
      a_occ_full_agrees : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
          settled |-> ((occ == OCC_W'(QUEUE_SIZE)) == !o_write_ready));
    end
  endgenerate


  // ---------------------------------------------------------------------------
  // Ordering
  //
  // Rather than a golden sorted array - QUEUE_SIZE x DATA_WIDTH bits of extra
  // state, which stalls the proof on anything but the smallest instance - pick
  // ONE value and count how many copies the queue should hold. `tv` is an
  // unconstrained constant, so proving the properties for it proves them for
  // every value at once. A handful of counter bits does the work of a full
  // reference model.
  //
  // The three asserts are complete together. Let h be o_data:
  //   a_head_is_max says h >= every resident value.
  //   a_head_present, contrapositive, says h is itself resident (take tv = h).
  //   Together: h is resident AND outranks everything resident, which is
  //   exactly "the head is the maximum" - not an approximation of it.
  //   a_no_loss closes the escape hatch: both of the others are guarded on
  //   o_read_ready, so without it a DUT that eats an element and then reports
  //   empty satisfies them vacuously.
  // ---------------------------------------------------------------------------

  // Deliberately undriven, so the tool is free to pick any value and must make
  // the properties hold for all of them. ($anyconst would say this directly but
  // is not accepted by every Jasper parser; an undriven net plus a stability
  // assumption is the portable spelling.)
  logic [DATA_WIDTH-1:0] tv;

  am_tv_stable : assume property (@(posedge i_CLK) disable iff (!i_RSTn)
      ##1 $stable(tv));

  // tv has to be a value the queue could actually be holding, or the count is
  // pinned at zero and every property below passes without saying anything.
  // c_tracked_present is what detects that.
  am_tv_legal : assume property (@(posedge i_CLK) disable iff (!i_RSTn)
      tv != '0 && tv != '1);

  localparam int CNT_W = $clog2(QUEUE_SIZE + 1) + 1;

  logic [CNT_W-1:0] cnt, cnt_next;

  // A replace that evicts a non-element pops nothing, but it needs no special
  // case: o_data is then a sentinel, and am_tv_legal already excludes both, so
  // the decrement cannot fire.
  always_comb begin
    cnt_next = cnt;
    if (acc_enq && i_data == tv) cnt_next = cnt + CNT_W'(1);
    else if (acc_deq && o_data == tv && cnt > 0) cnt_next = cnt - CNT_W'(1);
    else if (acc_rep) begin
      case ({i_data == tv, o_data == tv})
        2'b10:   cnt_next = cnt + CNT_W'(1);
        2'b01:   cnt_next = (cnt > 0) ? cnt - CNT_W'(1) : cnt;
        default: cnt_next = cnt;
      endcase
    end
  end

  always_ff @(posedge i_CLK or negedge i_RSTn) begin
    if (!i_RSTn) cnt <= '0;
    else cnt <= cnt_next;
  end

  // no silent loss: if a copy should be resident, the DUT must not claim empty
  a_no_loss : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && cnt > 0 |-> o_read_ready);

  // the head outranks everything resident
  a_head_is_max : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && o_read_ready && cnt > 0 |-> o_data >= tv);

  // the head is an element that is genuinely present
  a_head_present : assert property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && o_read_ready && cnt == 0 |-> o_data != tv);


  // ---------------------------------------------------------------------------
  // Anti-vacuity cover set. NOT OPTIONAL.
  //
  // If any of these comes back UNREACHABLE an assumption has strangled the
  // design and every `proven` above it is worthless. common.tcl fails the run
  // on one rather than leaving it to be noticed by eye.
  // ---------------------------------------------------------------------------

  // if this comes back unreachable the design cannot move and every `proven` above it is worthless
  c_plumbing_alive : cover property (@(posedge i_CLK) disable iff (!i_RSTn) o_read_ready);

  generate
    if (ENQ_ENA) begin : g_enq_covers
      c_enqueue_fires : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
          settled && o_write_ready && cmd_enqueue);
    end

    // Gated on HAS_FULL, NOT on ENQ_ENA: a replace-only register_array still
    // fills up, one evicted placeholder at a time. Only a DUT that never
    // advertises fullness at all has to skip these.
    if (HAS_FULL) begin : g_full_covers
      c_reaches_full : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
          settled && !o_write_ready);
      c_deq_from_full : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
          settled && !o_write_ready && cmd_dequeue);
    end
  endgenerate

  c_dequeue_fires : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && o_read_ready && cmd_dequeue);

  c_replace_fires : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && cmd_replace);

  c_reaches_empty : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && !o_read_ready);

  // These two guard the tracking mechanism itself. If tv ever gets pinned to a
  // value the queue cannot hold, the count sticks at zero and every ordering
  // property above passes while checking nothing - a fully green table that
  // looks exactly like success.
  c_tracked_present : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && cnt > 0);

  c_tracked_two : cover property (@(posedge i_CLK) disable iff (!i_RSTn)
      settled && cnt > 1);

endmodule

`default_nettype wire
