# JasperGold proof: register_tree_pipelined
#
# Run from the REPO ROOT. Use formal/run.sh rather than invoking this directly.
#
# The deepest sequential design in the register family: SETTLE_CYCLES is the
# full TREE_DEPTH (:48), where register_tree gets away with half of it. This is
# the one the roadmap flagged as most likely to need induction, so if a property
# comes back `bounded` rather than proven, that is the expected place - shrink
# DATA_WIDTH before raising effort.
#
# Carries the timer-soundness lemma too: head_valid is a countdown flop (:281),
# and the heap detector it is being checked against is the design's own,
# commented out at :288-295.

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
# QUEUE_SIZE must be 2^k-1 for the tree designs.
elaborate -top hwpq_rst_register_tree_pipelined \
    -parameter QUEUE_SIZE 7 \
    -parameter DATA_WIDTH 3 \
    -parameter ENQ_ENA    1

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_init_RSTn

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        register_tree_pipelined
set HWPQ_ALLOW_BOUNDED 0
# No workaround assumption applies here, so --ungated is a no-op and the
# property set must be clean in both modes.
set HWPQ_EXPECT_CEX    {}

source formal/tcl/common.tcl
hwpq_prove_and_exit
