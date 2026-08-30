# JasperGold proof: register_tree_pipelined, ENQ_ENA=0 (replace-only build)
#
# Run from the REPO ROOT. Use formal/run.sh rather than invoking this directly.
#
# A SEPARATE RUN, NOT A VARIANT. Reset fills every node with all-ones while size
# resets to 0 (register_tree_pipelined.sv:75-83), so the tree boots physically
# full but logically empty and each replace evicts one placeholder. There is no
# enqueue datapath, so a bare write is not a command this build has.
#
# The sentinel idiom is duplicated verbatim from register_tree, so this is
# expected to behave exactly like register_tree_enq0 -- including reproducing
# F-1 when ASSUME_FILL_FIRST is dropped.
#
# Carries the timer-soundness lemma too, and it is worth having on THIS build
# specifically: the reset fill is all-ones rather than zeros, so the heap
# detector the timer is checked against starts from the opposite extreme.
# register_tree_enq0 already proves the aux lemma under the same conditions.

clear -all

set HWPQ_SELFTEST 0
if {[info exists ::env(HWPQ_SELFTEST)]} { set HWPQ_SELFTEST $::env(HWPQ_SELFTEST) }
set HWPQ_UNGATED 0
if {[info exists ::env(HWPQ_UNGATED)]}  { set HWPQ_UNGATED  $::env(HWPQ_UNGATED) }

# ---- 1. sources -------------------------------------------------------------
set src {
    hwpq/register_tree_pipelined/src/register_tree_pipelined.sv
    formal/spec/hwpq_spec.sv
    formal/spec/hwpq_tree_aux.sv
    formal/bind/register_tree_pipelined_bind.sv
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
# QUEUE_SIZE must be 2^k-1 for the tree designs.
elaborate -top register_tree_pipelined \
    -parameter QUEUE_SIZE 7 \
    -parameter DATA_WIDTH 3 \
    -parameter ENQ_ENA    0

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_RSTn

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        register_tree_pipelined_enq0
set HWPQ_ALLOW_BOUNDED 0

# F-1 is assumed away, not recorded: ASSUME_FILL_FIRST in the spec constrains
# this build to the initialisation convention its callers follow (fill the queue
# before reading from it). That is hole CH-4 -- see formal/FINDINGS.md. The cover
# set is what proves the assumption did not strangle the design.
# Ungated runs must reproduce EXACTLY these and nothing else. If one stops
# firing the defect was fixed and the assumption should be retired; if a new
# one appears, something regressed. Either way the run fails and says which.
#   F-1: same mechanism as register_tree_enq0 -- the sentinel idiom is
#   duplicated verbatim across the register designs.
#   The TRACE behind those two changed when the head gate landed: they used to
#   fire because the queue advertised a placeholder as data, and now fire because
#   it holds an element during the fill phase that it will not admit to. Same two
#   names, different defect. HWPQ_EXPECT_CEX matches on NAMES, so the run cannot
#   tell those apart on its own -- see FINDINGS.
if {$HWPQ_UNGATED} {
    set HWPQ_EXPECT_CEX {a_occ_empty_agrees a_no_loss}
} else {
    set HWPQ_EXPECT_CEX {}
}

source formal/tcl/common.tcl
hwpq_prove_and_exit
