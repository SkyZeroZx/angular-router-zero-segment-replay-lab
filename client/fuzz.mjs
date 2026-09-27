// Payload search. Deterministic and offline: it only builds URLs and counts what
// recognition would do with them, using the two laws the `counts` arm measured:
//
//   nodes      = 2 * groups * matched_per_group * fan_out + 2
//   tree steps ~ 2.5 * (nodes / 2)^2
//
// The attacker controls `groups`, and which of `prim` and `noSep` the grammar
// uses. The application controls `outlet` (its own outlet name, paid once per
// group in the URL), `fanOut` (what the panel contains) and whether a primary
// child route exists at all for `prim` to match.
//
//   node client/fuzz.mjs            the whole grid
//   node client/fuzz.mjs 16000      one budget
import { buildTarget, groupCount } from "./workloads.mjs";

const BUDGETS = process.argv[2] ? [Number(process.argv[2])] : [7900, 15900];

// The outlet names a real application might have, since its spelling is repeated
// in every group and the attacker cannot choose it.
const OUTLETS = ["a", "aux", "detail", "sidePanel"];

function best({ budget, outlet, prim, noSep }) {
  let top = null;
  for (let branches = 2; branches <= 80; branches++) {
    for (let depth = 1; depth <= 14; depth++) {
      const groups = groupCount(branches, depth);
      if (groups > 6000) continue;
      const bytes = Buffer.byteLength(
        buildTarget({ shape: "x", branches, depth, prim, outlet, noSep }),
      );
      if (bytes > budget) continue;
      if (!top || groups > top.groups || (groups === top.groups && bytes < top.bytes)) {
        top = { branches, depth, groups, bytes };
      }
    }
  }
  return top;
}

const nodes = (groups, matched, fanOut) => 2 * groups * matched * fanOut + 2;
const steps = (n) => 2.5 * (n / 2) ** 2;
const fmt = (n) => n.toLocaleString("en-US");

for (const budget of BUDGETS) {
  console.log(`\n=== budget ${fmt(budget)} bytes ===\n`);

  // 1. What the grammar itself is worth, at a fixed fan-out.
  console.log("grammar, against an application whose outlet is 'detail', fan-out 13:\n");
  console.log(
    ["prim", "noSep", "b", "d", "groups", "bytes", "B/group", "nodes", "nodes/B", "rel"]
      .map((h, i) => h.padStart([5, 6, 3, 3, 7, 7, 8, 9, 8, 6][i]))
      .join(" "),
  );
  let base = null;
  for (const prim of [false, true]) {
    for (const noSep of [false, true]) {
      const t = best({ budget, outlet: "detail", prim, noSep });
      if (!t) continue;
      const n = nodes(t.groups, prim ? 2 : 1, 13);
      base ??= n;
      console.log(
        [
          String(prim),
          String(noSep),
          t.branches,
          t.depth,
          fmt(t.groups),
          fmt(t.bytes),
          (t.bytes / t.groups).toFixed(1),
          fmt(n),
          (n / t.bytes).toFixed(3),
          (n / base).toFixed(2) + "x",
        ]
          .map((v, i) => String(v).padStart([5, 6, 3, 3, 7, 7, 8, 9, 8, 6][i]))
          .join(" "),
      );
    }
  }

  // 2. What the application's own outlet name costs the attacker, at the best
  //    grammar. The attacker cannot change this one.
  console.log("\nthe application's outlet name, at prim + noSep:\n");
  console.log(
    ["outlet", "b", "d", "groups", "bytes", "B/group", "nodes", "rel"]
      .map((h, i) => h.padStart([10, 3, 3, 7, 7, 8, 9, 6][i]))
      .join(" "),
  );
  let obase = null;
  for (const outlet of OUTLETS) {
    const t = best({ budget, outlet, prim: true, noSep: true });
    if (!t) continue;
    const n = nodes(t.groups, 2, 13);
    obase ??= n;
    console.log(
      [outlet, t.branches, t.depth, fmt(t.groups), fmt(t.bytes),
       (t.bytes / t.groups).toFixed(1), fmt(n), (n / obase).toFixed(2) + "x"]
        .map((v, i) => String(v).padStart([10, 3, 3, 7, 7, 8, 9, 6][i]))
        .join(" "),
    );
  }

  // 3. What the application's fan-out is worth, which is the multiplier that
  //    costs the attacker nothing at all.
  console.log("\nthe application's fan-out, at prim + noSep, outlet 'detail':\n");
  console.log(
    ["shape", "fan-out", "nodes", "tree steps", "rel steps"]
      .map((h, i) => h.padStart([10, 8, 10, 16, 11][i]))
      .join(" "),
  );
  const t = best({ budget, outlet: "detail", prim: true, noSep: true });
  let sbase = null;
  for (const [shape, fanOut] of [["dashboard", 1], ["nested", 2], ["nested2", 4], ["nested3", 13]]) {
    const n = nodes(t.groups, 2, fanOut);
    const st = steps(n);
    sbase ??= st;
    console.log(
      [shape, fanOut, fmt(n), fmt(Math.round(st)), (st / sbase).toFixed(1) + "x"]
        .map((v, i) => String(v).padStart([10, 8, 10, 16, 11][i]))
        .join(" "),
    );
  }
}

console.log(
  "\nnodes and tree steps are derived from the laws the `counts` arm measured,",
);
console.log("not measured here. ./scripts/validate.sh fuzz measures a row end to end.\n");
