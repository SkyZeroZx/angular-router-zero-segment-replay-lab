#!/usr/bin/env bash
set -euo pipefail

export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"
cd "$(dirname "$0")/.."

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

# Finds the lowest concurrency that loses the worker, by testing a range of
# counts across lanes instead of walking it.
#
# Every count is an independent trial: fresh worker, C requests, does it die. So
# they can run side by side, and the lowest fatal among them is the same number a
# walk would have stopped on -- as long as every count in the range is tried,
# which is the whole difference from the ceiling-probing search this replaced.
#
#   FROM=44 TO=50 HEAP_MB=512 SHAPE=nested3 BRANCHES=2 DEPTH=8 ./scripts/sweep.sh
#
# A lane is a Compose project with its own containers, ports, evidence directory
# and a physical core of its own.

# Either a concurrency range for one cell, or an explicit list of probes.
#
#   FROM=44 TO=50 HEAP_MB=512 ./scripts/sweep.sh        one cell, C=44..50
#   CELLS="256:5:1246 256:3:2400" ./scripts/sweep.sh    heap:concurrency:flat
#
# A probe is a fresh worker and one burst, so the list can run across lanes
# exactly as the range does.
CELLS="${CELLS:-}"
FROM="${FROM:-0}"
TO="${TO:-0}"
[[ -n "$CELLS" || "$TO" -gt 0 ]] || { echo "set CELLS or FROM/TO" >&2; exit 2; }
LANES="${LANES:-4}"
CORES_PER_LANE="${CORES_PER_LANE:-2}"
OUT="${OUT:-results/sweep}"

mkdir -p "$OUT"
: >"$OUT/verdicts.txt"

if [[ -n "$CELLS" ]]; then
  echo "== ${SHAPE:-nested3} | $(wc -w <<<"$CELLS") cells | ${LANES} lanes =="
else
  echo "== sweep C=${FROM}..${TO} | ${SHAPE:-nested3} | ${HEAP_MB:-256} MiB | ${LANES} lanes =="
fi

COMPOSE_PROJECT_NAME="replaylane0" docker compose build app candidate control nginx backend >/dev/null

run_lane() {
  local lane="$1"
  shift
  local first=$((lane * CORES_PER_LANE))
  local last=$((first + CORES_PER_LANE - 1))
  local c heap conc flatn
  for c in "$@"; do
    if [[ "$c" == *:* ]]; then
      IFS=: read -r heap conc flatn <<<"$c"
    else
      heap="${HEAP_MB:-256}" conc="$c" flatn="${FLAT:-0}"
    fi
    COMPOSE_PROJECT_NAME="replaylane${lane}" \
    HEAP_MB="$heap" FLAT="$flatn" \
    APP_CPUSET="${first}-${last}" \
    APP_PORT=$((4000 + lane * 10)) \
    NGINX_PORT=$((8080 + lane * 10)) \
    BACKEND_PORT=$((5000 + lane * 10)) \
    EVIDENCE_DIR="evidence/lane${lane}" \
    CONCURRENCY="$conc" \
      ./scripts/validate.sh probe 2>&1 | grep -E '^[0-9]+M' >>"$OUT/verdicts.txt" || true
  done
}

counts=()
if [[ -n "$CELLS" ]]; then
  for c in $CELLS; do counts+=("$c"); done
else
  for ((c = FROM; c <= TO; c++)); do counts+=("$c"); done
fi

pids=()
for ((lane = 0; lane < LANES; lane++)); do
  lane_counts=()
  for ((i = lane; i < ${#counts[@]}; i += LANES)); do
    lane_counts+=("${counts[$i]}")
  done
  [[ ${#lane_counts[@]} -gt 0 ]] || continue
  run_lane "$lane" "${lane_counts[@]}" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || true; done

for ((lane = 0; lane < LANES; lane++)); do
  COMPOSE_PROJECT_NAME="replaylane${lane}" docker compose down -v --remove-orphans >/dev/null 2>&1 || true
done

echo
sort -t'x' -k2 -n "$OUT/verdicts.txt"
echo
[[ -z "$CELLS" ]] || exit 0
lowest="$(awk '$4 == "fatal" || $5 == "fatal" { gsub(/x/, "", $3); print $3 }' "$OUT/verdicts.txt" | sort -n | head -1)"
if [[ -n "$lowest" ]]; then
  echo "lowest fatal in ${FROM}..${TO}: ${lowest}"
else
  echo "no fatal in ${FROM}..${TO}"
fi
