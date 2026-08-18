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
    parameter int MAX_SETTLE = 1
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


  // For a DUT with no busy state, `settled` is constant 1. This proves everything binded correctly
  // HWPQ_SELFTEST inverts it into a guaranteed failure. This proves the harness can report failure
  generate
    if (!HAS_BUSY) begin : g_plumbing
`ifdef HWPQ_SELFTEST
      a_plumbing : assert property (@(posedge i_CLK) disable iff (!i_RSTn) !settled);
`else
      a_plumbing : assert property (@(posedge i_CLK) disable iff (!i_RSTn) settled);
`endif
    end
  endgenerate

  // if this comes back unreachable the design cannot move and every `proven` above it is worthless
  c_plumbing_alive : cover property (@(posedge i_CLK) disable iff (!i_RSTn) o_read_ready);

  // Parameters not yet consumed
  localparam int UNUSED_GUARD = QUEUE_SIZE + DATA_WIDTH + int'(ENQ_ENA) + MAX_SETTLE;
  if (UNUSED_GUARD < 0) begin : g_never
    // never elaborated; exists only to consume the parameters
  end

endmodule

`default_nettype wire
