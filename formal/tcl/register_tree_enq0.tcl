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

# ---- 1. sources -------------------------------------------------------------
set src {
    hwpq/register_tree/src/register_tree.sv
    formal/spec/hwpq_spec.sv
    formal/bind/register_tree_bind.sv
    formal/spec/hwpq_tree_aux.sv
    formal/bind/register_tree_aux_bind.sv
}
if {$HWPQ_SELFTEST} {
    puts "### SELF-TEST MODE: the self-test property is deliberately unprovable."
    analyze -sv12 -define HWPQ_SELFTEST {*}$src
} else {
    analyze -sv12 {*}$src
}

# ---- 2. elaborate SMALL -----------------------------------------------------
# Same sizes as the ENQ_ENA=1 run; only the reset fill and the command set move.
elaborate -top register_tree \
    -parameter QUEUE_SIZE 7 \
    -parameter DATA_WIDTH 3 \
    -parameter ENQ_ENA    0

# ---- 3. time and reset ------------------------------------------------------
clock i_CLK
reset ~i_RSTn

# ---- 4. prove, gate, exit ---------------------------------------------------
set HWPQ_MODULE        register_tree_enq0
set HWPQ_ALLOW_BOUNDED 0
set HWPQ_EXPECT_CEX    {}

source formal/tcl/common.tcl
hwpq_prove_and_exit
