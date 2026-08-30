#!/usr/bin/env bash
#
# JasperGold driver for the HWPQ formal suite.
#
#   formal/run.sh <module>              prove it; expect exit 0
#   formal/run.sh --selftest <module>   break one property on purpose;
#                                       expect exit 1
#   formal/run.sh --ungated <module>    drop the workaround assumptions and
#                                       reproduce the recorded shortcomings;
#                                       expect exit 0 (see below)
#   formal/run.sh --all                 every module with a tcl script
#   formal/run.sh --timeout <secs> ...  wall-clock ceiling per configuration
#                                       (default 1800; a run that exceeds it is
#                                       mis-sized, not merely slow)
#
# GATED vs UNGATED
#
# Some proofs hold only under an assumption that papers over a known, recorded
# defect - ASSUME_FILL_FIRST for F-1, ASSUME_ENQ_WHEN_WREADY for F-7/F-8. The
# default (gated) run applies them, so work on everything else can continue.
# --ungated drops them and reproduces the defects.
#
# Ungated is NOT "expect failure". Each tcl lists exactly which properties are
# supposed to break (HWPQ_EXPECT_CEX), so the run still exits 0 if and only if
# precisely those fail. A defect that gets FIXED therefore fails the ungated
# run - "expected cex that did NOT fire" - which is the prompt to retire the
# assumption. That makes the shortcomings a regression test rather than a
# footnote.
#
# Everything a run generates - Jasper scratch, console log, property summary -
# goes to formal/jgproject/<module>[_selftest][_ungated]/ and nowhere else, so
# the whole lot is one gitignored tree and one directory to delete.
#
# Runs from any working directory: paths resolve against the repo root.
# Requires `jg` on PATH 
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
cd "${REPO_ROOT}"

SELFTEST=0
UNGATED=0
MODULES=()

# Wall-clock ceiling per configuration, seconds. A proof that has not finished by
# now is not going to: these runs are dominated by finding cover witnesses, and a
# cover whose witness is hundreds of cycles deep does not converge at all rather
# than converging slowly. Without a ceiling that failure mode is silent -- one
# mis-sized configuration ran 4.7 hours and wrote a 212 MB log before anyone
# noticed it was not making progress. 1800 s is roughly 6x the slowest run that
# does converge (register_tree, 281 s). Override with --timeout <seconds>.
TIMEOUT="${HWPQ_TIMEOUT:-1800}"

while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) SELFTEST=1 ;;
    --ungated)  UNGATED=1 ;;
    --timeout)  shift; TIMEOUT="$1" ;;
    --all)      for f in formal/tcl/*.tcl; do
                  b="$(basename "$f" .tcl)"
                  [ "$b" = "common" ] || MODULES+=("$b")
                done ;;
    -h|--help)  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "unknown option: $1" >&2; exit 2 ;;
    *)          MODULES+=("$1") ;;
  esac
  shift
done

if [ "${#MODULES[@]}" -eq 0 ]; then
  echo "usage: formal/run.sh [--selftest] <module> | --all" >&2
  exit 2
fi

if ! command -v jg >/dev/null 2>&1; then
  echo "ERROR: jg not found on PATH." >&2
  echo "       On CEPool: module use /home/shared/modules && module load cadence/<jasper>" >&2
  exit 2
fi

overall=0
for m in "${MODULES[@]}"; do
  tcl="formal/tcl/${m}.tcl"
  if [ ! -f "$tcl" ]; then
    echo "ERROR: no such proof script: $tcl" >&2
    overall=2; continue
  fi

  # Everything a run generates lands in ONE directory: Jasper's scratch, the
  # console log, and the property summary. The suffix keeps the modes apart -
  # before it existed a --selftest run overwrote the real run's log, so the
  # artifact on disk belonged to whichever happened to run last.
  sfx=""
  [ "$SELFTEST" -eq 1 ] && sfx="${sfx}_selftest"
  [ "$UNGATED"  -eq 1 ] && sfx="${sfx}_ungated"
  outdir="formal/jgproject/${m}${sfx}"
  mkdir -p "$outdir"
  log="${outdir}/run.log"
  echo "############################################################"
  if [ "$SELFTEST" -eq 1 ]; then
    echo "# SELF-TEST: ${m}   (a broken property MUST make this exit 1)"
  elif [ "$UNGATED" -eq 1 ]; then
    echo "# UNGATED: ${m}   (workaround assumptions dropped; the recorded"
    echo "#                  shortcomings MUST reproduce, and nothing else)"
  else
    echo "# PROVE: ${m}"
  fi
  echo "############################################################"

  # -proj is per-run so parallel runs cannot clobber each other's scratch.
  # The mode flags travel in the environment: jg's option for pre-running Tcl is
  # spelled differently across releases, $::env() is not. HWPQ_OUTDIR is how
  # common.tcl learns where to put the summary, so the path is built once here
  # rather than reconstructed in Tcl.
  # A separate project dir per mode: the two configurations elaborate
  # differently, and sharing scratch invites a stale-lock collision.
  # A jg killed mid-run (Ctrl-C, a timeout, a dropped SSH session) leaves a lock
  # behind, and the next run then reports "Cannot obtain ownership of project
  # directory" -- which run.sh classifies as a proof FAILURE. That misreads as a
  # real regression and has already cost several false alarms. Clear a lock only
  # when it is from THIS host and its process is gone; a live run, or one on
  # another CEPool node, is left strictly alone.
  if [ -d "$outdir" ]; then
    for lk in "$outdir"/*.lock; do
      [ -e "$lk" ] || continue
      b="$(basename "$lk" .lock)"
      pid="${b##*.}"
      lkhost="${b%.*}"
      case "$pid" in
        ''|*[!0-9]*) continue ;;   # not host.PID.lock -- do not touch it
      esac
      if [ "$lkhost" = "$(hostname)" ] && ! ps -p "$pid" >/dev/null 2>&1; then
        echo "note: clearing stale Jasper lock from dead PID ${pid} (${lk})"
        rm -f "$lk"
      fi
    done
  fi

  HWPQ_SELFTEST="$SELFTEST" HWPQ_UNGATED="$UNGATED" HWPQ_OUTDIR="$outdir" \
    timeout --signal=TERM --kill-after=30 "$TIMEOUT" \
    jg -batch -tcl "$tcl" -proj "$outdir" 2>&1 | tee "$log"
  rc="${PIPESTATUS[0]}"

  # 124 is timeout(1) reporting that it had to kill the run.
  if [ "$rc" -eq 124 ]; then
    echo "==> ${m}: TIMEOUT after ${TIMEOUT}s -- the proof did not converge." >&2
    echo "    This is a sizing problem, not a proof failure. Check the cover set" >&2
    echo "    for a witness that is hundreds of cycles deep, and shrink" >&2
    echo "    QUEUE_SIZE before raising --timeout." >&2
    overall=1
    continue
  fi

  if [ "$SELFTEST" -eq 1 ]; then
    if [ "$rc" -eq 1 ]; then
      echo "==> ${m}: self-test PASSED (harness correctly reported failure, exit 1)"
    else
      echo "==> ${m}: self-test FAILED -- expected exit 1, got ${rc}." >&2
      echo "    The harness cannot report failures. Do not trust any green run" >&2
      echo "    until this is fixed." >&2
      overall=1
    fi
  else
    case "$rc" in
      0) if [ "$UNGATED" -eq 1 ]; then
           echo "==> ${m}: PASS (ungated -- recorded shortcomings reproduced exactly)"
         else
           echo "==> ${m}: PASS"
         fi ;;
      1) if [ "$UNGATED" -eq 1 ]; then
           echo "==> ${m}: FAIL (ungated -- the set of failures changed; either a" >&2
           echo "    defect was fixed and its assumption should be retired, or a" >&2
           echo "    new one appeared. Read ${log})" >&2
         else
           echo "==> ${m}: FAIL (proof failure -- read ${log})"
         fi
         overall=1 ;;
      *) echo "==> ${m}: SCRIPT ERROR (exit ${rc} -- read ${log})"; overall=2 ;;
    esac
  fi
  echo
done

exit "${overall}"
