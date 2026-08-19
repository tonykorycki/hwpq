# JasperGold proof: systolic_array
#
# Run from the REPO ROOT. Use formal/run.sh rather than invoking this directly.
#
# The fifth architecture, and the first whose readies are not a clean busy
# decode over a settled/unsettled state machine. See formal/bind/
# systolic_array_bind.sv for why HAS_FULL=0 and why MAX_SETTLE is a literal.
#
# Two things to watch on the first run, both predicted from the RTL rather than
# observed:
#
#  1. The DUT gates acceptance on its INTERNAL full/empty (systolic_array.sv:
#     241-252), not on the readies it advertises - and the two use different
#     thresholds. The spec reconstructs acceptance from o_write_ready /
#     o_read_ready, which is exact for the four register designs but may
#     undercount here. An occupancy assert failing is the expected symptom.
#  2. `size` is declared `int` (:72-73) - 32 bits of state where 4 would do.
#     If the proof will not converge, that is the first thing to look at.

clear -all

set HWPQ_SELFTEST 0
if {[info exists ::env(HWPQ_SELFTEST)]} { set HWPQ_SELFTEST $::env(HWPQ_SELFTEST) }

# ---- 1. sources -------------------------------------------------------------
set src {
    hwpq/systolic_array/src/systolic_array.sv
    formal/spec/hwpq_spec.sv
    formal/bind/systolic_array_bind.sv
}
if {$HWPQ_SELFTEST} {
    puts "### SELF-TEST MODE: the self-test property is deliberately unprovable."
    analyze -sv12 -define HWPQ_SELFTEST {*}$src
} else {
    analyze -sv12 {*}$src
}

# ---- 2. elaborate SMALL -----------------------------------------------------
# QUEUE_SIZE must be EVEN: the array is split into an input and an output buffer
# of HALF_SIZE = QUEUE_SIZE/2 each. It must also leave room for the shifting
# network's slack slots, which cost 3 of the nominal size - so 8 is the smallest
# value with any usable capacity at all (effective capacity 5).
elaborate -top systolic_array \
    -parameter QUEUE_SIZE 8 \
    -parameter DATA_WIDTH 3

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_RSTn

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        systolic_array
set HWPQ_ALLOW_BOUNDED 0
set HWPQ_EXPECT_CEX    {}

source formal/tcl/common.tcl
hwpq_prove_and_exit
