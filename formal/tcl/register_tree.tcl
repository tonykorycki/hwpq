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

# ---- 1. sources -------------------------------------------------------------
set src {
    hwpq/register_tree/src/register_tree.sv
    formal/spec/hwpq_spec.sv
    formal/bind/register_tree_bind.sv
}
if {$HWPQ_SELFTEST} {
    puts "### SELF-TEST MODE: the plumbing property is deliberately inverted."
    analyze -sv12 -define HWPQ_SELFTEST {*}$src
} else {
    analyze -sv12 {*}$src
}

# ---- 2. elaborate SMALL -----------------------------------------------------
# QUEUE_SIZE must be 2^k-1 for the tree designs: NODES_NEEDED is
# (1 << TREE_DEPTH) - 1, and any other size leaves a partly-populated bottom
# level. 7 is the smallest size with a real interior level.
elaborate -top register_tree \
    -parameter QUEUE_SIZE 7 \
    -parameter DATA_WIDTH 3 \
    -parameter ENQ_ENA    1

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_RSTn

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        register_tree
set HWPQ_ALLOW_BOUNDED 0
set HWPQ_EXPECT_CEX    {}

source formal/tcl/common.tcl
hwpq_prove_and_exit
