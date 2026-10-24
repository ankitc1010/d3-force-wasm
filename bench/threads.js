// Tick time by thread count (TRD 3, Testing: "Benchmarks"): manyBody + link +
// center, m = 2n random links, after warm-up; minimum of interleaved runs.
//
//   node bench/threads.js [n] [mode] [ticks]      mode: exact (default) | fast

import * as d3 from "d3-force";
import * as wasm from "../src/index.js";
import {testing} from "../src/core.js";
import {generator} from "../test/parity/scenarios.js";

const n = +(process.argv[2] || 10000), mode = process.argv[3] || "exact", ticks = +(process.argv[4] || 30);
const COUNTS = (process.env.COUNTS || "0,1,3,7").split(",").map(Number);

function setup(lib, k) {
  const r = generator(7);
  const nodes = Array.from({length: n}, () => ({}));
  const links = Array.from({length: 2 * n}, () => ({source: Math.floor(r() * n), target: Math.floor(r() * n)}));
  const sim = lib.forceSimulation(nodes).force("charge", lib.forceManyBody()).force("link", lib.forceLink(links))
      .force("center", lib.forceCenter()).stop();
  if (lib === wasm) sim.precision(mode), sim.threads(k);
  return sim;
}

function time(sim) {
  const t0 = performance.now();
  for (let t = 0; t < ticks; ++t) sim.tick();
  return (performance.now() - t0) / ticks;
}

// COOL=s idles first: the benchmark phone throttles, so runs start cool.
if (process.env.COOL) await new Promise((resolve) => setTimeout(resolve, 1000 * +process.env.COOL));
await testing.request();
const runs = [{name: "d3-force", sim: setup(d3)}, ...COUNTS.map((k) => ({name: `threads(${k})`, sim: setup(wasm, k)}))];
for (const r of runs) r.sim.tick(5), r.best = Infinity;
for (let round = 0; round < 3; ++round) for (const r of runs) r.best = Math.min(r.best, time(r.sim));
const d3ms = runs[0].best;
console.log(`n = ${n}, ${mode}, ${ticks} ticks × 3 rounds, workers available ${testing.pool.ready()?.k}`);
for (const r of runs) console.log(`${r.name.padEnd(11)} ${r.best.toFixed(2).padStart(8)} ms/tick  ${(d3ms / r.best).toFixed(1).padStart(5)}× d3  ${(runs[1].best / r.best).toFixed(2)}× threads(0)`);
