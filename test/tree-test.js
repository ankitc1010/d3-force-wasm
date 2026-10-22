// M0 gate: the O(n) tree build matches d3-quadtree's structure and callback
// order exactly. Stored traces come from scripts/tree-traces.js; the 100,000
// point set is traced live against d3-quadtree.

import {test} from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {pointSets, trace, bits, unbits} from "../scripts/tree-traces.js";

const wasm = readFileSync(new URL("../zig-out/bin/core.wasm", import.meta.url));
const core = new WebAssembly.Instance(new WebAssembly.Module(wasm), {env: {random: Math.random}}).exports;
const traces = JSON.parse(readFileSync(new URL("./fixtures/tree-traces.json", import.meta.url)));
const NONE = 0xffffffff;

// Reads the core's tree for points {x, y} into the trace format.
function coreTrace(x, y) {
  const n = x.length;
  const h = core.sim_create();
  assert.ok(h);
  assert.ok(core.sim_set_node_count(h, n) >= 0);
  new Float64Array(core.memory.buffer, core.sim_ptr(h, 0), n).set(x);
  new Float64Array(core.memory.buffer, core.sim_ptr(h, 1), n).set(y);
  assert.ok(core.tree_build(h, 0) >= 0);

  const len = core.tree_info(h, 0), root = core.tree_info(h, 1), size = core.tree_info(h, 5);
  assert.equal(size, 88);
  const out = core.alloc(Math.max(len, 1) * 4);
  const visitOrder = order(h, 0, out, len), afterOrder = order(h, 1, out, len);
  core.free(out, Math.max(len, 1) * 4);

  // Views are made after the last call that may allocate.
  const mem = core.memory.buffer;
  const cells = new DataView(mem, core.tree_info(h, 2), len * size);
  const perm = new Uint32Array(mem, core.tree_info(h, 4), core.tree_info(h, 6));
  const extent = [...new Float64Array(mem, core.tree_info(h, 3), 4)].map(bits);
  const cell = (c) => {
    const o = c * size, d = (k) => cells.getFloat64(o + k, true);
    return {
      child: [0, 1, 2, 3].map((i) => cells.getUint32(o + 4 * i, true)),
      first: cells.getUint32(o + 16, true),
      count: cells.getUint32(o + 20, true),
      bounds: [d(24), d(32), d(40), d(48)].map(bits),
    };
  };
  const chain = (c) => {
    const {first, count} = cell(c), l = [];
    for (let k = first + count - 1; k >= first; --k) l.push(perm[k]);
    return l;
  };
  const isLeaf = (c) => cell(c).child.every((k) => k === NONE);
  const shape = (c) => c === NONE ? null
    : isLeaf(c) ? {l: chain(c)}
    : cell(c).child.map(shape);
  const rec = (c) => [isLeaf(c) ? chain(c)[0] : -1, ...cell(c).bounds];

  const result = {
    extent,
    shape: len ? shape(root) : null,
    visit: visitOrder.map(rec),
    after: afterOrder.map(rec),
  };
  core.sim_destroy(h);
  return result;
}

function order(h, after, out, len) {
  assert.equal(core.tree_order(h, after, out), 0);
  return [...new Uint32Array(core.memory.buffer, out, len)];
}

function compare(name, ref, got) {
  // Extents of an empty tree are NaN in both; compare as values there.
  assert.deepEqual(got.extent, ref.extent, `${name}: extent`);
  assert.deepEqual(got.shape, ref.shape, `${name}: shape and leaf chains`);
  assert.deepEqual(got.visit, ref.visit, `${name}: visit order and bounds`);
  assert.deepEqual(got.after, ref.after, `${name}: visitAfter order and bounds`);
}

for (const [name, ref] of Object.entries(traces)) {
  test(`tree matches d3-quadtree trace: ${name}`, () => {
    compare(name, ref, coreTrace(ref.x.map(unbits), ref.y.map(unbits)));
  });
}

test("tree matches d3-quadtree live: random-100000", () => {
  const set = pointSets()["random-100000"];
  compare("random-100000", trace(set), coreTrace(set.x, set.y));
});

test("tree build reuses memory across rebuilds and node-count changes", () => {
  const h = core.sim_create();
  for (const n of [10, 1000, 50, 5000, 5000]) {
    core.sim_set_node_count(h, n);
    const x = new Float64Array(core.memory.buffer, core.sim_ptr(h, 0), n);
    const y = new Float64Array(core.memory.buffer, core.sim_ptr(h, 1), n);
    for (let i = 0; i < n; ++i) x[i] = Math.sin(i) * 100, y[i] = Math.cos(i * 1.3) * 100;
    assert.ok(core.tree_build(h, 0) >= 0);
    assert.equal(core.tree_info(h, 6), n);
  }
  assert.equal(core.sim_destroy(h), 0);
  assert.equal(core.sim_destroy(h), -1, "destroyed handle is rejected");
  assert.equal(core.tree_build(12345, 0), -1, "unknown handle is rejected");
});
