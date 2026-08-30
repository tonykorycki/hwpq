# JasperGold proof: register_array_pipelined, ENQ_ENA=0 (replace-only build)
#
# Run from the REPO ROOT. Use formal/run.sh rather than invoking this directly.
#
# A SEPARATE RUN, NOT A VARIANT. Reset fills the array with all-ones while size
# resets to 0 (register_array_pipelined.sv:56-64), so the queue boots physically
# full but logically empty and each replace evicts one placeholder. There is no
# enqueue datapath, so a bare write is not a command this build has.
#
# The sentinel idiom is duplicated verbatim from register_array, so this is
# expected to behave exactly like register_array_enq0 -- including reproducing
# F-1 when ASSUME_FILL_FIRST is dropped. The difference is HAS_BUSY: this design
# drops both readies mid-operation, so the fill-first flag has to latch on
# `settled && !o_write_ready` rather than `!o_write_ready` alone. That is F-5,
# already fixed in the spec and already exercised by register_tree_enq0.

clear -all

set HWPQ_SELFTEST 0
if {[info exists ::env(HWPQ_SELFTEST)]} { set HWPQ_SELFTEST $::env(HWPQ_SELFTEST) }
set HWPQ_UNGATED 0
if {[info exists ::env(HWPQ_UNGATED)]}  { set HWPQ_UNGATED  $::env(HWPQ_UNGATED) }

# ---- 1. sources -------------------------------------------------------------
set src {
    hwpq/register_array_pipelined/src/register_array_pipelined.sv
    formal/spec/hwpq_spec.sv
    formal/bind/register_array_pipelined_bind.sv
}
set hwpq_defs {}
if {$HWPQ_SELFTEST} {
    puts "### SELF-TEST MODE: the self-test property is deliberately unprovable."
    lappend hwpq_defs HWPQ_SELFTEST
}
if {$HWPQ_UNGATED} {
    puts "### UNGATED MODE: workaround assumptions dropped; the recorded"
    puts "###               shortcomings are expected to reproduce."
    lappend hwpq_defs HWPQ_UNGATED
}
set hwpq_dflags {}
foreach d $hwpq_defs { lappend hwpq_dflags -define $d }
analyze -sv12 {*}$hwpq_dflags {*}$src

# ---- 2. elaborate SMALL -----------------------------------------------------
# Same sizes as the ENQ_ENA=1 run; only the reset fill and the command set move.
# QUEUE_SIZE must be EVEN: the design pairs elements (PAIR_COUNT = QUEUE_SIZE/2).
elaborate -top register_array_pipelined \
    -parameter QUEUE_SIZE 4 \
    -parameter DATA_WIDTH 3 \
    -parameter ENQ_ENA    0

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_RSTn

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        register_array_pipelined_enq0
set HWPQ_ALLOW_BOUNDED 0

# F-1 is assumed away, not recorded: ASSUME_FILL_FIRST in the spec constrains
# this build to the initialisation convention its callers follow (fill the queue
# before reading from it). That is hole CH-4 -- see formal/FINDINGS.md. The cover
# set is what proves the assumption did not strangle the design.
# Ungated runs must reproduce EXACTLY these and nothing else. If one stops
# firing the defect was fixed and the assumption should be retired; if a new
# one appears, something regressed. Either way the run fails and says which.
#   F-1: same mechanism as register_array_enq0 -- the sentinel idiom is
#   duplicated verbatim across the register designs.
#   F-1 again, at the port: the queue advertises a placeholder as its maximum.
#   Reachable in 2 cycles and NOT scoped out by ASSUME_FILL_FIRST, which forbids
#   the dequeue rather than the exposure - so this one is expected in both modes.
if {$HWPQ_UNGATED} {
    set HWPQ_EXPECT_CEX {a_occ_empty_agrees a_no_loss a_head_not_placeholder}
} else {
    set HWPQ_EXPECT_CEX {a_head_not_placeholder}
}

source formal/tcl/common.tcl
hwpq_prove_and_exit
