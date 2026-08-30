# JasperGold proof: register_tree, ENQ_ENA=0 (replace-only build)
#
# Run from the REPO ROOT. Use formal/run.sh rather than invoking this directly.
#
# A SEPARATE RUN, NOT A VARIANT. Reset fills every node with all-ones while size
# resets to 0 (register_tree.sv:94-99), so the tree boots physically full but
# logically empty and each replace evicts one placeholder. There is no enqueue
# datapath, so a bare write is not a command this build has.
#
# The spec's ASSUME_FILL_FIRST constrains this build to the initialisation
# convention - do not read before the queue has been filled once. Without it
# this reproduces F-1, the same way register_array does; the idiom is duplicated
# verbatim across both families. See formal/README.md.

clear -all

set HWPQ_SELFTEST 0
if {[info exists ::env(HWPQ_SELFTEST)]} { set HWPQ_SELFTEST $::env(HWPQ_SELFTEST) }
set HWPQ_UNGATED 0
if {[info exists ::env(HWPQ_UNGATED)]}  { set HWPQ_UNGATED  $::env(HWPQ_UNGATED) }

# ---- 1. sources -------------------------------------------------------------
set src {
    hwpq/register_tree/src/register_tree.sv
    formal/spec/hwpq_spec.sv
    formal/bind/register_tree_bind.sv
    formal/spec/hwpq_tree_aux.sv
    formal/bind/register_tree_aux_bind.sv
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
elaborate -top hwpq_rst_register_tree \
    -parameter QUEUE_SIZE 7 \
    -parameter DATA_WIDTH 3 \
    -parameter ENQ_ENA    0

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_init_RSTn

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        register_tree_enq0
set HWPQ_ALLOW_BOUNDED 0
# Ungated runs must reproduce EXACTLY these and nothing else. If one stops
# firing the defect was fixed and the assumption should be retired; if a new
# one appears, something regressed. Either way the run fails and says which.
#   F-1: same mechanism as register_array_enq0 - the sentinel idiom is duplicated
#   verbatim across the register designs.
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
