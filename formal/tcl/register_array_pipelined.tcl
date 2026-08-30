# JasperGold proof: register_array_pipelined
#
# Run from the REPO ROOT. Use formal/run.sh rather than invoking this directly.
#
# Sequential, but unlike register_tree it has no settle timer: head_valid is a
# data-adaptive compare, `queue[0] >= queue[1]` (:198). That makes the
# black-box ordering properties the interesting ones here - a root-local
# detector is only obviously sound when nothing can outrank the root while
# hidden below it, and a_head_is_max is what decides whether that holds.

clear -all

set HWPQ_SELFTEST 0
if {[info exists ::env(HWPQ_SELFTEST)]} { set HWPQ_SELFTEST $::env(HWPQ_SELFTEST) }
set HWPQ_UNGATED 0
if {[info exists ::env(HWPQ_UNGATED)]}  { set HWPQ_UNGATED  $::env(HWPQ_UNGATED) }

# ---- 1. sources -------------------------------------------------------------
set src {
    hwpq/register_array_pipelined/src/register_array_pipelined.sv
    formal/spec/hwpq_spec.sv
    formal/bind/register_array_pipelined_bind.sv
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
# QUEUE_SIZE must be EVEN: the design pairs elements
# (PAIR_COUNT = QUEUE_SIZE/2, :41).
elaborate -top hwpq_rst_register_array_pipelined \
    -parameter QUEUE_SIZE 4 \
    -parameter DATA_WIDTH 3 \
    -parameter ENQ_ENA    1

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_init_RSTn

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        register_array_pipelined
set HWPQ_ALLOW_BOUNDED 0
# No workaround assumption applies here, so --ungated is a no-op and the
# property set must be clean in both modes.
set HWPQ_EXPECT_CEX    {}

source formal/tcl/common.tcl
hwpq_prove_and_exit
