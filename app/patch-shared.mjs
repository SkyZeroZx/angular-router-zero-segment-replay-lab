// Shared by the two patch scripts. Each of them edits the same compiled bundle,
// independently: they touch disjoint functions, so either can be applied,
// reverted or re-applied without disturbing the other.
import { readFileSync, writeFileSync } from "node:fs";

export const FILE = "node_modules/@angular/router/fesm2022/_router-chunk.mjs";

export function read() {
  return readFileSync(FILE, "utf8");
}

// Every edit is a pair, so applying is substituting one way and reverting is
// substituting the other. Nothing is remembered between runs: the file itself
// says which state it is in.
export function swap(source, edits, direction, label) {
  let out = source;
  for (const [name, before, after] of edits) {
    const from = direction === "apply" ? before : after;
    const to = direction === "apply" ? after : before;
    const found = out.split(from).length - 1;
    if (found !== 1) {
      throw new Error(
        `${label}: ${direction} "${name}" expected 1 site, found ${found}. ` +
          `Either the bundle is not @angular/router 22.2.0, or this patch is already ` +
          `in the state you asked for.`,
      );
    }
    out = out.split(from).join(to);
  }
  return out;
}

// True when every "after" side is already present and no "before" side is.
export function isApplied(source, edits) {
  return edits.every(([, before, after]) => source.includes(after) && !source.includes(before));
}

export function run(label, edits, argv) {
  const action = argv[2] ?? "apply";
  if (action !== "apply" && action !== "revert" && action !== "status") {
    throw new Error(`${label}: expected apply, revert or status, got ${action}.`);
  }
  const source = read();
  const applied = isApplied(source, edits);
  if (action === "status") {
    console.log(`${label}: ${applied ? "applied" : "not applied"}`);
    return;
  }
  if (action === "apply" && applied) {
    console.log(`${label}: already applied`);
    return;
  }
  if (action === "revert" && !applied) {
    console.log(`${label}: not applied`);
    return;
  }
  writeFileSync(FILE, swap(source, edits, action, label));
  console.log(`${label}: ${action === "apply" ? "applied" : "reverted"}`);
}
