#!/usr/bin/env bash
#
# Sweep hybrid_systolic_heap over data widths, tree sizes, tree counts and systolic buffer sizes,
# one batch run per build (every combination of the lists given).
#
# Usage: scripts/run_hybrid_sweep.sh [-j <parallel>] [-w "<widths>"] [-t "<tree_queue_sizes>"]
#                                    [-n "<tree_counts>"] [-s "<systolic_sizes>"]
#   -j  concurrent builds (default 2); each uses up to 8 threads and a 128-bit build ~10 GB
#   -w  data widths (default "128")
#   -t  per-tree queue sizes, each 2^k - 1 (default "2047")
#   -n  tree counts (default "11")
#   -s  systolic buffer sizes, even and at least 6 (default "16")
# Results:  hwpq/hybrid_systolic_bram_heap/vivado_analysis_results_<W>bit_xcau25p/ at the default
#   tree count and systolic size; hwpq/hybrid_systolic_bram_heap/sweep_<W>bit_n<N>_s<S>/ otherwise,
#   which the library plots do not read.
# Logs, checkpoints and path reports:  build/vivado_hybrid/<W>b_tree<T>_n<N>_s<S>/
# A build whose result file already ends in "Analysis completed" is skipped; delete it to rerun.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TCL="${ROOT}/scripts/vivado_hybrid.tcl"
MODULE_DIR="${ROOT}/hwpq/hybrid_systolic_bram_heap"
TREE_COUNTS="11"
SYSTOLIC_SIZES="16"

MAX_PARALLEL=2
WIDTHS="128"
TREE_SIZES="2047"
while getopts "j:w:t:n:s:" opt; do
  case "${opt}" in
    j) MAX_PARALLEL="${OPTARG}" ;;
    w) WIDTHS="${OPTARG}" ;;
    t) TREE_SIZES="${OPTARG}" ;;
    n) TREE_COUNTS="${OPTARG}" ;;
    s) SYSTOLIC_SIZES="${OPTARG}" ;;
    *) sed -n '3,16p' "$0"; exit 1 ;;
  esac
done

command -v vivado >/dev/null || { echo "vivado not on PATH"; exit 1; }

for s in ${SYSTOLIC_SIZES}; do
  if (( s % 2 || s < 6 )); then echo "systolic size ${s}: must be even and at least 6"; exit 1; fi
done

run_one() {
  local w="$1" t="$2" n="$3" s="$4"
  local qs=$(( n * t + 2 * (s - 2) ))
  local result_dir="${MODULE_DIR}/vivado_analysis_results_${w}bit_xcau25p"
  [ "${n}" = 11 ] && [ "${s}" = 16 ] || result_dir="${MODULE_DIR}/sweep_${w}bit_n${n}_s${s}"
  local tag="${w}b tree=${t} n=${n} s=${s}"
  local work_dir="${ROOT}/build/vivado_hybrid/${w}b_tree${t}_n${n}_s${s}"
  local result="${result_dir}/vivado_analysis_on_queue_size_${qs}.txt"

  if [ -f "${result}" ] && grep -q "Analysis completed" "${work_dir}/vivado.log" 2>/dev/null; then
    echo "skip  ${tag} (done)"
    return 0
  fi
  mkdir -p "${work_dir}"
  echo "start ${tag} -> ${work_dir}/vivado.log"
  local status=0
  (cd "${work_dir}" && vivado -mode batch -nojournal -log vivado.log -source "${TCL}" \
     -tclargs "${w}" "${t}" "${result_dir}" "${work_dir}" "${n}" "${s}" > /dev/null 2>&1) || status=$?
  if grep -q "Analysis completed" "${work_dir}/vivado.log"; then
    echo "done  ${tag}: best $(grep -o 'Achieved Frequency: [0-9.]*' "${result}" | awk '{print $3}' | sort -g | tail -1) MHz"
  else
    echo "FAIL  ${tag} (exit ${status}); see ${work_dir}/vivado.log"
  fi
}

for w in ${WIDTHS}; do
  for t in ${TREE_SIZES}; do
    for n in ${TREE_COUNTS}; do
      for s in ${SYSTOLIC_SIZES}; do
        while [ "$(jobs -rp | wc -l)" -ge "${MAX_PARALLEL}" ]; do wait -n || true; done
        run_one "${w}" "${t}" "${n}" "${s}" &
      done
    done
  done
done
wait
