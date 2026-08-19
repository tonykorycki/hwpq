# JasperGold proof: register_array, ENQ_ENA=0 (replace-only build)
#
# Run from the REPO ROOT. Use formal/run.sh rather than invoking this directly.
#
# A SEPARATE RUN, NOT A VARIANT. Reset fills the array with all-ones while size
# resets to 0 (register_array.sv:56-62), so the queue boots physically full but
# logically empty and each replace evicts one placeholder. The reachable command
# set differs too: there is no enqueue datapath, so a bare write is not a
# command this build has.

clear -all

set HWPQ_SELFTEST 0
if {[info exists ::env(HWPQ_SELFTEST)]} { set HWPQ_SELFTEST $::env(HWPQ_SELFTEST) }

# ---- 1. sources -------------------------------------------------------------
set src {
    hwpq/register_array/src/register_array.sv
    formal/spec/hwpq_spec.sv
    formal/bind/register_array_bind.sv
}
if {$HWPQ_SELFTEST} {
    puts "### SELF-TEST MODE: the plumbing property is deliberately inverted."
    analyze -sv12 -define HWPQ_SELFTEST {*}$src
} else {
    analyze -sv12 {*}$src
}

# ---- 2. elaborate SMALL -----------------------------------------------------
# Same sizes as the ENQ_ENA=1 run; only the reset fill and the command set move.
elaborate -top register_array \
    -parameter QUEUE_SIZE 4 \
    -parameter DATA_WIDTH 3 \
    -parameter ENQ_ENA    0

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_RSTn

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        register_array_enq0
set HWPQ_ALLOW_BOUNDED 0

# F-1 is assumed away, not recorded: ASSUME_FILL_FIRST in the spec constrains
# this build to the initialisation convention its callers follow (fill the queue
# before reading from it). That is hole CH-4 -- see formal/README.md. The cover
# set is what proves the assumption did not strangle the design.
set HWPQ_EXPECT_CEX    {}

source formal/tcl/common.tcl
hwpq_prove_and_exit
