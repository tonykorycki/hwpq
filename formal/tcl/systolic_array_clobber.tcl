# JasperGold proof: systolic_array, IB[0] clobber check
#
# Run from the REPO ROOT. Use formal/run.sh rather than invoking this directly.
#
# A white-box run, NOT a second functional proof. It binds
# hwpq_systolic_clobber only - deliberately without hwpq_spec, because the spec
# carries ASSUME_ENQ_WHEN_WREADY and that assumption forbids precisely the
# writes this run exists to study.
#
# What it decides: whether a write can DESTROY a live value sitting in IB[0].
# Every enqueue and replace overwrites IB[0] unconditionally, and the shift
# chain that is supposed to have vacated it first depends on how much slack the
# queue keeps. F-7 shows writes land one slot past what the queue advertises;
# this says whether that costs anything. See F-7 in formal/README.md.

clear -all

set HWPQ_SELFTEST 0
if {[info exists ::env(HWPQ_SELFTEST)]} { set HWPQ_SELFTEST $::env(HWPQ_SELFTEST) }
set HWPQ_UNGATED 0
if {[info exists ::env(HWPQ_UNGATED)]}  { set HWPQ_UNGATED  $::env(HWPQ_UNGATED) }

# ---- 1. sources -------------------------------------------------------------
set src {
    hwpq/systolic_array/src/systolic_array.sv
    formal/spec/hwpq_systolic_clobber.sv
    formal/bind/systolic_array_clobber_bind.sv
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
elaborate -top systolic_array \
    -parameter QUEUE_SIZE 8 \
    -parameter DATA_WIDTH 3

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_RSTn

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        systolic_array_clobber
set HWPQ_ALLOW_BOUNDED 0
# Ungated runs must reproduce EXACTLY these and nothing else. If one stops
# firing the defect was fixed and the assumption should be retired; if a new
# one appears, something regressed. Either way the run fails and says which.
#   F-8: without the assumption a caller may assert i_wrt while full, which the
#   sorting network acts on even though the datapath refused it - destroying
#   IB[0] and stranding cells the size counter does not know about. This is a
#   REAL RTL defect, unlike the F-7 rows above.
if {$HWPQ_UNGATED} {
    set HWPQ_EXPECT_CEX {a_no_clobber a_no_ghost_cells}
} else {
    set HWPQ_EXPECT_CEX {}
}

source formal/tcl/common.tcl
hwpq_prove_and_exit
