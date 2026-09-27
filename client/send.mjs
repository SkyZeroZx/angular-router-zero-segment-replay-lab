import http from "node:http";
import { createHash } from "node:crypto";
import { buildTarget, buildPrimaryOnly, buildFlat, groupCount } from "./workloads.mjs";

const target = new URL(process.env.TARGET_URL ?? "http://127.0.0.1:4000");
const REQUEST_TIMEOUT_MS = Number(process.env.REQUEST_TIMEOUT_MS ?? "600000");

// The fan-out ladder. Same dashboard, same named outlet, different contents:
//   dashboard  fan-out  1   one child route and nothing nested
//   nested     fan-out  2   the panel holds one always-on aside
//   nested2    fan-out  4   the aside holds two widgets
//   nested3    fan-out 13   three panels, three widgets in each
//   master     fan-out 13   plus a PRIMARY sibling route: two matches per group
//   guarded    fan-out 13   with one async canActivateChild on the parent
//   resolved   fan-out  1   with an ordinary resolver, which reports its own call count
const SHAPES = ["dashboard", "nested", "nested2", "nested3", "master", "guarded", "resolved", "live", "res", "flat"];

const shape = process.env.SHAPE ?? "dashboard";
// candidate  distinct wrapper names among siblings: every group replays
// control    the same bytes with one wrapper name, so siblings overwrite
// primary    the same wrapper tree with no named outlet in the replayed set
const mode = process.env.MODE ?? "candidate";
const branches = Number(process.env.BRANCHES ?? "6");
const depth = Number(process.env.DEPTH ?? "4");
// The configured named outlet. Its spelling is paid in EVERY group, so it moves
// the byte count a long way; read from here rather than assumed.
const outlet = process.env.OUTLET ?? "detail";
// Whether the replayed sibling set carries a primary sibling too. None of these
// shapes declares a primary child route, so a primary sibling fails recognition
// outright instead of fanning out. Off by default.
const prim = process.env.PRIM === "1";
// How many distinct outlet names a flat URL declares. Zero means the nested
// grammar; anything else switches to buildFlat.
const flat = Number(process.env.FLAT ?? "0");
// Drop the optional "//" between sibling wrapper groups: 2 bytes each.
const noSep = process.env.NO_SEP === "1";
const concurrency = Number(process.env.CONCURRENCY ?? "1");
// Timed on its own socket while the burst is in flight. /health is answered by
// Express before the Angular handler, so how long it takes is availability of
// the worker, not latency of routing.
const probe = process.env.PROBE !== "0";
const probeAfterMs = Number(process.env.PROBE_AFTER_MS ?? "250");
const follow = process.env.FOLLOW === "1";

if (!SHAPES.includes(shape)) {
  throw new Error(`Unsupported SHAPE=${shape}. Expected one of ${SHAPES.join(", ")}.`);
}
if (!["candidate", "control", "primary"].includes(mode)) {
  throw new Error(`Unsupported MODE=${mode}. Expected candidate, control or primary.`);
}

const path = flat
  ? buildFlat({ shape: process.env.FLAT_ROOT === "1" ? "" : shape, count: flat, mode })
  : mode === "primary"
    ? buildPrimaryOnly({ shape, branches, depth, mode })
    : buildTarget({ shape, mode, branches, depth, prim, outlet, noSep });
const pathBytes = Buffer.byteLength(path);
const groups = groupCount(branches, depth);

console.log(
  JSON.stringify({
    shape,
    mode,
    outlet,
    branches,
    depth,
    prim,
    noSep,
    groups,
    // What the candidate replays. The control declares the same groups in the
    // same bytes, but its same-named siblings overwrite, so it replays depth + 1.
    replayedGroups: mode === "control" ? depth + 1 : groups,
    concurrency,
    pathBytes,
    // Node's own default header budget is 16 KiB, so this needs no tuning.
    requestLineBytes: pathBytes + "GET  HTTP/1.1\r\n".length,
    heapMb: Number(process.env.HEAP_MB ?? "0") || undefined,
    canActivateChildMs: process.env.CANACTIVATECHILD_MS,
    destination: target.origin,
  }),
);

function get(requestPath) {
  return new Promise((resolve) => {
    const started = Date.now();
    const hash = createHash("sha256");
    // A socket of its own per request, so the concurrency is real and the
    // /health probe cannot queue behind the burst at the client end.
    const req = http.get(
      {
        host: target.hostname,
        port: target.port,
        path: requestPath,
        timeout: REQUEST_TIMEOUT_MS,
        agent: false,
      },
      (res) => {
        let bytes = 0;
        let body = "";
        res.on("data", (chunk) => {
          bytes += chunk.length;
          hash.update(chunk);
          if (body.length < 4096) body += chunk;
        });
        res.on("end", () =>
          resolve({
            status: res.statusCode,
            bytes,
            body,
            sha256: hash.digest("hex"),
            locationBytes: res.headers.location
              ? Buffer.byteLength(res.headers.location)
              : undefined,
            _location: res.headers.location,
            ms: Date.now() - started,
          }),
        );
      },
    );
    req.on("timeout", () => {
      req.destroy();
      resolve({ error: "timeout", ms: Date.now() - started });
    });
    req.on("error", (error) =>
      resolve({ error: error.code ?? error.message, ms: Date.now() - started }),
    );
  });
}

async function request(index) {
  const { _location, body: _body, ...first } = await get(path);
  const redirected = first.status >= 300 && first.status < 400;
  if (!follow || !_location || !redirected) return { index, ...first };
  const hop = new URL(_location, target);
  const { _location: _drop, body: _b2, ...followed } = await get(hop.pathname + hop.search);
  return { index, ...first, followed };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const burst = Promise.all(
  Array.from({ length: concurrency }, (_, index) => request(index)),
);

let health;
if (probe) {
  await sleep(probeAfterMs);
  const probed = await get("/health");
  health = { ms: probed.ms, status: probed.status ?? probed.error };
}

const results = await burst;

console.log(
  JSON.stringify({
    shape, mode, concurrency, groups, pathBytes,
    health,
    results: results.map(({ body: _b, ...r }) => r),
  }),
);
