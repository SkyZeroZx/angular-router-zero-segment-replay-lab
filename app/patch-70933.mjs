// angular/angular#70933, "fix(router): do not copy URL-sized objects into every
// route snapshot", applied to the compiled bundle.
//
// The same transformation as 70933.patch in the repository root, which is the
// PR's own diff against packages/router/src. That file is what a maintainer
// applies; this one exists so the lab can build an image in minutes instead of
// compiling Angular from source.
//
// Independent of patch-zero-segment.mjs. It does not close this vector, and the
// measurements say so - it is here to establish that.
//
//   node patch-70933.mjs [apply|revert|status]
import { run } from "./patch-shared.mjs";

// The query map, copied and frozen once per snapshot today. The PR holds one
// per recognition on the Recognizer. Keyed on the source object rather than set
// in the constructor, because urlTree is replaced when an absolute redirect is
// applied, which is the case the PR handles with a second assignment.
const QUERY_BEFORE = `Object.freeze({
      ...this.urlTree.queryParams
    })`;
const QUERY_AFTER = `(this.__sqSource === this.urlTree.queryParams ? this.__sharedQueryParams : (this.__sqSource = this.urlTree.queryParams, this.__sharedQueryParams = Object.freeze({
      ...this.urlTree.queryParams
    })))`;

const EDITS = [
  // Both snapshot construction sites, one in match() and one in createSnapshot().
  [
    "shared query map, root snapshot",
    `const rootSnapshot = new ActivatedRouteSnapshot([], Object.freeze({}), ${QUERY_BEFORE}`,
    `const rootSnapshot = new ActivatedRouteSnapshot([], Object.freeze({}), ${QUERY_AFTER}`,
  ],
  [
    "shared query map, per-route snapshot",
    `const snapshot = new ActivatedRouteSnapshot(segments, parameters, ${QUERY_BEFORE}`,
    `const snapshot = new ActivatedRouteSnapshot(segments, parameters, ${QUERY_AFTER}`,
  ],
  // getInherited: reuse the parent's frozen params when the route adds none of
  // its own, and freeze what it builds so createSnapshot does not have to.
  [
    "getInherited, inheriting branch",
    `    inherited = {
      params: {
        ...parent.params,
        ...route.params
      },
      data: {
        ...parent.data,
        ...route.data
      },`,
    `    inherited = {
      params: Object.keys(route.params).length === 0 ? parent.params : Object.freeze({
        ...parent.params,
        ...route.params
      }),
      data: Object.freeze({
        ...parent.data,
        ...route.data
      }),`,
  ],
  [
    "getInherited, non-inheriting branch",
    `  } else {
    inherited = {
      params: {
        ...route.params
      },
      data: {
        ...route.data
      },`,
    `  } else {
    inherited = {
      params: Object.freeze({
        ...route.params
      }),
      data: Object.freeze({
        ...route.data
      }),`,
  ],
  // With getInherited freezing, createSnapshot stops freezing a second time.
  [
    "createSnapshot double freeze",
    `    snapshot.params = Object.freeze(inherited.params);
    snapshot.data = Object.freeze(inherited.data);`,
    `    snapshot.params = inherited.params;
    snapshot.data = inherited.data;`,
  ],
];

run("70933", EDITS, process.argv);
