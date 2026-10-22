// Records d3-quadtree reference traces for the O(n) tree build (TRD, Testing:
// "Tree reference traces"). For each fixed point set it stores the extent after
// cover, the tree shape with leaf-chain orders, and the exact callback order of
// visit and visitAfter. Floats are stored as their 64-bit patterns so -0, NaN,
// Infinity and the last ulp survive JSON.
//
//   node scripts/tree-traces.js            writes test/fixtures/tree-traces.json

import {quadtree} from "d3-quadtree";
import {writeFileSync, mkdirSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {dirname, join} from "node:path";

const f64 = new Float64Array(1), u64 = new BigUint64Array(f64.buffer);
export const bits = (v) => (f64[0] = v, u64[0].toString(16).padStart(16, "0"));
export const unbits = (s) => (u64[0] = BigInt("0x" + s), f64[0]);

function lcg(seed) {
  let s = seed >>> 0;
  return () => (s = (1664525 * s + 1013904223) >>> 0) / 4294967296;
}

// Point sets as {x: number[], y: number[]}, chosen to exercise each rule the
// build must reproduce.
export function pointSets() {
  const sets = {};
  const gen = (name, n, f) => {
    const x = new Array(n), y = new Array(n);
    for (let i = 0; i < n; ++i) [x[i], y[i]] = f(i);
    sets[name] = {x, y};
  };
  let r = lcg(1);
  gen("random-1000", 1000, () => [(r() - 0.5) * 2000, (r() - 0.5) * 2000]);
  r = lcg(2);
  gen("random-small-10", 10, () => [r() * 10, r() * 10]);
  gen("grid-32", 1024, (i) => [i % 32, Math.floor(i / 32)]);
  gen("grid-half-offsets", 256, (i) => [(i % 16) * 0.5 - 4, Math.floor(i / 16) * 0.5 - 4]);
  gen("all-coincident", 50, () => [0, 0]);
  gen("signed-zero", 6, (i) => [i % 2 ? -0 : 0, i < 3 ? 0 : -0]);
  gen("coincident-groups", 120, (i) => [(i % 7) * 3, (i % 5) * 3]);
  gen("single", 1, () => [3.25, -7.5]);
  gen("two", 2, (i) => [i, i]);
  sets.empty = {x: [], y: []};
  gen("with-nan", 40, (i) => [i % 5 === 0 ? NaN : i, i % 7 === 0 ? NaN : -i]);
  gen("all-nan", 5, () => [NaN, NaN]);
  r = lcg(3);
  gen("huge-1e300", 200, () => [(r() - 0.5) * 2e300, (r() - 0.5) * 2e300]);
  r = lcg(4);
  gen("near-1e300-offset", 64, () => [1e300 + r() * 1e290, 1e300 + r() * 1e290]);
  r = lcg(5);
  gen("tiny-1e-300", 100, () => [r() * 1e-300, r() * 1e-300]);
  r = lcg(6);
  gen("huge-ints", 100, () => [Math.floor(r() * 2 ** 52), Math.floor(r() * 2 ** 52)]);
  // Distinct points closer than 2^-32 of a 1024-wide extent: needs the
  // incremental-split fallback below 32 Morton levels.
  gen("near-duplicates", 40, (i) => i < 4
    ? [i * 256, i * 256]
    : [0.5 + (i % 6) * 1e-12, 0.25 + Math.floor(i / 6) * 3e-13]);
  gen("near-duplicates-mixed", 30, (i) => i % 3 === 0
    ? [100 + i * 1e-11, 100 + i * 1e-11]
    : i % 3 === 1 ? [100, 100] : [-50 + i, 70 - i]);
  r = lcg(7);
  gen("clustered", 600, (i) => {
    const c = i % 3, s = c === 0 ? 1e-3 : c === 1 ? 1 : 1e3;
    return [c * 1e4 + (r() - 0.5) * s, -c * 1e4 + (r() - 0.5) * s];
  });
  r = lcg(8);
  gen("random-100000", 100000, () => [(r() - 0.5) * 1e4, (r() - 0.5) * 1e4]);
  return sets;
}

// Shape: internal node = [c0, c1, c2, c3] with null for an empty quadrant;
// leaf = {l: [data indices in chain order]}.
function shape(node) {
  if (!node) return null;
  if (node.length) return [0, 1, 2, 3].map((i) => shape(node[i]));
  const l = [];
  do l.push(node.data); while ((node = node.next));
  return {l};
}

// One callback record: leaf head index (or -1 for an internal node) plus the
// cell bounds exactly as d3 passes them.
function rec(node, x0, y0, x1, y1) {
  return [node.length ? -1 : node.data, bits(x0), bits(y0), bits(x1), bits(y1)];
}

export function trace({x, y}) {
  const t = quadtree().x((i) => x[i]).y((i) => y[i]).addAll(x.map((_, i) => i));
  const visit = [], after = [];
  t.visit((node, x0, y0, x1, y1) => void visit.push(rec(node, x0, y0, x1, y1)));
  t.visitAfter((node, x0, y0, x1, y1) => void after.push(rec(node, x0, y0, x1, y1)));
  return {
    x: x.map(bits),
    y: y.map(bits),
    extent: [t._x0, t._y0, t._x1, t._y1].map(bits),
    shape: shape(t.root()),
    visit,
    after,
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const out = {};
  for (const [name, set] of Object.entries(pointSets())) {
    if (set.x.length > 10000) continue; // large sets are compared live, not stored
    out[name] = trace(set);
  }
  const file = join(dirname(fileURLToPath(import.meta.url)), "../test/fixtures/tree-traces.json");
  mkdirSync(dirname(file), {recursive: true});
  writeFileSync(file, JSON.stringify(out));
  console.log(`${Object.keys(out).length} traces -> ${file}`);
}
