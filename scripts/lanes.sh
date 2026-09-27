#!/usr/bin/env bash
set -euo pipefail

export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"
cd "$(dirname "$0")/.."

# Only one measurement run at a time, whatever shape it takes: one sequential
# validate.sh, or one lanes.sh driving several. Two of them share the Docker
# daemon and, if they share a project name, tear down each other's containers
# mid-trial. That produces wrong-heap and boot-timeout verdicts and log files
# holding two interleaved runs, which is what it looked like the first two
# times it happened here.
#
# mkdir is atomic, so it is the lock. lanes.sh owns it on behalf of the
# validate.sh processes it spawns, which is why they skip it.
LAB_LOCK="${TMPDIR:-/tmp}/angular-router-replay-lab.lock"
if [[ -z "${LAB_LOCK_OWNER:-}" ]]; then
  if ! mkdir "$LAB_LOCK" 2>/dev/null; then
    echo "[FAIL] another run holds ${LAB_LOCK}." >&2
    echo "       Stop it, then: rmdir ${LAB_LOCK}" >&2
    exit 2
  fi
  # shellcheck disable=SC2064
  trap "rmdir '${LAB_LOCK}' 2>/dev/null || true" EXIT
  export LAB_LOCK_OWNER="$$"
fi


# Runs matrix cells across several lanes at once.
#
# A lane is a Compose project of its own, with its own container names, its own
# network, its own published ports and its own evidence directory. Docker keeps
# those apart on its own. What Docker does NOT keep apart is the CPU, and CPU is
# what this lab measures, so each lane also pins its worker to a disjoint set of
# cores.
#
# That pinning is not free: a worker on 2 cores is not the worker on 16 cores
# that the sequential runs measured. Numbers from here are comparable with each
# other and not with a sequential run, so a grid is measured one way or the
# other and never half and half.
#
#   ./scripts/lanes.sh cells.txt
#   LANES=4 CORES_PER_LANE=2 ./scripts/lanes.sh cells.txt
#
# One cell per line, blank lines and # comments ignored:
#
#   via   shape    heap  size  maxc  prim  nosep
#   app   nested3  512   16k   32    0     0
#   app   master   128   16k   20    1     1
#
# What a lane measures is a threshold: the request count at which the worker
# reaches its heap limit. That is the quantity this lab reports, and it is the
# one least sensitive to how fast the cores are, because without an async hook
# the requests queue and what accumulates is the parsed URL of each waiting one.
# Milliseconds are not measured here; those tables stay sequential.

LANES="${LANES:-4}"
CORES_PER_LANE="${CORES_PER_LANE:-2}"
CELLS_FILE="${1:?usage: lanes.sh <cells-file>}"
OUT="${OUT:-results/lanes}"

mapfile -t CELLS < <(grep -vE '^\s*(#|$)' "$CELLS_FILE")
[[ ${#CELLS[@]} -gt 0 ]] || { echo "no cells in $CELLS_FILE" >&2; exit 2; }

echo "== ${#CELLS[@]} cells over ${LANES} lanes, ${CORES_PER_LANE} cores each =="
nproc_total="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"
needed=$((LANES * CORES_PER_LANE))
if [[ "$nproc_total" -gt 0 && "$needed" -gt "$nproc_total" ]]; then
  echo "[FAIL] ${needed} cores requested, ${nproc_total} available." >&2
  exit 2
fi

mkdir -p "$OUT"

# Build once, into lane 0's project, then let the other lanes reuse the layer
# cache. Building inside each lane in parallel fights over the same cache and
# produces the same image four times.
echo "-- building --"
COMPOSE_PROJECT_NAME="replaylane0" docker compose build app candidate control nginx backend >/dev/null

run_lane() {
  local lane="$1"
  shift
  local first=$((lane * CORES_PER_LANE))
  local last=$((first + CORES_PER_LANE - 1))
  local log="${OUT}/lane${lane}.txt"

  : >"$log"
  local cell via shape heap size maxc prim nosep
  for cell in "$@"; do
    read -r via shape heap size maxc prim nosep <<<"$cell"
    {
      echo "== lane ${lane} | cores ${first}-${last} | ${via} ${shape} ${heap}M ${size} prim=${prim:-0} nosep=${nosep:-0} =="
      COMPOSE_PROJECT_NAME="replaylane${lane}" \
      APP_CPUSET="${first}-${last}" \
      APP_PORT=$((4000 + lane * 10)) \
      NGINX_PORT=$((8080 + lane * 10)) \
      BACKEND_PORT=$((5000 + lane * 10)) \
      EVIDENCE_DIR="evidence/lane${lane}" \
      SKIP_BUILD=0 \
      VIA="$via" SHAPES="$shape" HEAPS="$heap" SIZES="$size" \
      MAX_CONCURRENCY="${maxc:-16}" PRIM="${prim:-0}" NO_SEP="${nosep:-0}" \
        ./scripts/validate.sh matrix 2>&1 | grep -vE '^\s' || true
    } >>"$log" 2>&1
  done
  echo "-- lane ${lane} done --"
}

pids=()
for ((lane = 0; lane < LANES; lane++)); do
  lane_cells=()
  for ((i = lane; i < ${#CELLS[@]}; i += LANES)); do
    lane_cells+=("${CELLS[$i]}")
  done
  [[ ${#lane_cells[@]} -gt 0 ]] || continue
  run_lane "$lane" "${lane_cells[@]}" &
  pids+=($!)
done

status=0
for pid in "${pids[@]}"; do
  wait "$pid" || status=1
done

echo
echo "== results =="
for f in "$OUT"/lane*.txt; do
  [[ -f "$f" ]] || continue
  grep -E '^(==|16k|8k|\[FAIL)' "$f" || true
done

# Every lane's project, torn down.
for ((lane = 0; lane < LANES; lane++)); do
  COMPOSE_PROJECT_NAME="replaylane${lane}" docker compose down -v --remove-orphans >/dev/null 2>&1 || true
done

exit "$status"
