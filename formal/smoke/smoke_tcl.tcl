# Exercises formal/tcl/common.tcl's verdict logic with the Jasper commands
# stubbed out, so the pass/fail/exit-code decisions are validated without a
# license. Invoked by formal/smoke.sh.
#
# What this does NOT validate: the get_property_list filter SYNTAX and Jasper's
# status spellings, which vary by release and can only be confirmed on the
# machine. See VERSION SENSITIVITY in common.tcl.

set repo [lindex $argv 0]

# --- stub the Jasper commands common.tcl calls -------------------------------
proc check_assumptions {args} {}
proc prove {args} {}
proc report {args} {}

# STUB_TABLE maps an exact filter string to the property list it returns.
proc get_property_list {args} {
    global STUB_TABLE
    set filter [lindex $args 1]
    if {[dict exists $STUB_TABLE $filter]} { return [dict get $STUB_TABLE $filter] }
    return {}
}

proc table {cex undet bounded proven unreach cundet cok} {
    return [dict create \
        "type {assert} status {cex}"                        $cex \
        "type {assert} status {undetermined unknown error}"  $undet \
        "type {assert} status {bounded_proven bounded}"      $bounded \
        "type {assert} status {proven}"                      $proven \
        "type {cover} status {unreachable}"                  $unreach \
        "type {cover} status {undetermined unknown}"         $cundet \
        "type {cover} status {covered proven}"               $cok]
}

# Each case runs in a child tclsh so we can observe the exit code.
proc run_case {name expect_rc setup} {
    global repo
    set f [file join [file dirname [info script]] "_case.tcl"]
    set fh [open $f w]
    puts $fh "set repo {$repo}"
    puts $fh {proc check_assumptions {args} {}}
    puts $fh {proc prove {args} {}}
    puts $fh {proc report {args} {}}
    puts $fh {proc get_property_list {args} {
        global STUB_TABLE
        set filter [lindex $args 1]
        if {[dict exists $STUB_TABLE $filter]} { return [dict get $STUB_TABLE $filter] }
        return {}
    }}
    puts $fh $setup
    puts $fh {source [file join $repo formal tcl common.tcl]}
    puts $fh {hwpq_prove_and_exit}
    close $fh
    catch {exec tclsh $f} out opts
    set rc [dict get $opts -code]
    if {$rc == 0} { set rc 0 } else { set rc [lindex [dict get $opts -errorcode] 2] }
    file delete $f
    if {$rc == $expect_rc} {
        puts "        ok    $name (exit $rc)"
        return 1
    }
    puts "        BAD   $name: expected exit $expect_rc, got $rc"
    return 0
}

set common {
    set HWPQ_MODULE      smoke
    set HWPQ_EXPECT_CEX  {}
}

set all_ok 1

# 1. everything proven, covers reachable -> 0
set all_ok [expr {$all_ok & [run_case "clean run" 0 "
    set STUB_TABLE \[dict create \
        {type {assert} status {proven}} {a1 a2} \
        {type {cover} status {covered proven}} {c1}\]
    $common"]}]

# 2. an unexpected counterexample -> 1
set all_ok [expr {$all_ok & [run_case "unexpected cex" 1 "
    set STUB_TABLE \[dict create \
        {type {assert} status {cex}} {a_plumbing} \
        {type {cover} status {covered proven}} {c1}\]
    $common"]}]

# 3. an EXPECTED counterexample -> 0 (bug-reproduction mode)
set all_ok [expr {$all_ok & [run_case "expected cex fires" 0 "
    set STUB_TABLE \[dict create \
        {type {assert} status {cex}} {a_plumbing} \
        {type {cover} status {covered proven}} {c1}\]
    set HWPQ_MODULE smoke
    set HWPQ_EXPECT_CEX {a_plumbing}"]}]

# 4. an expected counterexample that does NOT fire -> 1
set all_ok [expr {$all_ok & [run_case "expected cex missing" 1 "
    set STUB_TABLE \[dict create \
        {type {assert} status {proven}} {a_plumbing} \
        {type {cover} status {covered proven}} {c1}\]
    set HWPQ_MODULE smoke
    set HWPQ_EXPECT_CEX {a_plumbing}"]}]

# 5. an unreachable cover means vacuity -> 1
set all_ok [expr {$all_ok & [run_case "unreachable cover" 1 "
    set STUB_TABLE \[dict create \
        {type {assert} status {proven}} {a1} \
        {type {cover} status {unreachable}} {c_plumbing_alive}\]
    $common"]}]

# 6. no asserts at all means the bind never attached -> 1
set all_ok [expr {$all_ok & [run_case "no asserts (bind missed)" 1 "
    set STUB_TABLE \[dict create \
        {type {cover} status {covered proven}} {c1}\]
    $common"]}]

# 7. bounded-only, not allowed -> 1
set all_ok [expr {$all_ok & [run_case "bounded-only rejected" 1 "
    set STUB_TABLE \[dict create \
        {type {assert} status {bounded_proven bounded}} {a1} \
        {type {cover} status {covered proven}} {c1}\]
    $common"]}]

exit [expr {$all_ok ? 0 : 1}]
