#!/usr/bin/env bash
#
# Cycle cost of hybrid_systolic_heap under an equal enqueue/dequeue/replace mix, for three value
# orders: uniform random, nondecreasing and nonincreasing.
#
# Each run fills the queue to half its capacity, then issues 12000 ops drawn 1/3 each enqueue,
# dequeue and replace from a master that holds each op until it is accepted. An op's cost is the
# cycles it waits plus one. Averaged over seeds 1, 7 and 13, the script prints two tables, each
# with rows per value order:
#   - the mean cost of each op type, and the mean dequeue cost after each op type;
#   - what the waiting reads (dequeues and replaces) waited on, in cycles per read, split by the
#     op before the read. Causes are checked in order and the first match counts:
#       own_buf    the buffer serving the head is still settling from its last command
#       other_buf  the other buffer is still settling, so the two heads cannot be compared
#       in_slot    the serving buffer's input slot is busy
#       top_move   a tree top is moving
#       max_busy   a tree holds a value above the head and that tree is busy
#       max_idle   a tree holds a value above the head and is idle, so the value is on its way up
#
# Usage (from anywhere, with iverilog on PATH):
#   hwpq/hybrid_systolic_bram_heap/perf/equal_mix.sh [out_dir]
#   TREES=4 TREE_QS=255 SYS=8 hwpq/hybrid_systolic_bram_heap/perf/equal_mix.sh
#
# Settings, as environment variables:
#   TREES    tree count (11)
#   TREE_QS  nodes per tree, a power of 2 minus 1 (2047)
#   SYS      systolic buffer size, even and at least 6 (16)
#   WIDTH    data width in bits (128)
#   M        measured ops per run (12000)
#   STEP     largest step between successive values in the monotone orders (3)
# Logs go to out_dir, by default build/hybrid_equal_mix/ under the repository root.
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../.." && pwd)"
SRC="${ROOT}/hwpq/hybrid_systolic_bram_heap/src"
OUT="${1:-${ROOT}/build/hybrid_equal_mix}"
TREES=${TREES:-11}; TREE_QS=${TREE_QS:-2047}; SYS=${SYS:-16}; WIDTH=${WIDTH:-128}; M=${M:-12000}
STEP=${STEP:-3}

if (( TREE_QS < 3 || (TREE_QS + 1) & TREE_QS )); then echo "TREE_QS must be 2^k - 1"; exit 1; fi
if (( SYS % 2 || SYS < 6 )); then echo "SYS must be even and at least 6"; exit 1; fi
CAP=$(( TREES * TREE_QS + 2 * (SYS - 2) ))  # trees plus both systolic buffers at threshold
mkdir -p "${OUT}"

for order in uniform nondecreasing nonincreasing; do
  mono=""
  [ "${order}" = nondecreasing ] && mono="-DMONO=1"
  [ "${order}" = nonincreasing ] && mono="-DMONO=-1"
  iverilog -g2012 -o "${OUT}/${order}.vvp" -s equal_mix_tb ${mono} \
    -DN=$(( CAP / 2 )) -DM="${M}" -DCAP="${CAP}" -DSTEP="${STEP}" \
    -DHYBRID_TREE_COUNT="${TREES}" -DHYBRID_BRAM_TREE_QUEUE_SIZE="${TREE_QS}" \
    -DHYBRID_SYSTOLIC_QUEUE_SIZE="${SYS}" -DHYBRID_DATA_WIDTH="${WIDTH}" \
    "${SRC}/hybrid_typedef.sv" "${SRC}/rams_tdp_rf_rf.sv" "${SRC}/bram_tree.sv" \
    "${SRC}/bram_tree_pair.sv" "${SRC}/hybrid_systolic_heap.sv" "${HERE}/equal_mix_tb.sv" \
    > "${OUT}/${order}.comp" 2>&1 || { cat "${OUT}/${order}.comp"; exit 1; }
  for s in 1 7 13; do vvp "${OUT}/${order}.vvp" +seed=${s} > "${OUT}/${order}_${s}.log" 2>&1 & done
done
wait
if grep -l TIMEOUT "${OUT}"/*_*.log; then echo "runs above timed out"; exit 1; fi

# mean <tag> <key> <logs...>: mean of <key>=<value> over the lines of the logs that start <tag>.
mean() {
  local tag=$1 key=$2; shift 2
  awk -v tag="${tag}" -v key="${key}" '$1 == tag {
      for (i = 2; i <= NF; i++) { split($i, kv, "="); if (kv[1] == key) { sum += kv[2]; n++ } }
    }
    END { printf "%.2f", sum / n }' "$@"
}
res() { mean RESULT "$1" "${logs[@]}"; }
wait_after() { mean "WAIT_after_$1" "$2" "${logs[@]}"; }

echo "${TREES} trees x ${TREE_QS}, systolic ${SYS}, ${WIDTH} bit, capacity ${CAP}; cycles per op"
row="%-14s %-6s %-6s %-6s %-8s | %-9s %-9s %-9s\n"
printf "${row}" values enq deq rep overall "deq a.enq" "deq a.deq" "deq a.rep"
for order in uniform nondecreasing nonincreasing; do
  logs=("${OUT}/${order}"_*.log)
  printf "${row}" "${order}" "$(res enq)" "$(res deq)" "$(res rep)" "$(res overall)" \
    "$(res deq_after_enq)" "$(res deq_after_deq)" "$(res deq_after_rep)"
done

echo
echo "read waits, cycles per read"
row="%-14s %-9s %-9s %-9s %-9s %-9s %-9s %-9s %-9s\n"
printf "${row}" values after own_buf other_buf in_slot top_move max_busy max_idle other
for order in uniform nondecreasing nonincreasing; do
  logs=("${OUT}/${order}"_*.log)
  for op in enq deq rep; do
    printf "${row}" "${order}" "${op}" "$(wait_after ${op} own_buffer_settling)" \
      "$(wait_after ${op} other_buffer_settling)" "$(wait_after ${op} input_slot_busy)" \
      "$(wait_after ${op} tree_top_moving)" "$(wait_after ${op} tree_max_above_head_tree_busy)" \
      "$(wait_after ${op} tree_max_above_head_tree_idle)" "$(wait_after ${op} other)"
  done
done
