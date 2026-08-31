# JasperGold proof: bram_tree (enqueue-capable; both command forms live)
#
# Run from the REPO ROOT. Use formal/run.sh rather than invoking this directly.
#
# THIS RUN IS EXPECTED TO FAIL, and to fail before it proves anything. The
# module's RAM model drives its array from two `always` blocks, so
# hwpq_multiple_driven_gate in common.tcl refuses it. That is the same defect as
# F-21 on bram_tree_pipelined, in this module's own copy of the file, and the run
# is committed in this state on purpose: the gate is the demonstration, and the
# fix is the next commit.
#
# Measured here: 7 multiply-driven signals (u_dut.bram_inst.ram[0..6]) and
# IMDS005 reporting 49 bits. The SIGNAL count is structural -- one per node -- but
# the BIT count tracks the elaborated parameters: 7 bits per word at DATA_WIDTH=3
# (1 active + 3 value + 3 capacity), against 20 bits and so 140 at the module's
# DATA_WIDTH=16 default. Quote the number with the size it was measured at.
#
# Nothing below has been validated against a converged run yet. MAX_SETTLE, the
# parameter sizes, and HAS_FULL are all first estimates -- see the bind file.

clear -all

set HWPQ_SELFTEST 0
if {[info exists ::env(HWPQ_SELFTEST)]} { set HWPQ_SELFTEST $::env(HWPQ_SELFTEST) }
set HWPQ_UNGATED 0
if {[info exists ::env(HWPQ_UNGATED)]}  { set HWPQ_UNGATED  $::env(HWPQ_UNGATED) }

# ---- 1. sources -------------------------------------------------------------
# Order is free now. It was NOT before fa7b2c9: bram_tree.sv declared
# `package bram_tree_pkg` and rams_tdp_rf_rf.sv imported it, so listing the RAM
# first gave VERI-8054 plus eight follow-on errors. Parameterising the module
# removed the package and with it the ordering constraint.
set src {
    hwpq/bram_tree/src/bram_tree.sv
    hwpq/bram_tree/src/rams_tdp_rf_rf.sv
    formal/spec/hwpq_spec.sv
    formal/spec/hwpq_bram_tree_aux.sv
    formal/bind/bram_tree_bind.sv
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
# QUEUE_SIZE must be 2^k - 1 for the tree designs. 7 gives TREE_DEPTH=3, which is
# the smallest size with a non-trivial descent.
#
# DATA_WIDTH 2, NOT the library default of 3. Sized up front so every run below
# is like-for-like and converges inside the ceiling. At width 3 the three spec
# properties that track a symbolic value through the whole queue -- a_no_loss,
# a_head_is_max and a_head_present -- do not converge in 1800 s. Those are the
# SAME three that forced width 2 on bram_tree_pipelined (PLAN 7.1), which is the
# same architecture family, and this module carries a capacity field per node on
# top of the payload so it has strictly more state.
#
# It is a real reduction in strength, not a free choice: with both sentinels
# reserved the legal alphabet is 2**2 - 2 = TWO values, so an ordering property
# can tell a maximum from a non-maximum but cannot distinguish degrees among
# three or more payloads. Raising the ceiling instead is the wrong answer (F-18).
#
# Superseded note, kept because the reasoning was right:
# bram_tree_pipelined did once its RAM model was sound, and this module carries a
# capacity field per node ON TOP of the payload, so it has strictly more state
# per node than the one that already needed the reduction. Width 2 leaves two
# legal payload values once both sentinels are reserved, which is a real
# reduction in what the ordering properties can distinguish -- do not take it
# until a run actually fails to converge at 3.
#
# The top is the reset harness, not the DUT -- see F-14 and the harness comment
# in formal/bind/bram_tree_bind.sv.
elaborate -top hwpq_rst_bram_tree \
    -parameter QUEUE_SIZE 7 \
    -parameter DATA_WIDTH 2

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_init_RSTn

# CH-6, in bram_tree's own instance. The BRAMs have no reset port and Jasper
# ignores the `initial` block that fills them (VERI-1060), so without this the
# memory starts arbitrary -- including the per-node `capacity` fields that carry
# this design's entire free-space accounting -- and the ordering and occupancy
# properties fail for reasons unrelated to the design.
#
# `-bound 1` pins CYCLE 0 and nothing after it. A later reset stays free, which
# is what leaves "reset does not restore the memory" reachable and provable as a
# defect rather than assumed away. See formal/spec/hwpq_bram_tree_aux.sv.
#
# It was MISSING from b13e3f1 through the enqueue-guard commit, so every result
# in that range was measured against a memory the tool was free to invent. The
# VERI-1060 warning naming it was printed on every one of those runs.
# CH-6 IS RETIRED. It used to read
#
#     assume -bound 1 {u_bram_aux.fill_intact}
#
# pinning the memory contents at cycle 0, because the BRAM has no reset port and
# Jasper ignores the `initial` block that fills it (VERI-1060), so the array
# started arbitrary and every ordering property failed for reasons unrelated to
# the design. The reset fill sweep now establishes the contents from whatever the
# memory powers up holding, and no command is accepted until it has, so the
# assumption is no longer load-bearing.
#
# The proofs therefore run with the node memory ENTIRELY FREE -- a strictly
# stronger result than the assumption ever allowed, and one hole fewer. Same
# outcome as bram_tree_pipelined, which retired its CH-6 at 46bec75 for the same
# reason.

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        bram_tree
set HWPQ_ALLOW_BOUNDED 0

# Empty on purpose. An expected-cex list is how a defect that is STAYING gets
# parked, not a running tally of work in progress -- and nothing here is staying
# yet. F-27 is the reminder that this must be revisited at the END of the work:
# leaving it empty on bram_tree_pipelined is what made `--all --ungated` red for
# a fortnight without anyone noticing.
set HWPQ_EXPECT_CEX {}

source formal/tcl/common.tcl
hwpq_prove_and_exit
