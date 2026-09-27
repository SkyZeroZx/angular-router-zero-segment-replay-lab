// The fix for the zero-segment group replay, applied to the compiled bundle.
//
// The same transformation as zero-segment-replay.patch in the repository root,
// which is the diff against packages/router/src. Independent of
// patch-70933.mjs: neither needs the other, they touch disjoint functions, and
// this is the one that closes the vector.
//
//   node patch-zero-segment.mjs [apply|revert|status]
import { run } from "./patch-shared.mjs";

const EDITS = [
  // 1. The gated call site goes away. It only ever saw the siblings at its own
  // level, which is why ungating it closes the nested replay and nothing else.
  [
    "gated call site in processChildren",
    `    const mergedChildren = mergeEmptyPathMatches(children);
    if (typeof ngDevMode === 'undefined' || ngDevMode) {
      checkOutletNameUniqueness(mergedChildren);
    }
    sortActivatedRouteSnapshots(mergedChildren);`,
    `    const mergedChildren = mergeEmptyPathMatches(children);
    sortActivatedRouteSnapshots(mergedChildren);`,
  ],
  // 2. The check moves onto every list mergeEmptyPathMatches returns. That
  // function recurses into the children it merges, so the duplicates the merge
  // itself creates - one level below where the old call site ran - are now
  // validated too. This is what closes the flat variant.
  [
    "check inside mergeEmptyPathMatches",
    `  return result.filter(n => !mergedNodes.has(n));
}`,
    `  const merged = result.filter(n => !mergedNodes.has(n));
  checkOutletNameUniqueness(merged);
  return merged;
}`,
  ],
  // 3. An outlet may be named after an Object.prototype member. With a plain
  // object literal, a single outlet called constructor, toString, valueOf or
  // __proto__ reads back an inherited value and is rejected as a duplicate of
  // itself. Latent today because the check does not run in production; a
  // prerequisite once it does.
  [
    "null-prototype name map",
    `function checkOutletNameUniqueness(nodes) {
  const names = {};`,
    `function checkOutletNameUniqueness(nodes) {
  const names = Object.create(null);`,
  ],
];

run("zero-segment", EDITS, process.argv);
