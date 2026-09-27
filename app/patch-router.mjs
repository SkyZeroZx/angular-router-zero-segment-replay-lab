// Proof-only edits to @angular/router, applied at image build time by the
// ROUTER_PATCH build arg. "none" leaves the package stock, which is what every
// headline number in the README uses.
//
//   count        report what recognition built and what the tree walk cost:
//                nodes created, and steps taken by findNode()/findPath()
//   ungate       run checkOutletNameUniqueness() in production too, at the call
//                site it has today. Closes the nested replay and leaves the
//                flat variant open, which is why it is an ablation and not the
//                fix. The fix is patch-zero-segment.mjs.

import { readFileSync, writeFileSync } from "node:fs";

const FILE = "node_modules/@angular/router/fesm2022/_router-chunk.mjs";

// Recognizer.processChildren(), verbatim from @angular/router 22.2.0.
const GATE_ANCHOR = `    const mergedChildren = mergeEmptyPathMatches(children);
    if (typeof ngDevMode === 'undefined' || ngDevMode) {
      checkOutletNameUniqueness(mergedChildren);
    }`;

// Recognizer.createSnapshot(), verbatim from @angular/router 22.2.0.
const SNAPSHOT_ANCHOR = `  createSnapshot(injector, route, segments, parameters, parentRoute) {
    const snapshot = new ActivatedRouteSnapshot(`;

// The identity search the four unmemoised Tree getters run from the root.
const FIND_NODE_ANCHOR = `function findNode(value, node) {
  if (value === node.value) return node;`;
const FIND_PATH_ANCHOR = `function findPath(value, node) {
  if (value === node.value) return [node];`;

// One debounced line per request burst, reset after each line so the line
// belongs to the burst that produced it rather than to everything the worker has
// served since it booted. Reporting is debounced off the last counted event, so
// it fires after the tree walk and not between recognition and activation.
const REPORTER = `function __report() {
  clearTimeout(globalThis.__t);
  globalThis.__t = setTimeout(() => {
    console.log(JSON.stringify({
      nodes: globalThis.__n ?? 0,
      treeSteps: globalThis.__d ?? 0,
    }));
    globalThis.__n = 0;
    globalThis.__d = 0;
  }, 400);
}
`;

function addCounters(source) {
  const edits = [
    [
      "createSnapshot",
      SNAPSHOT_ANCHOR,
      SNAPSHOT_ANCHOR.replace(
        "    const snapshot = new ActivatedRouteSnapshot(",
        "    globalThis.__n = (globalThis.__n ?? 0) + 1;\n    __report();\n    const snapshot = new ActivatedRouteSnapshot(",
      ),
    ],
    [
      "findNode",
      FIND_NODE_ANCHOR,
      REPORTER +
        FIND_NODE_ANCHOR.replace(
          "function findNode(value, node) {",
          "function findNode(value, node) {\n  globalThis.__d = (globalThis.__d ?? 0) + 1;\n  if (globalThis.__d % 2000000 === 0) __report();",
        ),
    ],
    [
      "findPath",
      FIND_PATH_ANCHOR,
      FIND_PATH_ANCHOR.replace(
        "function findPath(value, node) {",
        "function findPath(value, node) {\n  globalThis.__d = (globalThis.__d ?? 0) + 1;\n  if (globalThis.__d % 2000000 === 0) __report();",
      ),
    ],
  ];
  let out = source;
  for (const [what, anchor, replacement] of edits) {
    if (out.split(anchor).length - 1 !== 1) {
      throw new Error(`counters: ${what} did not match exactly once.`);
    }
    out = out.replace(anchor, replacement);
  }
  return out;
}

function applyOne(source, what, anchor, replacement) {
  if (source.split(anchor).length - 1 !== 1) {
    throw new Error(`${what} did not match exactly once.`);
  }
  return source.replace(anchor, replacement);
}

const MODES = {
  count: (s) => addCounters(s),

  // The one-line fix on its own, so its effect can be read apart from the
  // memoisation's.
  ungate: (s) =>
    applyOne(
      s,
      "the ngDevMode gate",
      GATE_ANCHOR,
      GATE_ANCHOR.replace(
        "    if (typeof ngDevMode === 'undefined' || ngDevMode) {\n      checkOutletNameUniqueness(mergedChildren);\n    }",
        "    /* __ungatedOutletCheck */\n    checkOutletNameUniqueness(mergedChildren);",
      ),
    ),

  // angular/angular#70933: create and freeze the query map once per recognition
  // and share it, instead of copying it into every snapshot. Keyed on the
  // urlTree identity so an absolute redirect that replaces the tree gets a new
  // map. Both copy sites, same transformation.
  // angular/angular#70933 in full: one frozen query map shared by every
  // snapshot, the parent's params reused when the route adds none, both
  // getInherited branches freezing what they build, and the double freeze in
  // createSnapshot() removed.

};

const mode = process.argv[2] ?? "none";
if (mode === "none") process.exit(0);
if (!(mode in MODES)) {
  throw new Error(
    `Unsupported ROUTER_PATCH=${mode}. Expected none or one of ${Object.keys(MODES).join(", ")}.`,
  );
}

const source = readFileSync(FILE, "utf8");
writeFileSync(FILE, MODES[mode](source));
console.log(`applied ROUTER_PATCH=${mode}`);
