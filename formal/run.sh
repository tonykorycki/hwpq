#!/usr/bin/env bash
#
# JasperGold driver for the HWPQ formal suite.
#
#   formal/run.sh <module>              prove it; expect exit 0
#   formal/run.sh --selftest <module>   break one property on purpose;
#                                       expect exit 1
#   formal/run.sh --all                 every module with a tcl script
#
# Runs from any working directory: paths resolve against the repo root.
# Requires `jg` on PATH 
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
cd "${REPO_ROOT}"

SELFTEST=0
MODULES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) SELFTEST=1 ;;
    --all)      for f in formal/tcl/*.tcl; do
                  b="$(basename "$f" .tcl)"
                  [ "$b" = "common" ] || MODULES+=("$b")
                done ;;
    -h|--help)  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

  log="formal/${m}.log"
  echo "############################################################"
  if [ "$SELFTEST" -eq 1 ]; then
    echo "# SELF-TEST: ${m}   (a broken property MUST make this exit 1)"
  else
    echo "# PROVE: ${m}"
  fi
  echo "############################################################"

  # -proj is per-module so parallel runs cannot clobber each other's scratch.
  # The self-test flag travels in the environment: jg's option for pre-running
  # Tcl is spelled differently across releases, $::env() is not.
  HWPQ_SELFTEST="$SELFTEST" \
    jg -batch -tcl "$tcl" -proj "formal/jgproject_${m}" 2>&1 | tee "$log"
  rc="${PIPESTATUS[0]}"

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
      0) echo "==> ${m}: PASS" ;;
      1) echo "==> ${m}: FAIL (proof failure -- read ${log})"; overall=1 ;;
      *) echo "==> ${m}: SCRIPT ERROR (exit ${rc} -- read ${log})"; overall=2 ;;
    esac
  fi
  echo
done

exit "${overall}"
