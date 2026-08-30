# JasperGold proof: register_tree
#
# Run from the REPO ROOT. Use formal/run.sh rather than invoking this directly.
#
# The first SEQUENTIAL module: both readies drop together while an operation is
# in flight, so this is what actually exercises the busy-state machinery in the
# spec - p_at_next_settle's non-degenerate path and a_progress. Everything
# proven before this ran with `settled` constant 1.

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
# QUEUE_SIZE must be 2^k-1 for the tree designs: NODES_NEEDED is
# (1 << TREE_DEPTH) - 1, and any other size leaves a partly-populated bottom
# level. 7 is the smallest size with a real interior level.
elaborate -top hwpq_rst_register_tree \
    -parameter QUEUE_SIZE 7 \
    -parameter DATA_WIDTH 3 \
    -parameter ENQ_ENA    1

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_init_RSTn

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        register_tree
set HWPQ_ALLOW_BOUNDED 0
# No workaround assumption applies here, so --ungated is a no-op and the
# property set must be clean in both modes.
set HWPQ_EXPECT_CEX    {}

source formal/tcl/common.tcl
hwpq_prove_and_exit
