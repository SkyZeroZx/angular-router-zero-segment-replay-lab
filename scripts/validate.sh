#!/usr/bin/env bash
set -euo pipefail

# Git Bash on Windows rewrites any argument that looks like an absolute POSIX
# path into a Windows one, which silently turns a container path into a host
# path. Every container path here is written relative to WORKDIR for that
# reason; this is belt and braces for anything added later.
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


# Arms:
#
#   dashboard the headline. The victim configuration, candidate against a
#             byte-identical control.
#   ladder    what the configured fan-out is worth against a fixed URL. Same
#             bytes, same groups, four route configurations.
#   fuzz      the (branches, depth) grid inside a request-line budget.
#   counts    what recognition built and what walking it cost, from a build
#             instrumented only at createSnapshot(), findNode() and findPath().
#   devprod   the same URL against a development build and a production build.
#   ablation  stock against each proof-only edit, same bytes, same output.
#   guard     the async canActivateChild amplifier, swept over its delay.
#   matrix    both request-line sizes, four heaps, through Nginx.
#   backend   the second victim: what one request does to the service behind
#             the SSR tier, through an ordinary resolver.
#
# Every trial gets a brand new worker, and the worker's own command line and its
# own copy of the bundle are checked before anything is measured. A reused
# container at the wrong heap, or an image rebuilt between the build and the
# trial, looks exactly like a result.
ARM="${1:-dashboard}"
TRIALS="${TRIALS:-5}"

# Where trial logs go. Lanes running side by side set this to a directory of
# their own; without that they overwrite each other, because a tag names the
# cell and not the lane.
EVIDENCE="${EVIDENCE_DIR:-evidence}"

OOM='JavaScript heap out of memory|Reached heap limit|FatalProcessOutOfMemory'

fail() { echo "[FAIL] $*" >&2; exit 1; }

app_running() {
  docker compose ps app --status running --format '{{.Service}}' 2>/dev/null | grep -qx app
}

healthy_count() {
  docker compose ps "$1" --format json 2>/dev/null | grep -c '"Health":"healthy"' || true
}

app_cid() { docker compose ps -a -q app 2>/dev/null; }

# The cgroup's own peak counter is monotonic, so the last read before a worker
# dies is its peak up to that moment. One long-lived exec running the loop inside
# the container, not one exec per sample: exec costs a few hundred ms to set up,
# which on a request that is fatal in under a second leaves the final surge
# unsampled. A fatal arm is still a floor and not a peak - the container takes
# the cgroup with it - which is why the differential is read off an arm where
# nothing dies.
PEAK_PID=""
PEAK_FILE=""
PEAK_READ='while :; do cat /sys/fs/cgroup/memory.peak 2>/dev/null || cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes 2>/dev/null; sleep 0.05; done'
peak_start() {
  PEAK_FILE="$(mktemp)"
  docker exec "$(app_cid)" sh -c "$PEAK_READ" >>"$PEAK_FILE" 2>/dev/null &
  PEAK_PID=$!
}
peak_stop() {
  if [[ -n "$PEAK_PID" ]]; then
    kill "$PEAK_PID" 2>/dev/null || true
    wait "$PEAK_PID" 2>/dev/null || true
  fi
  PEAK_PID=""
  awk '/^[0-9]+$/ { if ($1 > m) m = $1 } END { if (m > 0) printf "%.0f\n", m / 1048576; else print "n/a" }' "$PEAK_FILE"
  rm -f "$PEAK_FILE"
}

# SERVICES is "app", or "app nginx" when the client goes through the proxy.
start_fresh_worker() {
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  # Let the daemon release the old container before recreating it.
  sleep 2
  docker compose up -d --force-recreate ${SERVICES:-app} >/dev/null 2>&1 || true

  local waited=0
  while [[ $waited -lt 90 ]]; do
    local ready=1
    for service in ${SERVICES:-app}; do
      [[ "$(healthy_count "$service")" == "1" ]] || ready=0
    done
    [[ $ready == 1 ]] && break
    sleep 1
    waited=$((waited + 1))
  done
  [[ $waited -lt 90 ]] || return 1

  # The heap is the whole measurement; refuse to trust a worker that did not get
  # the one we asked for.
  local cmd
  cmd="$(docker inspect -f '{{json .Config.Cmd}}' "$(app_cid)" 2>/dev/null || true)"
  grep -q "max-old-space-size=${HEAP_MB}" <<<"$cmd" || return 2

  # And the build is the other half of it. Assert the patch inside the process
  # that produces the number, not at the point the image was asked for.
  assert_router_patch || return 3
}

marker_count() {
  docker exec "$(app_cid)" sh -c \
    "grep -c '$1' node_modules/@angular/router/fesm2022/_router-chunk.mjs || true" \
    2>/dev/null | tr -d '\r' | head -1
}

# Greps the running worker's own copy of the bundle for the markers the requested
# ROUTER_PATCH must and must not have put there. Asserting the absent ones too is
# what keeps a stale image from passing as a fresh one.
assert_router_patch() {
  local want="${BUILD_VARIANT:-${ROUTER_PATCH:-none}}"
  local gate shared counted merged
  gate="$(marker_count '__ungatedOutletCheck')"
  shared="$(marker_count '__sharedQueryParams')"
  counted="$(marker_count 'globalThis.__d')"
  merged="$(marker_count 'checkOutletNameUniqueness(merged)')"
  : "${gate:=0}" "${shared:=0}" "${counted:=0}" "${merged:=0}"
  case "$want" in
  stock | none)  [[ $gate == 0 && $shared == 0 && $counted == 0 && $merged == 0 ]] ;;
  count)         [[ $gate == 0 && $shared == 0 && $counted -gt 0 && $merged == 0 ]] ;;
  ungate)        [[ $gate -gt 0 && $shared == 0 && $counted == 0 && $merged == 0 ]] ;;
  70933)         [[ $gate == 0 && $shared -gt 0 && $counted == 0 && $merged == 0 ]] ;;
  zero-segment)  [[ $gate == 0 && $shared == 0 && $counted == 0 && $merged -gt 0 ]] ;;
  both)          [[ $gate == 0 && $shared -gt 0 && $counted == 0 && $merged -gt 0 ]] ;;
  *) return 1 ;;
  esac
}

# Runs one client against a fresh worker and sets TRIAL_*. Deliberately not
# called in a subshell: the caller needs every field, not just the verdict.
TRIAL_VERDICT=""
TRIAL_PEAK=""
TRIAL_MS=""
TRIAL_STATUS=""
TRIAL_SHA=""
TRIAL_BLOCK=""
TRIAL_BYTES=""
TRIAL_DELIVERED=""
TRIAL_SENT=""
trial() {
  local mode="$1" concurrency="$2" log="$3" boot results v
  TRIAL_VERDICT=""
  TRIAL_PEAK="n/a"
  TRIAL_MS="n/a"
  TRIAL_STATUS="n/a"
  TRIAL_SHA="n/a"
  TRIAL_BLOCK="n/a"
  TRIAL_BYTES="n/a"
  TRIAL_DELIVERED=0
  TRIAL_SENT="$2"

  set +e
  start_fresh_worker
  boot=$?
  set -e
  case $boot in
  1) TRIAL_VERDICT=boot-timeout; return ;;
  2) TRIAL_VERDICT=wrong-heap; return ;;
  3) TRIAL_VERDICT=wrong-build; return ;;
  esac

  peak_start
  # A fresh worker means a fresh burst; the backend's tally has to start with
  # it or the line belongs to every trial that came before.
  if [[ "${SERVICES:-app}" == *backend* ]]; then backend_call reset >/dev/null 2>&1 || true; fi
  # --no-deps: the worker is already up, and letting Compose re-resolve the
  # dependency here races with the container it is about to replace.
  CONCURRENCY="$concurrency" docker compose --profile test run --rm --no-deps "$mode" \
    >"$log" 2>&1 || true
  TRIAL_PEAK="$(peak_stop)"

  docker compose logs app >>"$log" 2>&1 || true
  # OOMKilled tells a V8 heap-limit failure from the kernel reaping the
  # container. It has to be false for this to be the bug and not the cgroup.
  docker inspect -f '{{json .State}}' "$(app_cid)" >>"$log" 2>&1 || true

  TRIAL_BYTES="$(grep -o '"pathBytes":[0-9]*' "$log" | head -1 | cut -d: -f2 || true)"
  results="$(grep -o '"results":\[.*\]' "$log" | head -1 || true)"
  TRIAL_MS="$(grep -o '"ms":[0-9]*' <<<"$results" | head -1 | cut -d: -f2 || true)"
  TRIAL_STATUS="$(grep -o '"status":[0-9]*' <<<"$results" | head -1 | cut -d: -f2 || true)"
  TRIAL_SHA="$(grep -o '"sha256":"[0-9a-f]*"' <<<"$results" | tail -1 | cut -d'"' -f4 || true)"
  # How long /health took while the burst was in flight. Express answers it
  # before the Angular handler, so it is availability of the worker and not
  # latency of routing.
  TRIAL_BLOCK="$(grep -o '"health":{"ms":[0-9]*' "$log" | head -1 | grep -o '[0-9]*$' || true)"
  # The probe reports the error code in place of the status when it never got an
  # answer, so a client-side outage and a blocked worker both arrive here as a
  # slow /health. Only a 200 means the worker was reached and answered.
  TRIAL_HEALTH="$(grep -o '"health":{"ms":[0-9]*,"status":[^,}]*' "$log" | head -1 | sed 's/.*"status"://; s/"//g' || true)"
  # How many of the burst actually reached the application. A request the proxy
  # reset, or that Node answered 431 on the request line, never loaded the
  # worker - and a worker that was never loaded looks exactly like a worker that
  # withstood the load. Both have happened in this repository.
  TRIAL_DELIVERED="$(grep -o '"status":[0-9]*' <<<"$results" | wc -l | tr -d ' ')"
  TRIAL_SENT="$concurrency"
  for v in TRIAL_MS TRIAL_STATUS TRIAL_SHA TRIAL_BLOCK TRIAL_BYTES TRIAL_HEALTH; do
    [[ -n "${!v}" ]] || printf -v "$v" '%s' "n/a"
  done

  if [[ "$TRIAL_STATUS" == 431 ]]; then
    # Node answered on the request line: the path was longer than
    # --max-http-header-size and recognition never ran. A 431 carries a status,
    # so the delivered count cannot see it, and the cell reports as a fast
    # healthy worker - which is exactly what a payload that is merely cheap
    # looks like. Three master cells were measured this way before this existed.
    TRIAL_VERDICT=over-budget
  elif grep -Fq '"OOMKilled":true' "$log"; then
    TRIAL_VERDICT=kernel-oom
  elif grep -Eq "$OOM" "$log" && ! app_running; then
    # A fatal worker resets whatever was still in flight, so an undelivered
    # count is expected here and means nothing.
    TRIAL_VERDICT=fatal
  elif [[ "$TRIAL_DELIVERED" -lt "$TRIAL_SENT" ]]; then
    # Requests went missing. Which of two very different things that is depends
    # on whether the worker was under load at the time.
    #
    # /health fast, or never answered at all: the burst never arrived. Nginx
    # running out of large header buffers does this, so does Node answering 431
    # on the request line, and so does the client failing to resolve the worker -
    # a DNS failure takes seconds, which reads as a slow /health unless the
    # status is checked too. A worker that was never loaded is not a healthy one.
    #
    # /health slow: the burst arrived and the worker shed part of it while
    # blocked. Node's own headersTimeout is 60 s, so a worker stalled longer than
    # that destroys connections whose headers it has not finished reading. That
    # is the victim failing, not the harness.
    if [[ "$TRIAL_HEALTH" == 200 ]] && [[ "$TRIAL_BLOCK" != "n/a" ]] && ((TRIAL_BLOCK >= 1000)); then
      TRIAL_VERDICT=healthy
    elif [[ "$TRIAL_DELIVERED" -gt 0 ]] && [[ "$TRIAL_BLOCK" != "n/a" ]] && ((TRIAL_BLOCK >= 1000)); then
      # Part of the burst arrived and the worker then stopped answering its own
      # health endpoint. It never reached the heap limit, so as a rung of a climb
      # it survived - but it did not withstand the load either, and a table that
      # calls it healthy says the opposite of what happened.
      TRIAL_VERDICT=stalled
    else
      TRIAL_VERDICT=undelivered
    fi
  else
    TRIAL_VERDICT=healthy
  fi
}

median() {
  tr ' ' '\n' <<<"$1" | grep -E '^[0-9]+(\.[0-9]+)?$' | sort -n |
    awk '{ v[NR] = $1 } END { if (NR) print v[int((NR + 1) / 2)]; else print "n/a" }'
}

# Repeats one arm TRIALS times. Sets REPEAT_* to the tally and the medians.
REPEAT_FATAL=0
REPEAT_MS=""
REPEAT_PEAK=""
REPEAT_BLOCK=""
REPEAT_STATUS="n/a"
REPEAT_SHA="n/a"
REPEAT_BYTES="n/a"
repeat() {
  local mode="$1" concurrency="$2" tag="$3" i
  REPEAT_FATAL=0
  REPEAT_MS=""
  REPEAT_PEAK=""
  REPEAT_BLOCK=""
  REPEAT_STATUS="n/a"
  REPEAT_SHA="n/a"
  REPEAT_BYTES="n/a"
  for ((i = 1; i <= TRIALS; i++)); do
    trial "$mode" "$concurrency" "$EVIDENCE/${tag}-t${i}.log"
    case "$TRIAL_VERDICT" in
    fatal) REPEAT_FATAL=$((REPEAT_FATAL + 1)) ;;
    healthy) ;;
    stalled) echo "[stalled] ${tag} t${i}: alive but stopped answering /health (${TRIAL_DELIVERED}/${TRIAL_SENT} delivered)" >&2 ;;
    over-budget) fail "${tag} trial ${i}: request line over the header budget, answered 431." ;;
    undelivered) fail "${tag} trial ${i}: only ${TRIAL_DELIVERED}/${TRIAL_SENT} requests reached the app." ;;
    *) fail "${tag} trial ${i}: ${TRIAL_VERDICT}." ;;
    esac
    REPEAT_MS="$REPEAT_MS $TRIAL_MS"
    REPEAT_PEAK="$REPEAT_PEAK $TRIAL_PEAK"
    REPEAT_BLOCK="$REPEAT_BLOCK $TRIAL_BLOCK"
    [[ "$TRIAL_STATUS" == "n/a" ]] || REPEAT_STATUS="$TRIAL_STATUS"
    [[ "$TRIAL_SHA" == "n/a" ]] || REPEAT_SHA="$TRIAL_SHA"
    [[ "$TRIAL_BYTES" == "n/a" ]] || REPEAT_BYTES="$TRIAL_BYTES"
  done
  REPEAT_MS="$(median "$REPEAT_MS")"
  REPEAT_PEAK="$(median "$REPEAT_PEAK")"
  REPEAT_BLOCK="$(median "$REPEAT_BLOCK")"
}

# Echoes the lowest concurrency that loses the worker, by climbing from 1.
#
# An earlier revision probed a ceiling first and bisected, on the assumption
# that a worker surviving N concurrent requests survives everything below N.
# That assumption is false here, measured: 16 KiB against a 128 MiB worker is
# fatal at 6 and at 8, and healthy at 16 and at 64. Through a proxy the burst
# stops arriving together once it is large enough, and requests that arrive
# apart are recognised one at a time and collected one at a time. A search that
# skips counts cannot find a window it steps over, so this climbs.
#
# MAX_CONCURRENCY bounds the climb. It has to sit above every count the tables
# publish, or the documented command cannot reach the cell it is cited for.
first_oom() {
  local tag="$1" max="${MAX_CONCURRENCY:-64}" count

  # START_C continues a climb whose lower counts are already on record. It is
  # not a shortcut past them: skipping counts that were never tried is what the
  # ceiling probe did, and it stepped over the fatal window.
  local attempt
  for ((count = "${START_C:-1}"; count <= max; count++)); do
    # A rung that delivered nothing gets one retry. Docker DNS occasionally fails
    # to resolve the worker on a fresh container, which is transient and not the
    # victim's doing; a second failure is not transient and stops the climb
    # rather than being counted as a rung the worker survived.
    for attempt in 1 2; do
      trial candidate "$count" "$EVIDENCE/${tag}-x${count}.log"
      [[ "$TRIAL_VERDICT" == undelivered && "$attempt" == 1 ]] || break
      echo "[retry] x${count}: ${TRIAL_DELIVERED}/${TRIAL_SENT} delivered, /health ${TRIAL_HEALTH}. Retrying once." >&2
    done
    case "$TRIAL_VERDICT" in
    fatal) echo "$count"; return ;;
    healthy) ;;
    stalled) echo "[stalled] x${count}: alive but stopped answering /health (${TRIAL_DELIVERED}/${TRIAL_SENT} delivered)" >&2 ;;
    over-budget) fail "${tag} x${count}: request line over the header budget, answered 431." ;;
    undelivered) fail "${tag} x${count}: only ${TRIAL_DELIVERED}/${TRIAL_SENT} requests reached the app, /health ${TRIAL_HEALTH}. Twice." ;;
    *) fail "${tag} x${count}: ${TRIAL_VERDICT}." ;;
    esac
  done
  echo "survives $max"
}

# stock | 70933 | zero-segment | both | ungate | count
#
# The two fixes are separate scripts with separate switches, so they compose:
# "both" is not a third patch, it is the two of them applied to the same bundle.
# ungate and count are proof-only edits and go through patch-router.mjs instead.
build_app() {
  local variant="$1" cfg="${2:-production}"
  local rp=none p9=0 pz=0
  case "$variant" in
  stock | none) ;;
  70933) p9=1 ;;
  zero-segment) pz=1 ;;
  both) p9=1 pz=1 ;;
  ungate | count) rp="$variant" ;;
  *) fail "unknown build variant: $variant" ;;
  esac
  ROUTER_PATCH="$rp" PATCH_70933="$p9" PATCH_ZERO_SEGMENT="$pz" BUILD_CONFIG="$cfg"     docker compose build app >/dev/null 2>&1 ||
    fail "build of variant $variant (config $cfg) failed."
  export ROUTER_PATCH="$rp" PATCH_70933="$p9" PATCH_ZERO_SEGMENT="$pz" BUILD_VARIANT="$variant"
}

# Reads the simulated internal service over the lab network, using the client
# image because it is already on it. Not the host: the point of this arm is
# that the traffic never leaves the operator's own network.
backend_call() {
  docker compose run --rm --no-deps --entrypoint node candidate \
    -e "fetch('http://backend:5000/$1').then(r=>r.text()).then(t=>console.log(t))" \
    2>/dev/null | tr -d '\r' | tail -1
}

groups_of() {
  node -e 'let t=0,l=1;for(let i=0;i<=+process.argv[2];i++){t+=l;l*=+process.argv[1];}console.log(t)' "$1" "$2"
}

mkdir -p "$EVIDENCE"
[[ "${SKIP_BUILD:-0}" == 1 ]] ||
  docker compose build app candidate control nginx backend >/dev/null

case "$ARM" in
dashboard)
  # The headline. The victim configuration is the dashboard in app.routes.ts;
  # the URL is a balanced tree of zero-segment outlet groups. The control is
  # byte-identical and differs only in how many DISTINCT names the siblings of
  # each group carry, which is the difference between replaying every group and
  # replaying one per level.
  export HEAP_MB="${HEAP_MB:-256}" SHAPE="${SHAPE:-nested3}"
  export BRANCHES="${BRANCHES:-2}" DEPTH="${DEPTH:-9}" OUTLET=detail PRIM=0
  export SERVICES=app TARGET_URL=http://app:4000
  echo "== ${SHAPE} | heap ${HEAP_MB} MiB | b=${BRANCHES} d=${DEPTH} =="

  # One request each, first. This is the part that needs no burst and no count:
  # same bytes, same groups, and the candidate blocks the worker while the
  # control does not. An earlier revision asserted an OOM at a fixed count
  # instead, which is a threshold, and the arm failed whenever the machine
  # needed one more request than the number that was hardcoded.
  trial control 1 "$EVIDENCE/dashboard-control.log"
  [[ "$TRIAL_VERDICT" == healthy ]] || fail "Control was $TRIAL_VERDICT at one request."
  control_bytes="$TRIAL_BYTES"
  control_block="$TRIAL_BLOCK"
  echo "[PASS] control:   ${TRIAL_BYTES} B, /health ${TRIAL_BLOCK} ms, peak ${TRIAL_PEAK} MiB."

  trial candidate 1 "$EVIDENCE/dashboard-candidate.log"
  [[ "$TRIAL_BYTES" == "$control_bytes" ]] ||
    fail "Not byte-identical: candidate ${TRIAL_BYTES} B, control ${control_bytes} B."
  [[ "$TRIAL_BLOCK" != "n/a" && "$control_block" != "n/a" ]] ||
    fail "No /health timing to compare."
  ((TRIAL_BLOCK > control_block * 10)) ||
    fail "Candidate blocked ${TRIAL_BLOCK} ms against the control's ${control_block} ms; expected far worse."
  echo "[PASS] candidate: same ${TRIAL_BYTES} B, /health ${TRIAL_BLOCK} ms against ${control_block} ms, peak ${TRIAL_PEAK} MiB."

  # Then the burst, climbing rather than guessing. Prints the count; does not
  # depend on it being any particular number.
  first="$(first_oom dashboard)"
  [[ "$first" =~ ^[0-9]+$ ]] || fail "Worker survived every count up to ${MAX_CONCURRENCY:-64}."
  echo "[PASS] candidate: V8 heap limit at ${first} concurrent requests, OOMKilled=false."

  trial control "$first" "$EVIDENCE/dashboard-control-x${first}.log"
  [[ "$TRIAL_VERDICT" == healthy ]] || fail "Control was $TRIAL_VERDICT at ${first} requests."
  echo "[PASS] control:   survived ${first} of the same-length requests."
  ;;

ladder)
  # What the configured fan-out is worth. Same URL, same bytes, same number of
  # replayed groups; only the route configuration changes. Run at a heap where
  # nothing dies, so the cost reads as time and memory rather than as a crash.
  export HEAP_MB="${HEAP_MB:-1024}" BRANCHES="${BRANCHES:-2}" DEPTH="${DEPTH:-9}"
  export OUTLET=detail PRIM=0 SERVICES=app TARGET_URL=http://app:4000
  export CONCURRENCY=1
  echo "== ladder | heap ${HEAP_MB} MiB | b=${BRANCHES} d=${DEPTH} | 1 request | ${TRIALS} fresh workers per rung =="
  printf '%-12s %-8s %-8s %-14s %-11s %-12s %s\n' \
    shape fan-out bytes outcome "median ms" "/health ms" "peak MiB"

  for spec in "dashboard:1" "nested:2" "nested2:4" "nested3:13"; do
    IFS=: read -r shape fanout <<<"$spec"
    export SHAPE="$shape"
    repeat candidate 1 "ladder-${shape}"
    printf '%-12s %-8s %-8s %-14s %-11s %-12s %s\n' \
      "$shape" "$fanout" "$REPEAT_BYTES" "${REPEAT_FATAL}/${TRIALS} fatal" \
      "$REPEAT_MS" "$REPEAT_BLOCK" "$REPEAT_PEAK"
  done
  ;;

fuzz)
  # Which (branches, depth) fits the most groups into a request-line budget.
  # Bytes per group are near constant, so what decides is how many groups fit,
  # and depth never has to approach the parser's own depth > 50 guard.
  export HEAP_MB="${HEAP_MB:-1024}" SHAPE="${SHAPE:-nested3}" OUTLET=detail
  export SERVICES=app TARGET_URL=http://app:4000 CONCURRENCY=1
  export PRIM="${PRIM:-0}" NO_SEP="${NO_SEP:-0}"
  # Wide and shallow beats deep and narrow: what decides is how many groups fit
  # in the budget, not how they are arranged. client/fuzz.mjs searches the grid
  # offline; these are the pairs worth confirming against a real worker.
  PAIRS="${PAIRS:-2:6 2:8 2:9 5:4 9:3 10:3 20:2 30:2 34:2}"
  echo "== fuzz | heap ${HEAP_MB} MiB | ${SHAPE} | prim=${PRIM} nosep=${NO_SEP} | 1 request | ${TRIALS} fresh workers per pair =="
  printf '%-4s %-4s %-8s %-8s %-14s %-11s %s\n' b d groups bytes outcome "median ms" "/health ms"

  for pair in $PAIRS; do
    export BRANCHES="${pair%%:*}" DEPTH="${pair##*:}"
    repeat candidate 1 "fuzz-b${BRANCHES}-d${DEPTH}"
    # A request line over the header budget is answered 431 and never reaches
    # recognition. Without this the cell reports as fast and healthy, which reads
    # exactly like a payload that is simply cheap.
    if [[ "$REPEAT_STATUS" == 431 ]]; then
      printf '%-4s %-4s %-8s %-8s %-14s %-11s %s\n' \
        "$BRANCHES" "$DEPTH" "$(groups_of "$BRANCHES" "$DEPTH")" "$REPEAT_BYTES" \
        "431 over budget" "-" "-"
      continue
    fi
    printf '%-4s %-4s %-8s %-8s %-14s %-11s %s\n' \
      "$BRANCHES" "$DEPTH" "$(groups_of "$BRANCHES" "$DEPTH")" "$REPEAT_BYTES" \
      "${REPEAT_FATAL}/${TRIALS} fatal" "$REPEAT_MS" "$REPEAT_BLOCK"
  done
  ;;

counts)
  # One build, instrumented only at createSnapshot(), findNode() and findPath().
  # "nodes" is what recognition built; "tree steps" is what the four unmemoised
  # Tree getters cost walking it afterwards.
  build_app count
  export HEAP_MB="${HEAP_MB:-2048}" BRANCHES="${BRANCHES:-2}" DEPTH="${DEPTH:-8}"
  export OUTLET=detail SERVICES=app TARGET_URL=http://app:4000
  export ROUTER_PATCH=count CONCURRENCY=1 NO_SEP="${NO_SEP:-0}"
  echo "== counts | heap ${HEAP_MB} MiB | ROUTER_PATCH=count | b=${BRANCHES} d=${DEPTH} | 1 request =="
  printf '%-12s %-9s %-6s %-8s %-10s %-14s %s\n' shape arm prim bytes nodes "tree steps" "/health ms"

  # shape:mode:prim. The master row is the one that tests whether the node law
  # holds when TWO routes match per replayed group instead of one.
  for spec in "dashboard:candidate:0" "nested:candidate:0" "nested2:candidate:0" \
    "nested3:candidate:0" "master:candidate:1" "nested3:control:0" "nested3:primary:0"; do
    IFS=: read -r shape mode prim <<<"$spec"
    export SHAPE="$shape" CONTROL_MODE="$mode" PRIM="$prim"
    service=control
    [[ "$mode" == candidate ]] && service=candidate
    log="$EVIDENCE/counts-${shape}-${mode}.log"
    trial "$service" 1 "$log"
    line="$(grep -o '{"nodes":[0-9]*,"treeSteps":[0-9]*}' "$log" | tail -1 || true)"
    printf '%-12s %-9s %-6s %-8s %-10s %-14s %s\n' "$shape" "$mode" "$prim" "$TRIAL_BYTES" \
      "$(grep -o '"nodes":[0-9]*' <<<"$line" | cut -d: -f2)" \
      "$(grep -o '"treeSteps":[0-9]*' <<<"$line" | cut -d: -f2)" \
      "$TRIAL_BLOCK"
  done
  unset CONTROL_MODE
  export PRIM=0
  build_app none
  ;;

devprod)
  # The same application, the same URL, the same heap, the same concurrency,
  # compiled both ways. @angular/build substitutes ngDevMode with false in an
  # optimized build, so the branch dies and checkOutletNameUniqueness is
  # tree-shaken out of the artefact that gets deployed.
  export HEAP_MB="${HEAP_MB:-256}" SHAPE="${SHAPE:-nested3}"
  export BRANCHES="${BRANCHES:-2}" DEPTH="${DEPTH:-9}" OUTLET=detail PRIM=0
  export SERVICES=app TARGET_URL=http://app:4000 ROUTER_PATCH=none
  C="${CONCURRENCY:-4}"
  echo "== devprod | heap ${HEAP_MB} MiB | ${SHAPE} | b=${BRANCHES} d=${DEPTH} | ${C} requests =="
  printf '%-14s %-26s %-8s %-14s %-11s %s\n' \
    build "checkOutletNameUniqueness" status outcome "median ms" "/health ms"

  for cfg in development production; do
    build_app none "$cfg"
    export BUILD_CONFIG="$cfg"
    present="$(docker compose run --rm --no-deps --entrypoint cat app outlet-check.txt 2>/dev/null | tr -d '\r' | tail -1 || true)"
    repeat candidate "$C" "devprod-${cfg}"
    printf '%-14s %-26s %-8s %-14s %-11s %s\n' \
      "$cfg" "${present:-unknown}" "$REPEAT_STATUS" \
      "${REPEAT_FATAL}/${TRIALS} fatal" "$REPEAT_MS" "$REPEAT_BLOCK"
  done
  export BUILD_CONFIG=production
  build_app none production
  ;;

ablation)
  # Each change on its own, against the same bytes and the same URL. 70933 is
  # angular/angular#70933, included to show what it does not reach. ungate is the
  # one-line ablation: it closes the nested replay only. zero-segment is the fix.
  export HEAP_MB="${HEAP_MB:-256}" SHAPE="${SHAPE:-nested3}"
  export BRANCHES="${BRANCHES:-2}" DEPTH="${DEPTH:-9}" OUTLET=detail PRIM=0
  export SERVICES=app TARGET_URL=http://app:4000 CONCURRENCY="${CONCURRENCY:-4}"
  echo "== ablation | heap ${HEAP_MB} MiB | ${SHAPE} | ${CONCURRENCY} requests | ${TRIALS} fresh workers per build =="
  printf '%-14s %-14s %-11s %-12s %-10s %s\n' build outcome "median ms" "/health ms" "peak MiB" status

  for patch in ${VARIANTS:-stock 70933 ungate zero-segment}; do
    build_app "$patch"
    repeat candidate "$CONCURRENCY" "ablation-${patch}"
    label="$patch"
    printf '%-14s %-14s %-11s %-12s %-10s %s\n' \
      "$label" "${REPEAT_FATAL}/${TRIALS} fatal" "$REPEAT_MS" "$REPEAT_BLOCK" \
      "$REPEAT_PEAK" "$REPEAT_STATUS"
  done
  build_app stock
  ;;

guard)
  # One async canActivateChild, declared once on the parent. It is the only place
  # recognition and activation yield the event loop, so concurrent requests
  # overlap their trees instead of serialising behind one another.
  export HEAP_MB="${HEAP_MB:-256}" SHAPE=guarded OUTLET=detail PRIM=0
  export BRANCHES="${BRANCHES:-2}" DEPTH="${DEPTH:-9}"
  export SERVICES=app TARGET_URL=http://app:4000
  echo "== guard | heap ${HEAP_MB} MiB | b=${BRANCHES} d=${DEPTH} =="
  printf '%-18s %-20s %s\n' canActivateChild "requests to OOM" "control at that count"

  for ms in ${DELAYS:-0 2 10}; do
    export CANACTIVATECHILD_MS="$ms"
    first="$(first_oom "guard-${ms}ms")"
    if [[ ! "$first" =~ ^[0-9]+$ ]]; then
      printf '%-18s %-20s %s\n' "${ms} ms" "$first" "-"
      continue
    fi
    trial control "$first" "$EVIDENCE/guard-${ms}ms-control.log"
    [[ "$TRIAL_VERDICT" == healthy ]] || fail "Control was $TRIAL_VERDICT at ${ms} ms, x${first}."
    printf '%-18s %-20s %s\n' "${ms} ms" "$first" "${first}/${first} survived"
  done
  export CANACTIVATECHILD_MS=0
  ;;

matrix)
  # Through Nginx, whose two non-default settings are the 16k request line an AWS
  # Elastic Load Balancer forwards and a response-header buffer big enough for
  # the redirect the app answers with. Both sizes pass with Node's own default
  # header budget, proxy headers included.
  # VIA=nginx (default) goes through the proxy; VIA=app goes straight at the
  # worker. Both exist because "the requests serialised" and "the proxy
  # serialised them" are different claims and the grid has to be able to tell
  # them apart.
  if [[ "${VIA:-nginx}" == app ]]; then
    export SERVICES=app TARGET_URL=http://app:4000
  else
    export SERVICES="app nginx" TARGET_URL=http://nginx:8080
  fi
  export OUTLET=detail PRIM="${PRIM:-0}" NO_SEP="${NO_SEP:-0}"
  export CANACTIVATECHILD_MS=0
  echo "== matrix | via ${VIA:-nginx} | prim=${PRIM:-0} nosep=${NO_SEP:-0} =="
  printf '%-6s %-10s %-8s %s\n' size shape heap "requests to OOM"

  for size in ${SIZES:-8k 16k}; do
    case "$size" in
    # The (branches, depth) each budget uses. They are knobs because the byte
    # cost per group depends on the sibling set: prim and no-sep move it, and a
    # pair that fits one spelling overruns another and gets answered 431.
    8k) export BRANCHES="${B8:-2}" DEPTH="${D8:-8}" ;;
    16k) export BRANCHES="${B16:-2}" DEPTH="${D16:-9}" ;;
    esac
    for shape in ${SHAPES:-nested2 nested3}; do
      export SHAPE="$shape"
      for heap in ${HEAPS:-128 256 512 1024}; do
        export HEAP_MB="$heap"
        printf '%-6s %-10s %-8s %s\n' "$size" "$shape" "${heap}M" \
          "$(first_oom "matrix-${size}-${shape}-${heap}")"
      done
    done
  done
  ;;

backend)
  # The second victim. The SSR worker survives every cell in this arm; what
  # takes the damage is the service its resolver talks to.
  #
  # /resolved is the four-line victim configuration with an ordinary resolver
  # on it. Fan-out 1, so every query is one replayed group and nothing else.
  export HEAP_MB="${HEAP_MB:-1024}" SHAPE=resolved OUTLET=detail PRIM=0
  export SERVICES="app backend" TARGET_URL=http://app:4000
  export BACKEND_URL=http://backend:5000 BACKEND_MS="${BACKEND_MS:-250}"
  export CONCURRENCY=1 REQUEST_TIMEOUT_MS="${REQUEST_TIMEOUT_MS:-600000}"
  PAIRS="${PAIRS:-2:3 2:5 2:6}"
  echo "== backend | ${BACKEND_MS} ms per query | 1 request | heap ${HEAP_MB} MiB =="
  printf '%-5s %-5s %-8s %-8s %-8s %-10s %-9s %-11s %s\n' \
    b d groups bytes status 'request ms' queries 'peak in-flight' 'query span ms'

  for pair in $PAIRS; do
    export BRANCHES="${pair%%:*}" DEPTH="${pair##*:}"
    trial candidate 1 "$EVIDENCE/backend-b${BRANCHES}-d${DEPTH}.log"
    [[ "$TRIAL_VERDICT" == healthy ]] || fail "backend arm: worker was $TRIAL_VERDICT."
    st="$(backend_call stats)"
    printf '%-5s %-5s %-8s %-8s %-8s %-10s %-9s %-11s %s\n' \
      "$BRANCHES" "$DEPTH" "$(groups_of "$BRANCHES" "$DEPTH")" "$TRIAL_BYTES" \
      "$TRIAL_STATUS" "$TRIAL_MS" \
      "$(grep -o '"queries":[0-9]*' <<<"$st" | cut -d: -f2)" \
      "$(grep -o '"peakInFlight":[0-9]*' <<<"$st" | cut -d: -f2)" \
      "$(grep -o '"spanMs":[0-9]*' <<<"$st" | cut -d: -f2)"
  done

  # The same URL with one wrapper name instead of distinct ones. Same bytes,
  # same groups, same parse - and the resolver runs depth + 1 times.
  export BRANCHES=2 DEPTH=6
  trial control 1 "$EVIDENCE/backend-control.log"
  st="$(backend_call stats)"
  echo "control, byte-identical: $st"

  unset BACKEND_URL
  ;;

probe)
  # One trial at one concurrency, printed as a verdict. A ramp is a sequence of
  # these, and every count in it is independent of the others: fresh worker, C
  # requests, does it die. So the ramp can be split across lanes by count rather
  # than walked, which is what scripts/sweep.sh does. Nothing is skipped, so the
  # lowest fatal it finds is the same one a walk would stop on.
  export HEAP_MB="${HEAP_MB:-256}" SHAPE="${SHAPE:-nested3}" OUTLET=detail
  export PRIM="${PRIM:-0}" NO_SEP="${NO_SEP:-0}"
  export BRANCHES="${BRANCHES:-2}" DEPTH="${DEPTH:-9}"
  if [[ "${VIA:-app}" == nginx ]]; then
    export SERVICES="app nginx" TARGET_URL=http://nginx:8080
  else
    export SERVICES=app TARGET_URL=http://app:4000
  fi
  C="${CONCURRENCY:?probe needs CONCURRENCY}"
  trial candidate "$C" "$EVIDENCE/probe-${SHAPE}-${HEAP_MB}-x${C}.log"
  printf '%-8s %-10s %-6s %-6s %s\n' \
    "${HEAP_MB}M" "$SHAPE" "x${C}" "$TRIAL_BYTES" "$TRIAL_VERDICT"
  ;;
resources)
  # withRouterResources(), the second way to reach the same missing check. The
  # URL here is flat - distinct outlet names, no nesting - and the duplicated
  # siblings are manufactured by mergeEmptyPathMatches() one level below where
  # checkOutletNameUniqueness() runs, so ungating alone does not close it.
  #
  # The feature is developer preview and opt-in; ROUTER_RESOURCES=1 is read at
  # runtime by app.config.ts, so the same image serves both columns.
  export ROUTER_RESOURCES=1 FLAT_ROOT=1 SHAPE="" OUTLET=a PRIM=0 NO_SEP=0
  export SERVICES=app TARGET_URL=http://app:4000
  echo "== resources | withRouterResources() | flat URL, distinct outlet names =="
  printf '%-10s %-8s %-8s %s\n' outlets heap patch "requests to OOM"

  for patch in ${VARIANTS:-stock 70933 zero-segment}; do
    build_app "$patch"
    for outlets in ${OUTLETS:-1246 2400}; do
      export FLAT="$outlets"
      for heap in ${HEAPS:-256 512}; do
        export HEAP_MB="$heap"
        printf '%-10s %-8s %-8s %s\n' "$outlets" "${heap}M" "$patch" \
          "$(first_oom "resources-${outlets}-${heap}-${patch}")"
      done
    done
  done
  export ROUTER_RESOURCES=0
  build_app stock
  ;;

fixcheck)
  # The two fixes against the same attack, and the question a maintainer asks
  # first: does an ordinary URL still render the same page. stock is unpatched,
  # 70933 is angular/angular#70933, zero-segment is the proposed fix, both is the
  # two of them on the same bundle.
  export HEAP_MB="${HEAP_MB:-256}" SHAPE="${SHAPE:-nested3}"
  export BRANCHES="${BRANCHES:-2}" DEPTH="${DEPTH:-9}" OUTLET=detail PRIM=0
  export SERVICES=app TARGET_URL=http://app:4000 CONCURRENCY="${CONCURRENCY:-4}"
  echo "== fixcheck | heap ${HEAP_MB} MiB | ${SHAPE} | ${CONCURRENCY} requests =="
  printf '%-14s %-12s %-10s %-12s %s
' build attack "peak MiB" "/health ms" "ordinary URL"

  for variant in ${VARIANTS:-stock 70933 zero-segment both}; do
    build_app "$variant"
    trial candidate "$CONCURRENCY" "$EVIDENCE/fixcheck-${variant}.log"
    attack="$TRIAL_STATUS"
    [[ "$TRIAL_VERDICT" == fatal ]] && attack="V8 OOM"
    apeak="$TRIAL_PEAK"
    ablock="$TRIAL_BLOCK"

    # A legal URL through the same build: one group, one route, the page a real
    # user asks for. Its bytes are what a regression would move.
    DEPTH=0 BRANCHES=1 trial control 1 "$EVIDENCE/fixcheck-${variant}-ordinary.log"
    printf '%-14s %-12s %-10s %-12s %s
'       "$variant" "$attack" "$apeak" "$ablock" "${TRIAL_STATUS} sha ${TRIAL_SHA:0:16}"
  done
  build_app stock
  ;;

*)
  echo "Usage: $0 [dashboard|ladder|fuzz|counts|devprod|ablation|guard|matrix|backend|probe|resources|fixcheck]" >&2
  exit 2
  ;;
esac

docker compose down -v --remove-orphans >/dev/null 2>&1 || true
