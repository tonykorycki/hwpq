# JasperGold proof: register_array
#
# Run from the REPO ROOT - every path below is repo-relative. Use formal/run.sh
# rather than invoking this directly; it handles the self-test mode and reports
# the exit code.
#
# Proves the full property set for the ENQ_ENA=1 build: the interface
# contract, progress and handshake, occupancy, and ordering.
# The replace-only build is a separate run -- register_array_enq0.tcl.

clear -all

# HWPQ_SELFTEST is exported by formal/run.sh --selftest. It flips the plumbing
# property into a guaranteed failure so we can prove the harness reports
# failures correctly
#
# Read from the ENVIRONMENT rather than passed as a jg command-line option: the
# spelling of jg's "run this Tcl before the script" flag varies across releases,
# but $::env() is plain Tcl and works everywhere. Every per-module script
# repeats these two lines.
set HWPQ_SELFTEST 0
if {[info exists ::env(HWPQ_SELFTEST)]} { set HWPQ_SELFTEST $::env(HWPQ_SELFTEST) }
set HWPQ_UNGATED 0
if {[info exists ::env(HWPQ_UNGATED)]}  { set HWPQ_UNGATED  $::env(HWPQ_UNGATED) }

# sources
# `-define` spelling varies across Jasper releases; if this errors, try
# `analyze -sv12 +define+HWPQ_SELFTEST ...` instead.
set src {
    hwpq/register_array/src/register_array.sv
    formal/spec/hwpq_spec.sv
    formal/bind/register_array_bind.sv
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

# elaborate SMALL
# QUEUE_SIZE must be EVEN: the design pairs elements
# (PAIR_COUNT = QUEUE_SIZE/2, register_array.sv:43) and an odd size drops the
# last element out of the compare-and-swap network entirely.
#
# DATA_WIDTH 3 throughout. the spec is symbolic in the payload
# value, so extra width buys nothing but state space. If a proof will not
# converge, come back here and shrink
#
# ENQ_ENA 1 selects the '0 reset fill. The ENQ_ENA=0 build resets the array to
# all-ones instead (register_array.sv:56-62) and is a SEPARATE run, not a
# variant
elaborate -top hwpq_rst_register_array \
    -parameter QUEUE_SIZE 4 \
    -parameter DATA_WIDTH 3 \
    -parameter ENQ_ENA    1

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_init_RSTn

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        register_array
set HWPQ_ALLOW_BOUNDED 0
# Left empty even in self-test mode. The self-test's whole point is that a
# genuinely broken property makes the harness exit 1, so we must NOT tell
# common.tcl to expect the failure -- that would convert it back into a pass.
# run.sh asserts the exit code is 1. (HWPQ_EXPECT_CEX itself is exercised by
# formal/smoke.sh's stub tests, and is there for real bug reproductions later.)
# No workaround assumption applies here, so --ungated is a no-op and the
# property set must be clean in both modes.
set HWPQ_EXPECT_CEX    {}

source formal/tcl/common.tcl
hwpq_prove_and_exit
