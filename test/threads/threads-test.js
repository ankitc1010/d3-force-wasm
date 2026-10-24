// M3 gates (TRD 3, Testing). Exact mode is bitwise equal to d3-force at
// threads(0), (1), (3) and (7), on the parity corpus with a test-only
// setting that moves even tiny simulations to the threaded core and splits
// every phase into 16-node chunks, and on large scenarios at the default
// settings. Fast mode reproduces the digests stored from v0.2.0 at the same
// four thread counts.
//
//   THREADS_SEEDS   seeds per parity scenario (default 2)
//   THREADS_TICKS   ticks per large exact scenario (default 60; the gate runs 300)
//   THREADS_ONLY    run only scenarios whose name contains this text

import {test} from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import * as d3 from "d3-force";
import * as wasm from "../../src/index.js";
import {testing} from "../../src/core.js";
import {generator, scenarios as parity} from "../parity/scenarios.js";
import {scenarios as large, CHECKPOINTS} from "./scenarios.js";
import {digest} from "./digest.js";

const SEEDS = +(process.env.THREADS_SEEDS || 2);
const TICKS = +(process.env.THREADS_TICKS || 60);
const ONLY = process.env.THREADS_ONLY || "";
const COUNTS = [0, 1, 3, 7];
const FIELDS = ["index", "x", "y", "vx", "vy"];

await testing.request();
const pool = testing.pool.ready();

function firstDifference(a, b) {
  if (a.nodes.length !== b.nodes.length) return `node count ${a.nodes.length} vs ${b.nodes.length}`;
  for (let i = 0; i < a.nodes.length; ++i) {
    for (const f of FIELDS) {
      if (!Object.is(a.nodes[i][f], b.nodes[i][f])) return `node ${i} ${f}: d3 ${a.nodes[i][f]} vs wasm ${b.nodes[i][f]}`;
    }
  }
  if (!Object.is(a.sim.alpha(), b.sim.alpha())) return `alpha ${a.sim.alpha()} vs ${b.sim.alpha()}`;
  return null;
}

// Small chunks and cuts in both cores, and a threshold of 0, for `body`.
function split(body) {
  testing.threshold(0), testing.tune(0, 16), testing.tune(1, 4);
  try {
    body();
  } finally {
    testing.threshold(2000), testing.tune(0, 0), testing.tune(1, 0);
  }
}

test("the pool starts on Node with hardwareConcurrency − 1 workers", () => {
  assert.ok(pool, `pool ${testing.pool.status()}`);
  assert.ok(pool.k >= 1);
});

for (const [name, scenario] of Object.entries(parity)) {
  if (!name.includes(ONLY)) continue;
  test(`exact, split: ${name} × ${SEEDS} seeds at threads ${COUNTS.join(", ")}`, () => split(() => {
    for (let seed = 1; seed <= SEEDS; ++seed) {
      const a = scenario.setup(d3, generator(seed));
      const runs = COUNTS.map((k) => {
        const b = scenario.setup(wasm, generator(seed));
        b.sim.threads(k);
        return b;
      });
      const step = scenario.ticks || 1;
      for (let t = 0; t < 300; t += step) {
        if (a.before) a.before(t);
        a.sim.tick(step);
        for (const [j, b] of runs.entries()) {
          if (b.before) b.before(t);
          b.sim.tick(step);
          const diff = firstDifference(a, b);
          if (diff) assert.fail(`threads(${COUNTS[j]}), seed ${seed}, tick ${t + step}: ${diff}`);
        }
      }
      const next = a.sim.randomSource()();
      for (const [j, b] of runs.entries()) {
        assert.ok(Object.is(next, b.sim.randomSource()()), `threads(${COUNTS[j]}), seed ${seed}: random stream position`);
      }
    }
  }));
}

for (const [name, scenario] of Object.entries(large)) {
  if (!name.includes(ONLY)) continue;
  test(`exact, default settings: ${name} × ${TICKS} ticks at threads ${COUNTS.join(", ")}`, () => {
    const a = scenario.setup(d3);
    const runs = COUNTS.map((k) => {
      const b = scenario.setup(wasm);
      b.sim.threads(k);
      return b;
    });
    for (let t = 1; t <= TICKS; ++t) {
      a.sim.tick();
      for (const [j, b] of runs.entries()) {
        b.sim.tick();
        const diff = firstDifference(a, b);
        if (diff) assert.fail(`threads(${COUNTS[j]}), tick ${t}: ${diff}`);
        if (COUNTS[j] && t > 1) assert.equal(b.sim.threads(), Math.min(COUNTS[j], pool.k), "workers used");
      }
    }
  });
}

const golden = JSON.parse(readFileSync(new URL("../fixtures/fast-golden.json", import.meta.url), "utf8"));

for (const [name, scenario] of Object.entries(large)) {
  if (!name.includes(ONLY)) continue;
  test(`fast mode matches v0.2.0: ${name} at threads ${COUNTS.join(", ")}`, () => {
    for (const k of COUNTS) {
      const {nodes, sim} = scenario.setup(wasm, "fast");
      sim.threads(k);
      for (let t = 1; t <= CHECKPOINTS.at(-1); ++t) {
        sim.tick();
        if (CHECKPOINTS.includes(t)) assert.equal(digest(nodes), golden[name][t], `threads(${k}), tick ${t}`);
      }
    }
  });
}
