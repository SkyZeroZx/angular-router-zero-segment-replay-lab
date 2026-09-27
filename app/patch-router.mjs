// Proof-only edits to @angular/router, applied at image build time by the
// ROUTER_PATCH build arg. "none" leaves the package stock, which is what every
// headline number in the README uses.
//
//   count        report what recognition built and what the tree walk cost:
//                nodes created, and steps taken by findNode()/findPath()
//   ungate       run checkOutletNameUniqueness() in production too. One line.
//   memo         index the snapshot tree by identity instead of searching it
//                from the root on every getter access
//   share-query  create and freeze the query map once per recognition and share
//                it, the transformation from angular/angular#70933
//   ungate       call checkOutletNameUniqueness() in production too

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

const PR_INHERITED_ANCHOR = `    inherited = {
      params: {
        ...parent.params,
        ...route.params
      },
      data: {
        ...parent.data,
        ...route.data
      },`;

// The same two hunks the PR applies there: reuse the parent's frozen params
// when the route contributes none of its own, and freeze what is built.
const PR_INHERITED_FIXED = `    inherited = {
      params: Object.keys(route.params).length === 0 ? parent.params : Object.freeze({
        ...parent.params,
        ...route.params
      }),
      data: Object.freeze({
        ...parent.data,
        ...route.data
      }),`;

// createSnapshot() freezes the inherited maps today; the PR moves that into
// getInherited() and stops doing it twice.
const PR_SNAPSHOT_ANCHOR = `    snapshot.params = Object.freeze(inherited.params);
    snapshot.data = Object.freeze(inherited.data);`;
const PR_SNAPSHOT_FIXED = `    snapshot.params = inherited.params;
    snapshot.data = inherited.data;`;

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
  // angular/angular#70933 in full, as three edits: one frozen query map shared
  // by every snapshot, the parent's params reused when the route adds none, and
  // the double freeze in createSnapshot() removed. An earlier revision applied
  // only the first and understated what the PR does.
  "share-query": (s) => {
    const q = "Object.freeze({\n      ...this.urlTree.queryParams\n    })";
    if (s.split(q).length - 1 !== 2) {
      throw new Error("share-query: expected exactly 2 query copy sites.");
    }
    let out = s.split(q).join(
      "(this.__sqSource === this.urlTree.queryParams ? this.__sharedQueryParams : (this.__sqSource = this.urlTree.queryParams, this.__sharedQueryParams = Object.freeze({\n      ...this.urlTree.queryParams\n    })))",
    );
    out = applyOne(out, "getInherited", PR_INHERITED_ANCHOR, PR_INHERITED_FIXED);
    out = applyOne(out, "the double freeze in createSnapshot", PR_SNAPSHOT_ANCHOR, PR_SNAPSHOT_FIXED);
    return out;
  },

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
