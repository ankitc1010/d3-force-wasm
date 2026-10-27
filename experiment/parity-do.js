// Bitwise parity of the data-oriented JS port (do-force.js) against
// d3-force 3.0.0, with d3-force-wasm's exact core as a third reference.
// After every tick, x, y, vx and vy of every node are compared with
// Object.is — the same gate this repo applies to its wasm core.
//
//   node experiment/parity-do.js [ticks]

import * as d3 from "d3-force";
import * as wasm from "../src/index.js";
import {testing} from "../src/core.js";
import {generator} from "../test/parity/scenarios.js";
import * as doF from "./do-force.js";

const TICKS = +(process.argv[2] || 300);
const SEEDS = [1, 2, 3, 4, 5];

function randomNodes(n, r, spread = 500) {
  return Array.from({length: n}, () => ({x: (r() - 0.5) * spread, y: (r() - 0.5) * spread}));
}

function randomLinks(n, m, r) {
  const links = [];
  for (let i = 0; i < m; ++i) links.push({source: Math.floor(r() * n), target: Math.floor(r() * n)});
  return links;
}

// Each scenario builds fresh inputs from a seed and wires up the default
// forces (charge, link, center) on the given library.
const scenarios = {
  // The benchmark workload, at a few sizes.
  ...Object.fromEntries([10, 100, 1000].map((n) => [`default-${n}`, {
    make(seed) {
      const r = generator(seed);
      return {nodes: randomNodes(n, r), links: randomLinks(n, 2 * n, r)};
    },
  }])),

  // Every point coincident: leaf chains, and jiggles drawn in manyBody.
  coincident: {
    make(seed) {
      const r = generator(seed);
      const nodes = Array.from({length: 60}, (_, i) => i % 3 ? {x: 0, y: 0} : {x: 0, y: 1});
      return {nodes, links: randomLinks(60, 60, r)};
    },
  },

  // fx/fy pinned nodes exercise the fixed paths of copyIn and integrate.
  fixed: {
    make(seed) {
      const r = generator(seed);
      const nodes = randomNodes(120, r);
      for (let i = 0; i < nodes.length; i += 5) nodes[i].fx = -100 + i, nodes[i].fy = 60 - i;
      for (let i = 0; i < nodes.length; i += 11) nodes[i].fx = 0; // fy free
      return {nodes, links: randomLinks(120, 240, r)};
    },
  },

  // NaN coordinates are skipped by the tree but still traversed for forces.
  nan: {
    make(seed) {
      const r = generator(seed);
      const nodes = randomNodes(100, r);
      for (let i = 0; i < nodes.length; i += 7) nodes[i].x = NaN;
      for (let i = 3; i < nodes.length; i += 9) nodes[i].y = NaN;
      return {nodes, links: randomLinks(100, 200, r)};
    },
  },

  // Preferential-attachment links and an empty start (phyllotaxis layout).
  scalefree: {
    make(seed) {
      const r = generator(seed);
      const nodes = Array.from({length: 200}, () => ({}));
      const links = [], ends = [0];
      for (let i = 1; i < 200; ++i) {
        for (let k = r() < 0.3 ? 2 : 1; k > 0; --k) {
          const j = ends[Math.floor(r() * ends.length)];
          links.push({source: i, target: j}), ends.push(i, j);
        }
      }
      return {nodes, links};
    },
  },

  // Coordinates near 1e300: cover doubles its extent to overflow.
  extreme: {
    make(seed) {
      const r = generator(seed);
      const nodes = randomNodes(50, r, 1e300);
      return {nodes, links: randomLinks(50, 100, r)};
    },
  },

  // A dense clump plus far outliers: deep cells and long covers.
  clustered: {
    make(seed) {
      const r = generator(seed);
      const nodes = randomNodes(150, r, 1);
      for (let i = 0; i < 10; ++i) nodes.push({x: (r() - 0.5) * 1e6, y: (r() - 0.5) * 1e6});
      return {nodes, links: randomLinks(160, 320, r)};
    },
  },
};

function setup(lib, {nodes, links}) {
  return lib.forceSimulation(nodes)
      .force("charge", lib.forceManyBody())
      .force("link", lib.forceLink(links))
      .force("center", lib.forceCenter())
      .stop();
}

function firstMismatch(a, b) {
  for (let i = 0; i < a.length; ++i) {
    const na = a[i], nb = b[i];
    if (!Object.is(na.x, nb.x)) return {i, field: "x", a: na.x, b: nb.x};
    if (!Object.is(na.y, nb.y)) return {i, field: "y", a: na.y, b: nb.y};
    if (!Object.is(na.vx, nb.vx)) return {i, field: "vx", a: na.vx, b: nb.vx};
    if (!Object.is(na.vy, nb.vy)) return {i, field: "vy", a: na.vy, b: nb.vy};
  }
  return null;
}

await testing.request();

let failures = 0, checks = 0;
for (const [name, scenario] of Object.entries(scenarios)) {
  for (const seed of SEEDS) {
    const d3sim = setup(d3, scenario.make(seed));
    const doSim = setup(doF, scenario.make(seed));
    const wsim = setup(wasm, scenario.make(seed));
    wsim.precision("exact").threads(0);
    for (let t = 0; t < TICKS; ++t) {
      d3sim.tick();
      doSim.tick();
      wsim.tick();
      ++checks;
      const badDo = firstMismatch(d3sim.nodes(), doSim.nodes());
      const badW = firstMismatch(d3sim.nodes(), wsim.nodes());
      if (badDo || badW) {
        ++failures;
        if (badDo) console.log(`FAIL ${name} seed ${seed} tick ${t}: do ${badDo.field}[${badDo.i}] = ${badDo.a} vs d3 ${badDo.b}`);
        if (badW) console.log(`FAIL ${name} seed ${seed} tick ${t}: wasm ${badW.field}[${badW.i}] = ${badW.a} vs d3 ${badW.b}`);
        break;
      }
    }
  }
  console.log(`${failures ? "✗" : "✓"} ${name}`);
}

console.log(failures ? `\n${failures} of ${checks} tick comparisons diverged` : `\nAll ${checks} tick comparisons bit-identical across do-force, wasm and d3-force.`);
process.exit(failures ? 1 : 0);
