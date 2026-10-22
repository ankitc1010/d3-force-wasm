// M1 gate: exact mode is bitwise equal to d3-force v3.0.0 after every tick
// (TRD, Testing: "Parity corpus"). Positions and velocities are compared with
// Object.is, which tells -0 from 0 and treats NaN as equal to NaN; alpha, the
// links' mutations and the next value of the random source are compared too,
// so one extra or missing jiggle draw fails the run.
//
//   PARITY_SEEDS   seeds per scenario (default 5; the M1 gate runs 50)
//   PARITY_TICKS   ticks per run (default 300)
//   PARITY_ONLY    run only scenarios whose name contains this text

import {test} from "node:test";
import assert from "node:assert/strict";
import * as d3 from "d3-force";
import * as wasm from "../../src/index.js";
import {generator, scenarios} from "./scenarios.js";

const SEEDS = +(process.env.PARITY_SEEDS || 5);
const TICKS = +(process.env.PARITY_TICKS || 300);
const ONLY = process.env.PARITY_ONLY || "";

const FIELDS = ["index", "x", "y", "vx", "vy"];

function firstDifference(a, b) {
  if (a.nodes.length !== b.nodes.length) return `node count ${a.nodes.length} vs ${b.nodes.length}`;
  for (let i = 0; i < a.nodes.length; ++i) {
    for (const f of FIELDS) {
      if (!Object.is(a.nodes[i][f], b.nodes[i][f])) {
        return `node ${i} ${f}: d3 ${a.nodes[i][f]} vs wasm ${b.nodes[i][f]}`;
      }
    }
  }
  if (!Object.is(a.sim.alpha(), b.sim.alpha())) return `alpha ${a.sim.alpha()} vs ${b.sim.alpha()}`;
  return null;
}

function linkState(sim) {
  const link = sim.force("link");
  return link ? link.links().map((l) => [l.index, l.source.index, l.target.index]) : null;
}

for (const [name, scenario] of Object.entries(scenarios)) {
  if (!name.includes(ONLY)) continue;
  test(`parity: ${name} × ${SEEDS} seeds × ${TICKS} ticks`, () => {
    for (let seed = 1; seed <= SEEDS; ++seed) {
      const a = scenario.setup(d3, generator(seed));
      const b = scenario.setup(wasm, generator(seed));
      const step = scenario.ticks || 1;
      let diff = firstDifference(a, b);
      assert.equal(diff, null, `seed ${seed}, after initialize: ${diff}`);
      assert.deepEqual(linkState(b.sim), linkState(a.sim), `seed ${seed}: link mutation`);
      for (let t = 0; t < TICKS; t += step) {
        if (a.before) a.before(t), b.before(t);
        a.sim.tick(step), b.sim.tick(step);
        diff = firstDifference(a, b);
        if (diff) assert.fail(`seed ${seed}, tick ${t + step}: ${diff}`);
      }
      assert.ok(Object.is(a.sim.randomSource()(), b.sim.randomSource()()), `seed ${seed}: random stream position`);
    }
  });
}
