# JasperGold proof: register_array_pipelined
#
# Run from the REPO ROOT. Use formal/run.sh rather than invoking this directly.
#
# Sequential, but unlike register_tree it has no settle timer: head_valid is a
# data-adaptive compare, `queue[0] >= queue[1]` (:198). That makes the
# black-box ordering properties the interesting ones here - a root-local
# detector is only obviously sound when nothing can outrank the root while
# hidden below it, and a_head_is_max is what decides whether that holds.

clear -all

set HWPQ_SELFTEST 0
if {[info exists ::env(HWPQ_SELFTEST)]} { set HWPQ_SELFTEST $::env(HWPQ_SELFTEST) }

# ---- 1. sources -------------------------------------------------------------
set src {
    hwpq/register_array_pipelined/src/register_array_pipelined.sv
    formal/spec/hwpq_spec.sv
    formal/bind/register_array_pipelined_bind.sv
}
if {$HWPQ_SELFTEST} {
    puts "### SELF-TEST MODE: the self-test property is deliberately unprovable."
    analyze -sv12 -define HWPQ_SELFTEST {*}$src
} else {
    analyze -sv12 {*}$src
}

# ---- 2. elaborate SMALL -----------------------------------------------------
# QUEUE_SIZE must be EVEN: the design pairs elements
# (PAIR_COUNT = QUEUE_SIZE/2, :41).
elaborate -top register_array_pipelined \
    -parameter QUEUE_SIZE 4 \
    -parameter DATA_WIDTH 3 \
    -parameter ENQ_ENA    1

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_RSTn

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        register_array_pipelined
set HWPQ_ALLOW_BOUNDED 0
set HWPQ_EXPECT_CEX    {}

source formal/tcl/common.tcl
hwpq_prove_and_exit
