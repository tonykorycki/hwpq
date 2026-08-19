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

# KNOWN FAILING, deliberately recorded rather than assumed away -- see F-1 in
# formal/README.md. A replace-only queue reports non-empty as soon as the first
# replace lands, but the head is still an all-ones placeholder, so it advertises
# data it cannot deliver and the payload underneath can be stranded.
#
# Recorded here instead of adding an assumption because an assumption would
# HIDE the behaviour: everything would prove, vacuously, in exactly the region
# where the bug lives. This way the properties still run and still fail, the
# run is still green, and if the RTL is ever fixed the harness reports
# "expected cex that did NOT fire" and forces this list to be updated.
set HWPQ_EXPECT_CEX    {a_no_loss a_occ_empty_agrees}

source formal/tcl/common.tcl
hwpq_prove_and_exit
