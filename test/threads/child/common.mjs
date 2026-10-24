// Shared by the failover children: a d3-force and a d3-force-wasm simulation
// of the same 3,000-node graph, compared bit for bit after every tick.

import * as d3 from "d3-force";
import * as wasm from "../../../src/index.js";
import {generator} from "../../parity/scenarios.js";

export {wasm};

export function pair(n = 3000) {
  const make = (lib) => {
    const r = generator(3);
    const nodes = Array.from({length: n}, () => ({}));
    const links = Array.from({length: n}, (_, i) => ({source: i, target: Math.floor(r() * n)}));
    const sim = lib.forceSimulation(nodes).force("charge", lib.forceManyBody()).force("link", lib.forceLink(links))
        .force("collide", lib.forceCollide(2)).force("center", lib.forceCenter()).stop();
    return {nodes, sim};
  };
  return [make(d3), make(wasm)];
}

export function same(a, b) {
  for (let i = 0; i < a.nodes.length; ++i) {
    for (const f of ["x", "y", "vx", "vy"]) {
      if (!Object.is(a.nodes[i][f], b.nodes[i][f])) return `node ${i} ${f}: ${a.nodes[i][f]} vs ${b.nodes[i][f]}`;
    }
  }
  return null;
}

export function report(result) {
  console.log(JSON.stringify(result));
}
