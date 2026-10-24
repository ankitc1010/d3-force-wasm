// Large scenarios for the thread gates (TRD 3, Testing): the five layouts of
// the fast error corpus with every native force that splits by node, sized
// above the 2,000-node threshold so the threaded core is used at its default
// settings. `setup(lib, mode)` builds a stopped simulation; the data comes from
// a seeded generator, so every library and mode sees identical inputs.

import {generator} from "../parity/scenarios.js";

// Inputs use only correctly rounded arithmetic (+, −, ×, ÷, sqrt): V8's
// Math.cos, sin and log differ in the last bit between x86-64 and arm64, so
// layouts built with them, d3's own phyllotaxis start included, would give
// the golden digests a different input on each architecture.
function disk(r, cx, cy, radius) {
  let x, y;
  do x = 2 * r() - 1, y = 2 * r() - 1; while (x * x + y * y > 1);
  return {x: cx + radius * x, y: cy + radius * y};
}

// d3's phyllotaxis, radius 10 √(0.5 + i), with the golden-angle turn applied
// by a fixed rotation instead of cos and sin of i times the angle.
function spiral(n) {
  const c = -0.7373688780783197, s = 0.6754902942615238; // cos, sin of π (3 − √5)
  const nodes = [];
  for (let i = 0, u = 1, v = 0; i < n; ++i, [u, v] = [u * c - v * s, u * s + v * c]) {
    const radius = 10 * Math.sqrt(0.5 + i);
    nodes.push({x: radius * u, y: radius * v});
  }
  return nodes;
}

const layouts = {
  "uniform 4000": (r) => Array.from({length: 4000}, () => ({x: 1000 * (r() - 0.5), y: 1000 * (r() - 0.5)})),
  "three clusters 6000": (r) => Array.from({length: 6000}, (_, i) => disk(r, [0, 400, -300][i % 3], [0, 100, 350][i % 3], 120)),
  "spiral 8000": () => spiral(8000),
  "grid 2500 with exact zero deltas": () => Array.from({length: 2500}, (_, i) => ({x: 12 * (i % 50), y: 12 * Math.floor(i / 50)})),
  "dense sub-unit cluster 3000": (r) => Array.from({length: 3000}, () => ({x: 20 * r(), y: 20 * r()})),
};

function links(n, r) {
  return Array.from({length: n}, (_, i) => ({source: i, target: Math.floor(r() * n)}));
}

export const scenarios = Object.fromEntries(Object.entries(layouts).map(([name, make]) => [name, {
  setup(lib, mode, seed = 1) {
    const r = generator(seed);
    const nodes = make(r);
    const sim = lib.forceSimulation(nodes)
        .force("charge", lib.forceManyBody())
        .force("link", lib.forceLink(links(nodes.length, r)))
        .force("collide", lib.forceCollide(3))
        .force("center", lib.forceCenter())
        .stop();
    if (mode) sim.precision(mode);
    return {nodes, sim};
  }
}]));

// Ticks after which the golden corpus records a digest.
export const CHECKPOINTS = [1, 10, 100, 300];
