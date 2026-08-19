# formal/tcl/common.tcl - shared prove / classify / report / exit tail
#
# Sourced by a per-module script AFTER it has done analyze, elaborate, clock
# and reset. this file only knows how to prove and classify the result and decide pass/fail
#
#
# CALLER CONTRACT:
#   HWPQ_MODULE          module name, used for report filenames.       REQUIRED
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

proc hwpq_group {label items} {
    if {[llength $items] == 0} { return }
    puts "    $label ([llength $items]):"
    foreach p $items { puts "        $p" }
}

# hwpq_prove_and_exit - prove everything, print a verdict, exit 0/1/2.
#
#   0  every assert proven (or an expected cex fired); every cover reachable
#   1  a real proof failure - unexpected cex, missing expected cex,
#      undetermined, unreachable cover, or bounded-only with ALLOW_BOUNDED=0
#   2  the script itself could not run

proc hwpq_prove_and_exit {} {
    global HWPQ_MODULE HWPQ_ALLOW_BOUNDED HWPQ_EXPECT_CEX

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
    # Suffix the summary in ungated mode. run.sh already suffixes the log and
    # the project dir; without this the two modes overwrite each other's summary
    # and the file on disk silently belongs to whichever ran last.
    set sfx ""
    if {[info exists ::env(HWPQ_UNGATED)] && $::env(HWPQ_UNGATED)} { set sfx "_ungated" }
    catch { report -summary -force -result -file formal/${HWPQ_MODULE}${sfx}_summary.txt }
    catch { report -task {<embedded>} -assert -cover -summary }

    if {$fail} { puts "\n    RESULT: FAIL\n" ; exit 1 }
    puts "\n    RESULT: PASS\n"
    exit 0
}
