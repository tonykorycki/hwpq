# JasperGold proof: bram_tree_pipelined (replace-only; the module has no enqueue path)
#
# Run from the REPO ROOT. Use formal/run.sh rather than invoking this directly.
#
# The first BRAM architecture to be proved. Three things make it unlike the
# register modules, all handled in formal/spec/hwpq_bram_aux.sv rather than here:
#
#   Memory is not reset state. Jasper ignores the `initial` block that fills the
#   RAMs (VERI-1060), so they start arbitrary. hwpq_bram_aux assumes the all-ones
#   fill for the FIRST reset only -- hole CH-6 -- which leaves a later reset free
#   to expose the fact that nothing restores it.
#
#   o_write_ready is not a fullness signal. The word "full" does not appear in
#   the source; there is no enqueue datapath and a replace on a populated queue
#   is size-neutral, so no command it accepts has fullness as a precondition.
#   Hence HAS_FULL=0 with CAPACITY=QUEUE_SIZE, and the aux file both states what
#   the port does mean and recovers the covers HAS_FULL=0 would have dropped.
#
#   The out-of-range index expressions Jasper warns about (VERI-9005, ten sites)
#   are left in the RTL and decided by property instead of patched blind.

clear -all

set HWPQ_SELFTEST 0
if {[info exists ::env(HWPQ_SELFTEST)]} { set HWPQ_SELFTEST $::env(HWPQ_SELFTEST) }
set HWPQ_UNGATED 0
if {[info exists ::env(HWPQ_UNGATED)]}  { set HWPQ_UNGATED  $::env(HWPQ_UNGATED) }

# ---- 1. sources -------------------------------------------------------------
set src {
    hwpq/bram_tree_pipelined/src/comparator.sv
    hwpq/bram_tree_pipelined/src/rams_tdp_rf_rf.sv
    hwpq/bram_tree_pipelined/src/bram_tree_pipelined.sv
    formal/spec/hwpq_spec.sv
    formal/bind/baseline/bram_tree_pipelined_baseline_bind.sv
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
# QUEUE_SIZE must be 2^k - 1 for the tree designs, so the choice is 7 or 15.
#
# 15 DOES NOT CONVERGE. These proofs are dominated by finding cover witnesses,
# and at 15 the queue holds fifteen elements at up to 18 cycles per operation, so
# demonstrating that it can fill needs roughly 270 cycles of bounded
# reachability. A run at that size was killed at 1800 s having made no progress,
# after an earlier one had spent 4.7 hours and written a 212 MB log. Runs at 15
# that did finish only finished because a fast-failing property gave the engines
# an easy answer first; that is luck, not convergence.
#
# 7 gives TREE_DEPTH=3 and exactly one BRAM level, which is the cost: the second
# level, and any defect that needs two, is out of scope here. The index-range
# questions the depth was originally chosen for are settled by construction now
# that the accesses are guarded, so that reason for preferring 15 has expired.
#
# DATA_WIDTH 2, NOT 3 as everywhere else -- and this one is a real reduction in
# strength, not a free choice. With '0 and all-ones reserved the legal alphabet is
# 2**2 - 2 = TWO values, so an ordering property can still tell a maximum from a
# non-maximum but cannot distinguish degrees of ordering among three or more
# distinct payloads.
#
# It became necessary when the RAM model was fixed (F-21). Against the old
# multiply-driven memory the engines got cheap counterexamples from contents
# Jasper was free to invent; against a sound model they have to search, and
# a_no_loss, a_head_is_max and a_head_present -- the spec properties that track a
# symbolic value through the whole queue -- did not converge in 3600 s at width 3.
# The reset sweep also adds a fixed ~9-cycle prefix to every trace, pushing every
# witness that much deeper.
#
# At width 2 the whole set converges in well under the default ceiling. Raising
# the ceiling instead was tried twice (2100 s and 3600 s) and is the wrong answer:
# a proof past the ceiling is mis-sized, not slow (F-18).
#
# The top is the reset harness, not the DUT -- see F-14 and the harness comment
# in formal/bind/baseline/bram_tree_pipelined_baseline_bind.sv.
elaborate -top hwpq_rst_bram_tree_pipelined \
    -parameter QUEUE_SIZE 7 \
    -parameter DATA_WIDTH 2

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_init_RSTn

# CH-6 IS RETIRED. It used to read
#
#     assume -bound 1 {u_bram_aux.fill_intact}
#
# because the BRAMs have no reset, Jasper ignores the `initial` block that fills
# them (VERI-1060), and so they started arbitrary -- every ordering property then
# failed for reasons unrelated to the design. The reset fill sequencer establishes
# the all-ones contents from whatever the memory powers up holding, and no command
# is accepted until it has, so the assumption is no longer load-bearing and the
# proofs now run with the memory contents entirely free.

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        bram_tree_pipelined_baseline
set HWPQ_ALLOW_BOUNDED 0

# Ungated runs must reproduce EXACTLY these and nothing else. If one stops firing
# the defect was fixed and the assumption should be retired; if a new one appears,
# something regressed. Either way the run fails and says which.
#
# a_reset_restores_fill USED TO be expected here, in both modes, because nothing
# restored the placeholder fill and CH-6 deliberately left a later reset free so
# that defect stayed reachable. That is F-25, fixed at e2e0111 and 8b67c01; the
# property now PROVES, as one of the twenty, and CH-6 is retired with it. The
# expectation went with it.
#
# What is expected instead is weaker evidence than that was, and the difference
# is worth stating rather than glossing. a_reset_restores_fill named its own
# mechanism. a_occ_empty_agrees and a_no_loss are downstream occupancy asserts
# that happen to be what falls over -- exactly the shape F-13 warns about.
#
# The end of that work has now arrived, so the list is populated. This module
# carries the F-1 head-sentinel gate (a91849f) and therefore inherits the F-1
# RESIDUAL that the four register architectures have: with ASSUME_FILL_FIRST
# dropped -- the only thing --ungated drops here -- a queue holding placeholders
# during the fill phase holds elements it will not admit to, and the two
# occupancy properties say so. CH-4 is the hole; F-1 is why it is not being
# closed.
#
# Measured at a3c9da6: both fire at 24-30 cycles. The register modules fire the
# same two names at 2 and 4, and the difference is this module's ~9-cycle reset
# sweep plus 6-18 cycles per operation -- not a different defect. Per F-13,
# HWPQ_EXPECT_CEX matches on NAMES and cannot tell a changed mechanism from an
# unchanged one, so the depths above are recorded here as the thing to re-check
# if this run ever starts passing or failing differently.
#
# Leaving this empty is what made `formal/run.sh --all --ungated` red at HEAD
# while `--all` was green. Only the first mode was being run.
if {$HWPQ_UNGATED} {
    set HWPQ_EXPECT_CEX {a_occ_empty_agrees a_no_loss}
} else {
    set HWPQ_EXPECT_CEX {}
}

source formal/tcl/common.tcl
hwpq_prove_and_exit
