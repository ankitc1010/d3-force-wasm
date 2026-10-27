// Tick time and GC pressure: d3-force vs the data-oriented JS port vs
// d3-force-wasm's exact core, one thread, the repo's headline workload
// (manyBody + link + center, m = 2n random links, warm-up, minimum of
// interleaved rounds).
//
//   node experiment/bench-do.js [n] [ticks]     COUNTS=a,b,c to override sizes
//   RUN_ONLY=d3|do|wasm isolates one implementation in its own process, so
//   the GC pauses counted are its own and not another library's garbage
//   collected late.
//
// GC pauses are watched with a PerformanceObserver and attributed to the
// window they start in.

import {PerformanceObserver} from "node:perf_hooks";

const only = process.env.RUN_ONLY || null;
const libs = {};
let testing = null;
if (!only || only === "d3") {
  const d3 = await import("d3-force");
  libs["d3-force"] = d3;
}
if (!only || only === "do") {
  const doF = await import("./do-force.js");
  libs["do (js)"] = doF;
}
if (!only || only === "wasm") {
  const wasm = await import("../src/index.js");
  libs["wasm"] = wasm;
  ({testing} = await import("../src/core.js"));
}
const {generator} = await import("../test/parity/scenarios.js");

const COUNTS = (process.env.COUNTS || "1000,10000,50000").split(",").map(Number);
const ticks = +(process.argv[3] || 30);

// Collect {startTime, duration} of every GC pause.
const pauses = [];
new PerformanceObserver((list) => {
  for (const e of list.getEntries()) pauses.push({start: e.startTime, ms: e.duration});
}).observe({entryTypes: ["gc"]});

function setup(lib, n, seed) {
  const r = generator(seed);
  const nodes = Array.from({length: n}, () => ({}));
  const links = Array.from({length: 2 * n}, () => ({source: Math.floor(r() * n), target: Math.floor(r() * n)}));
  const sim = lib.forceSimulation(nodes).force("charge", lib.forceManyBody()).force("link", lib.forceLink(links))
      .force("center", lib.forceCenter()).stop();
  if (testing && lib === libs.wasm) sim.threads(0);
  return sim;
}

function timed(sim) {
  const from = performance.now();
  for (let t = 0; t < ticks; ++t) sim.tick();
  const to = performance.now();
  // GC entries are delivered on a later tick; flush them, then attribute by
  // the time the pause started.
  return new Promise((resolve) => setImmediate(() => setImmediate(() => {
    let gc = 0, count = 0;
    for (const p of pauses) {
      if (p.start >= from && p.start < to) gc += p.ms, ++count;
    }
    resolve({ms: (to - from) / ticks, gc, count});
  })));
}

// COOL=s idles first, as bench/threads.js does.
if (process.env.COOL) await new Promise((resolve) => setTimeout(resolve, 1000 * +process.env.COOL));
if (testing) await testing.request();

console.log(`manyBody + link + center, m = 2n, ${ticks} ticks × 3 rounds, minimum; Node ${process.version}`);
console.log(`${"n".padStart(8)}  ${"implementation".padEnd(14)} ${"ms/tick".padStart(9)} ${"vs d3".padStart(7)} ${"gc ms".padStart(7)} ${"gc pauses".padStart(9)}`);

for (const n of COUNTS) {
  const runs = Object.entries(libs).map(([name, lib]) => ({
    name,
    sim: setup(lib, n, 7),
    best: Infinity,
    gc: 0,
    count: 0,
  }));
  for (const r of runs) r.sim.tick(5); // warm-up
  pauses.length = 0;
  for (let round = 0; round < 3; ++round) {
    for (const r of runs) {
      const {ms, gc, count} = await timed(r.sim);
      r.gc += gc;
      r.count += count;
      if (ms < r.best) r.best = ms;
    }
  }
  const d3ms = runs[0].best;
  for (const r of runs) {
    console.log(`${String(n).padStart(8)}  ${r.name.padEnd(14)} ${r.best.toFixed(2).padStart(9)} ${(d3ms / r.best).toFixed(2).padStart(6)}× ${r.gc.toFixed(1).padStart(7)} ${String(r.count).padStart(9)}`);
  }
}
