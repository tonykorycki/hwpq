# JasperGold proof: systolic_array, F-7 gap characterisation
#
# Run from the REPO ROOT. Use formal/run.sh rather than invoking this directly.
#
# A white-box run, NOT a second functional proof. It binds hwpq_systolic_aux
# only - deliberately without hwpq_spec, because the spec carries
# ASSUME_ENQ_WHEN_WREADY and that assumption forbids precisely the window this
# run exists to measure. Binding both would leave every property here vacuous
# and every cover unreachable.
#
# What it decides: how wide the ready/accept disagreement is, whether it is
# reachable, and what the queue's true capacity is as opposed to its advertised
# one. See F-7 in formal/README.md.

clear -all

set HWPQ_SELFTEST 0
if {[info exists ::env(HWPQ_SELFTEST)]} { set HWPQ_SELFTEST $::env(HWPQ_SELFTEST) }
set HWPQ_UNGATED 0
if {[info exists ::env(HWPQ_UNGATED)]}  { set HWPQ_UNGATED  $::env(HWPQ_UNGATED) }

# ---- 1. sources -------------------------------------------------------------
set src {
    hwpq/systolic_array/src/systolic_array.sv
    formal/spec/hwpq_systolic_aux.sv
    formal/bind/systolic_array_aux_bind.sv
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
elaborate -top hwpq_rst_systolic_array \
    -parameter QUEUE_SIZE 8 \
    -parameter DATA_WIDTH 3

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_init_RSTn

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        systolic_array_gap
set HWPQ_ALLOW_BOUNDED 0
# No workaround assumption applies here, so --ungated is a no-op and the
# property set must be clean in both modes.
set HWPQ_EXPECT_CEX    {}

source formal/tcl/common.tcl
hwpq_prove_and_exit
