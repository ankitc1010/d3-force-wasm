// Large scenarios for the thread gates (TRD 3, Testing): the five layouts of
// the fast error corpus with every native force that splits by node, sized
// above the 2,000-node threshold so the threaded core is used at its default
// settings. `setup(lib, mode)` builds a stopped simulation; the data comes from
// a seeded generator, so every library and mode sees identical inputs.

import {generator} from "../parity/scenarios.js";

const layouts = {
  "uniform 4000": (r) => Array.from({length: 4000}, () => ({x: 1000 * (r() - 0.5), y: 1000 * (r() - 0.5)})),
  "three clusters 6000": (r) => Array.from({length: 6000}, (_, i) => {
    const c = i % 3, cx = [0, 400, -300][c], cy = [0, 100, 350][c], a = r() * 2 * Math.PI, d = 40 * Math.sqrt(-2 * Math.log(1 - r()));
    return {x: cx + d * Math.cos(a), y: cy + d * Math.sin(a)};
  }),
  "phyllotaxis 8000": () => Array.from({length: 8000}, () => ({})),
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
