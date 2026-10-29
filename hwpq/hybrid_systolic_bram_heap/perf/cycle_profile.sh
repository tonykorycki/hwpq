#!/usr/bin/env bash
#
# Cycle cost of hybrid_systolic_heap for three value orders: uniform random, nondecreasing and
# nonincreasing. Two loads, each from a master that holds every op until it is accepted; an op's
# cost is the cycles it waits plus one. Results are means over seeds 1, 7 and 13.
#
#   mix     Fill to half capacity, then 12000 ops drawn 1/3 each enqueue, dequeue and replace.
#           Table: mean cost of each op type, and of dequeues split by the op just before them.
#   stream  Fill from empty to full, drain to empty, refill, then one replace per entry.
#           Table: mean cost per op of the fill, drain and replace phases.
#
# Each load also gets a table of what the waiting reads (dequeues and replaces) waited on, in
# cycles per read: split by the op before the read for mix, by phase for stream. Causes are
# checked in this order and the first match counts:
#   own_buf    the buffer serving the head is still settling from its last command
#   other_buf  the other buffer is still settling, so the two heads cannot be compared
#   in_slot    the serving buffer's input slot is busy
#   top_move   a tree top is moving
#   max_busy   a tree holds a value above the head and that tree is busy
#   max_idle   a tree holds a value above the head and is idle, so the value is on its way up
#
# Usage (from anywhere, with iverilog on PATH):
#   hwpq/hybrid_systolic_bram_heap/perf/cycle_profile.sh [out_dir]
#   TREES=4 TREE_QS=255 SYS=8 hwpq/hybrid_systolic_bram_heap/perf/cycle_profile.sh
#
# Settings, as environment variables:
#   TREES    tree count (11)
#   TREE_QS  nodes per tree, a power of 2 minus 1 (2047)
#   SYS      systolic buffer size, even and at least 6 (16)
#   WIDTH    data width in bits (128)
#   M        ops per mix run (12000)
#   STEP     largest step between successive values in the monotone orders (3)
# Logs go to out_dir, by default build/hybrid_cycle_profile/ under the repository root.
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../.." && pwd)"
SRC="${ROOT}/hwpq/hybrid_systolic_bram_heap/src"
OUT="${1:-${ROOT}/build/hybrid_cycle_profile}"
TREES=${TREES:-11}; TREE_QS=${TREE_QS:-2047}; SYS=${SYS:-16}; WIDTH=${WIDTH:-128}; M=${M:-12000}
STEP=${STEP:-3}
ORDERS="uniform nondecreasing nonincreasing"

if (( TREE_QS < 3 || (TREE_QS + 1) & TREE_QS )); then echo "TREE_QS must be 2^k - 1"; exit 1; fi
if (( SYS % 2 || SYS < 6 )); then echo "SYS must be even and at least 6"; exit 1; fi
CAP=$(( TREES * TREE_QS + 2 * (SYS - 2) ))  # trees plus both systolic buffers at threshold
mkdir -p "${OUT}"

for mode in mix stream; do
  case "${mode}" in
    mix)    load="-DN=$(( CAP / 2 )) -DM=${M}" ;;
    stream) load="-DSTREAM -DN=${CAP}" ;;
  esac
  for order in ${ORDERS}; do
    mono=""
    [ "${order}" = nondecreasing ] && mono="-DMONO=1"
    [ "${order}" = nonincreasing ] && mono="-DMONO=-1"
    run="${OUT}/${mode}_${order}"
    iverilog -g2012 -o "${run}.vvp" -s cycle_profile_tb ${load} ${mono} \
      -DCAP="${CAP}" -DSTEP="${STEP}" \
      -DHYBRID_TREE_COUNT="${TREES}" -DHYBRID_BRAM_TREE_QUEUE_SIZE="${TREE_QS}" \
      -DHYBRID_SYSTOLIC_QUEUE_SIZE="${SYS}" -DHYBRID_DATA_WIDTH="${WIDTH}" \
      "${SRC}/hybrid_typedef.sv" "${SRC}/rams_tdp_rf_rf.sv" "${SRC}/bram_tree.sv" \
      "${SRC}/bram_tree_pair.sv" "${SRC}/hybrid_systolic_heap.sv" "${HERE}/cycle_profile_tb.sv" \
      > "${run}.comp" 2>&1 || { cat "${run}.comp"; exit 1; }
    for s in 1 7 13; do vvp "${run}.vvp" +seed=${s} > "${run}_${s}.log" 2>&1 & done
  done
done
wait
if grep -l TIMEOUT "${OUT}"/*_*.log; then echo "runs above timed out"; exit 1; fi

# mean <tag> <key>: mean of <key>=<value> over the lines starting <tag> in the current ${logs}.
mean() {
  awk -v tag="$1" -v key="$2" '$1 == tag {
      for (i = 2; i <= NF; i++) { split($i, kv, "="); if (kv[1] == key) { sum += kv[2]; n++ } }
    }
    END { printf "%.2f", sum / n }' "${logs[@]}"
}
# wait_rows <mode> <tag prefix> <buckets...>: one row of the wait table per order and bucket.
wait_rows() {
  local mode=$1 prefix=$2 order b; shift 2
  for order in ${ORDERS}; do
    logs=("${OUT}/${mode}_${order}"_*.log)
    for b in "$@"; do
      printf "${wrow}" "${order}" "${b}" "$(mean ${prefix}${b} own_buffer_settling)" \
        "$(mean ${prefix}${b} other_buffer_settling)" "$(mean ${prefix}${b} input_slot_busy)" \
        "$(mean ${prefix}${b} tree_top_moving)" \
        "$(mean ${prefix}${b} tree_max_above_head_tree_busy)" \
        "$(mean ${prefix}${b} tree_max_above_head_tree_idle)" "$(mean ${prefix}${b} other)"
    done
  done
}
wrow="%-14s %-8s %-9s %-9s %-9s %-9s %-9s %-9s %-9s\n"
wait_header() {
  echo "read waits, cycles per read"
  printf "${wrow}" values "$1" own_buf other_buf in_slot top_move max_busy max_idle other
}

echo "${TREES} trees x ${TREE_QS}, systolic ${SYS}, ${WIDTH} bit, capacity ${CAP}"
for mode in mix stream; do
  echo
  if [ "${mode}" = mix ]; then
    echo "== mix from half full: cycles per op"
    row="%-14s %-6s %-6s %-6s %-8s | %-9s %-9s %-9s\n"
    printf "${row}" values enq deq rep overall "deq a.enq" "deq a.deq" "deq a.rep"
    for order in ${ORDERS}; do
      logs=("${OUT}/mix_${order}"_*.log)
      printf "${row}" "${order}" "$(mean RESULT enq)" "$(mean RESULT deq)" "$(mean RESULT rep)" \
        "$(mean RESULT overall)" "$(mean RESULT deq_after_enq)" "$(mean RESULT deq_after_deq)" \
        "$(mean RESULT deq_after_rep)"
    done
    echo
    wait_header after
    wait_rows mix WAIT_after_ enq deq rep
  else
    echo "== stream, empty to full and back: cycles per op"
    row="%-14s %-8s %-8s %-8s\n"
    printf "${row}" values fill drain replace
    for order in ${ORDERS}; do
      logs=("${OUT}/stream_${order}"_*.log)
      printf "${row}" "${order}" "$(mean RESULT fill)" "$(mean RESULT drain)" \
        "$(mean RESULT replace)"
    done
    echo
    wait_header phase
    wait_rows stream WAIT_ drain replace
  fi
done
