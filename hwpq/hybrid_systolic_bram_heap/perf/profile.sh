#!/usr/bin/env bash
#
# Cycle profile of hybrid_systolic_heap: mix_tb over 6 seeds and stream_tb over 3, then one
# summary row of mean cycles per op.
#
# Usage: hwpq/hybrid_systolic_bram_heap/perf/profile.sh [out_dir]
#   Sizes:  TREES (11), TREE_QS (2047), SYS (16), WIDTH (128)
#   Load:   MIX_N (10000), MIX_M (12000), RATIO (6), STREAM_N (8000)
# The mixed phase grows the queue by about MIX_M*(RATIO-2)/RATIO, so MIX_N plus that must fit.
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../src"
OUT="${1:-${HERE}/../../../build/hybrid_perf}"
TREES=${TREES:-11}; TREE_QS=${TREE_QS:-2047}; SYS=${SYS:-16}; WIDTH=${WIDTH:-128}
MIX_N=${MIX_N:-10000}; MIX_M=${MIX_M:-12000}; RATIO=${RATIO:-6}; STREAM_N=${STREAM_N:-8000}
CAP=$(( TREES * TREE_QS + 2 * (SYS - 2) ))
if (( MIX_N + MIX_M * (RATIO - 2) / RATIO > CAP || STREAM_N > CAP )); then
  echo "load does not fit capacity ${CAP}: lower MIX_N, MIX_M or STREAM_N"; exit 1
fi
mkdir -p "${OUT}"

SRCS="${SRC}/hybrid_typedef.sv ${SRC}/rams_tdp_rf_rf.sv ${SRC}/bram_tree.sv ${SRC}/bram_tree_pair.sv
      ${SRC}/hybrid_systolic_heap.sv"
DEFS="-DHYBRID_TREE_COUNT=${TREES} -DHYBRID_BRAM_TREE_QUEUE_SIZE=${TREE_QS}
      -DHYBRID_SYSTOLIC_QUEUE_SIZE=${SYS} -DHYBRID_DATA_WIDTH=${WIDTH}"
build() {
  iverilog -g2012 -o "${OUT}/$1.vvp" -s "$1" ${DEFS} "${@:2}" ${SRCS} "${HERE}/$1.sv" \
    > "${OUT}/$1.comp" 2>&1 || { cat "${OUT}/$1.comp"; exit 1; }
}
build mix_tb -DN=${MIX_N} -DM=${MIX_M} -DRATIO=${RATIO}
build stream_tb -DN=${STREAM_N}

for s in 1 7 13 29 101 333; do vvp "${OUT}/mix_tb.vvp" +seed=$s > "${OUT}/mix_$s.log" 2>&1 & done
for s in 1 7 13; do vvp "${OUT}/stream_tb.vvp" +seed=$s > "${OUT}/stream_$s.log" 2>&1 & done
wait
if grep -l TIMEOUT "${OUT}"/mix_*.log "${OUT}"/stream_*.log; then echo "timed out"; exit 1; fi

avg() { awk '{s += $1; n++} END {printf "%.2f", s / n}'; }
mix() { grep -h 'PROF mix' "${OUT}"/mix_*.log | sed "s/$1/\\1/" | avg; }
stream() { grep -h "PROF $1" "${OUT}"/stream_*.log | awk '{print $5}' | avg; }
echo "trees ${TREES} x ${TREE_QS}, systolic ${SYS}, ${WIDTH} bit, capacity ${CAP}"
printf "%-8s %-8s %-8s %-8s %-8s %-8s\n" enq deq overall fill drain replace
printf "%-8s %-8s %-8s %-8s %-8s %-8s\n" \
  "$(mix '.*enq \([0-9.]*\).*')" "$(mix '.*read \([0-9.]*\).*')" "$(mix '.*ops, \([0-9.]*\) cycles.*')" \
  "$(stream fill)" "$(stream drain)" "$(stream replace)"
