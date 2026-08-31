# formal/tcl/common.tcl - shared prove / classify / report / exit tail
#
# Sourced by a per-module script AFTER it has done analyze, elaborate, clock
# and reset. this file only knows how to prove and classify the result and decide pass/fail
#
#
# CALLER CONTRACT:
#   HWPQ_MODULE          module name, used in the verdict banner.        REQUIRED
#   HWPQ_OUTDIR (env)    where run.sh wants artifacts; defaults to formal/
#   HWPQ_ALLOW_BOUNDED   1 = accept bounded_proven asserts.            Default 0
#   HWPQ_EXPECT_CEX      list of assert leaf-names that are SUPPOSED to fail.
#                        A listed property that proves is a FAILURE; one that
#                        produces a cex is a PASS.                     Default {}
#
# VERSION SENSITIVITY:
#   `get_property_list -include {...}` filter syntax and the exact spelling of
#   Jasper status strings have shifted across releases. Every query is wrapped so that a
#   failure to QUERY is a hard error (exit 2), never "nothing found". If a query errors,
#   run these and adjust the status lists in hwpq_prove_and_exit:
#       help get_property_list
#       get_property_list -include {type {assert}}
#       get_property_info -list <one-property-name>
#   The same applies to the multiple-driver gate, which uses
#       get_design_info -list multiple_driven -silent
#   Verified against IC251 (`jg` 2024.12-ish): returns {} on a clean design and a
#   list of signal names on a dirty one. If the keyword is ever renamed, `help
#   get_design_info` prints the accepted -list arguments.

if {![info exists HWPQ_MODULE]} {
    puts "FORMAL ERROR: caller did not set HWPQ_MODULE before sourcing common.tcl"
    exit 2
}
if {![info exists HWPQ_ALLOW_BOUNDED]} { set HWPQ_ALLOW_BOUNDED 0 }
if {![info exists HWPQ_EXPECT_CEX]}    { set HWPQ_EXPECT_CEX    {} }


# hwpq_plist - query the property table, hard-failing on a query error.

proc hwpq_plist {type statuses} {
    set filter "type \{$type\} status \{$statuses\}"
    if {[catch {set res [get_property_list -include $filter]} err]} {
        puts "FORMAL ERROR: get_property_list failed for {$filter}"
        puts "FORMAL ERROR: $err"
        puts "FORMAL ERROR: see VERSION SENSITIVITY in formal/tcl/common.tcl"
        exit 2
    }
    return $res
}

# hwpq_leaf - the bare property name out of a full Jasper path.
#
# Jasper reports properties as <task>::<module>.<inst>.<generate>.<name>, which
# is DOT-separated. `file tail` splits on "/" and so returns the whole string
# untouched -- an HWPQ_EXPECT_CEX entry could then never match anything.
proc hwpq_leaf {p} {
    return [lindex [split $p .] end]
}

# hwpq_multiple_driven_gate - refuse to prove against a multiply-driven design.
#
# A variable driven from two `always` blocks is a lint nit in simulation: the two
# write ports touch different addresses and the non-blocking assignments land on
# different elements, so nothing is ever observed to go wrong. In formal it means
# the TOOL resolves the drivers, and what it resolves to is not what the design
# computes. Writes stop being reliably observable -- a write to address 0 need not
# be there on the next cycle -- and every memory-dependent property is then
# decided against contents Jasper was free to invent.
#
# That is F-21, the most expensive finding of this effort. Jasper announced it on
# every run of bram_tree_pipelined, starting with the very first:
#
#   [WARN (VDB-1000)] rams_tdp_rf_rf.sv(36): net 'ram[6][2]' is constantly driven
#                     from multiple places
#   [WARN (VDB-1001)] rams_tdp_rf_rf.sv(43): found another driver here
#   INFO  (IMDS005): Number of multiple-driven bits in design: 21
#
# Nobody read them for the life of the module, because nothing here treated them
# as fatal. Six properties that failed for this reason were reported as design
# defects; five were retracted (F-17), and one of them had been escalated as
# requiring a rework of the sift walk. There was nothing to rework.
#
# The gate runs BEFORE `prove -all`. A run against a resolved-driver model does
# not produce a weaker result, it produces a meaningless one, so there is nothing
# to spend proof time on and nothing to trade off -- which is also why there is
# deliberately NO override switch. `bram_tree` still carries its own copy of the
# defect (7 signals, 140 bits) and this gate will refuse the run until
# hwpq/bram_tree/src/rams_tdp_rf_rf.sv is fixed. That is the intended sequencing,
# not an obstacle to work around.
proc hwpq_multiple_driven_gate {} {
    puts "\n=== multiple-driver check ======================================"
    if {[catch {set md [get_design_info -list multiple_driven -silent]} err]} {
        puts "FORMAL ERROR: get_design_info -list multiple_driven failed"
        puts "FORMAL ERROR: $err"
        puts "FORMAL ERROR: see VERSION SENSITIVITY in formal/tcl/common.tcl"
        exit 2
    }
    if {[llength $md] == 0} {
        puts "    none - every signal has a single driver."
        return
    }
    puts "    MULTIPLY-DRIVEN SIGNALS ([llength $md]):"
    foreach sig $md { puts "        $sig" }
    puts ""
    puts "    Jasper resolves these drivers itself, so their values are NOT the"
    puts "    ones the RTL computes. Any property that reads them is decided"
    puts "    against contents the tool chose. Do not prove, do not report, and"
    puts "    do NOT treat a counterexample from such a run as a design defect."
    puts ""
    puts "    Search the elaboration log above for VDB-1000 / VDB-1001 to see"
    puts "    both drivers, and IMDS005 for the bit count. The usual cause is a"
    puts "    vendor RAM template with one always block per port; merging them"
    puts "    into a single process is sound wherever both ports share a clock."
    puts "    See F-21 in formal/FINDINGS.md."
    puts ""
    puts "    RESULT: FAIL"
    puts ""
    exit 1
}

proc hwpq_group {label items} {
    if {[llength $items] == 0} { return }
    puts "    $label ([llength $items]):"
    foreach p $items { puts "        $p" }
}

# hwpq_prove_and_exit - prove everything, print a verdict, exit 0/1/2.
#
#   0  every assert proven (or an expected cex fired); every cover reachable
#   1  a real proof failure - unexpected cex, missing expected cex,
#      undetermined, unreachable cover, bounded-only with ALLOW_BOUNDED=0, or a
#      multiply-driven design (checked BEFORE proving; see the gate below)
#   2  the script itself could not run

proc hwpq_prove_and_exit {} {
    global HWPQ_MODULE HWPQ_ALLOW_BOUNDED HWPQ_EXPECT_CEX

    # Model sanity BEFORE proof effort: a multiply-driven design cannot be
    # proved against, only proved something about. Exits 1 on its own if dirty.
    hwpq_multiple_driven_gate

    # assumption sanity
    puts "\n=== assumption check ==========================================="
    if {[catch {check_assumptions -conflict} err]} {
        puts "    NOTE: 'check_assumptions -conflict' unavailable here ($err)"
        puts "    NOTE: falling back on the cover set to detect vacuity."
    }

    # prove
    puts "\n=== prove ======================================================"
    prove -all

    # classify
    # Each query passes several spellings so one rename cannot silently drop a
    # whole failure category.
    set a_cex     [hwpq_plist assert {cex}]
    set a_undet   [hwpq_plist assert {undetermined unknown error}]
    set a_bounded [hwpq_plist assert {bounded_proven bounded}]
    set a_proven  [hwpq_plist assert {proven}]
    set c_unreach [hwpq_plist cover  {unreachable}]
    set c_undet   [hwpq_plist cover  {undetermined unknown}]
    set c_ok      [hwpq_plist cover  {covered proven}]

    # expected-cex bookkeeping
    set unexpected_cex {}
    set missing_cex    {}
    foreach p $a_cex {
        if {[lsearch -exact $HWPQ_EXPECT_CEX [hwpq_leaf $p]] < 0} {
            lappend unexpected_cex $p
        }
    }
    foreach want $HWPQ_EXPECT_CEX {
        set hit 0
        foreach p $a_cex { if {[hwpq_leaf $p] eq $want} { set hit 1 } }
        if {!$hit} { lappend missing_cex $want }
    }

    # verdict
    puts "\n=== $HWPQ_MODULE verdict ======================================="
    puts "    asserts: [llength $a_proven] proven, [llength $a_cex] cex,\
[llength $a_bounded] bounded, [llength $a_undet] undetermined"
    puts "    covers : [llength $c_ok] reachable, [llength $c_unreach] UNREACHABLE,\
[llength $c_undet] undetermined"
    if {[llength $HWPQ_EXPECT_CEX] > 0} {
        puts "    expecting cex from: $HWPQ_EXPECT_CEX"
    }

    hwpq_group "unexpected counterexamples"       $unexpected_cex
    hwpq_group "expected cex that did NOT fire"   $missing_cex
    hwpq_group "undetermined asserts"             $a_undet
    hwpq_group "bounded-only asserts"             $a_bounded
    hwpq_group "UNREACHABLE covers"               $c_unreach
    hwpq_group "undetermined covers"              $c_undet

    if {[llength $c_unreach] > 0} {
        puts ""
        puts "    An unreachable cover means an assumption has strangled the"
        puts "    design. Every 'proven' above it is vacuous. Fix the assume"
        puts "    set FIRST - do not raise effort, and do not report this run."
    }

    set fail 0
    if {[llength $unexpected_cex] > 0} { set fail 1 }
    if {[llength $missing_cex]    > 0} { set fail 1 }
    if {[llength $a_undet]        > 0} { set fail 1 }
    if {[llength $c_unreach]      > 0} { set fail 1 }
    if {[llength $c_undet]        > 0} { set fail 1 }
    if {[llength $a_bounded] > 0 && !$HWPQ_ALLOW_BOUNDED} { set fail 1 }

    # An empty assert table means the bind never attached: green by vacuum.
    if {[llength $a_proven] == 0 && [llength $a_cex] == 0 &&
        [llength $a_bounded] == 0 && [llength $a_undet] == 0} {
        puts ""
        puts "    NO ASSERTS FOUND. The bind almost certainly did not attach."
        puts "    Check the module name in formal/bind/<module>_bind.sv and"
        puts "    that the bind file was passed to `analyze`."
        set fail 1
    }

    # artifacts
    # run.sh passes the run's output directory, so the summary lands beside the
    # log and the Jasper scratch for the same run rather than in a parallel
    # naming scheme of its own. Falling back keeps a hand-invoked `jg -tcl ...`
    # working outside run.sh.
    set outdir "formal"
    set sname  "${HWPQ_MODULE}_summary.txt"
    if {[info exists ::env(HWPQ_OUTDIR)] && $::env(HWPQ_OUTDIR) ne ""} {
        set outdir $::env(HWPQ_OUTDIR)
        set sname  "summary.txt"
    }
    catch { report -summary -force -result -file ${outdir}/${sname} }
    catch { report -task {<embedded>} -assert -cover -summary }

    if {$fail} { puts "\n    RESULT: FAIL\n" ; exit 1 }
    puts "\n    RESULT: PASS\n"
    exit 0
}
