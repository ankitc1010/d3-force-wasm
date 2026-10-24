// Records the fast-mode golden corpus (TRD 3, Testing: "Fast golden corpus"):
// a digest of every large scenario at each checkpoint, from whatever core
// src/core-bytes.js holds. It was run once on the v0.2.0 sources; the thread
// tests require every later build, at every thread count, to reproduce it.
//
//   node scripts/fast-golden.js > test/fixtures/fast-golden.json

import * as wasm from "../src/index.js";
import {scenarios, CHECKPOINTS} from "../test/threads/scenarios.js";
import {digest} from "../test/threads/digest.js";

const out = {};
for (const [name, scenario] of Object.entries(scenarios)) {
  const {nodes, sim} = scenario.setup(wasm, "fast");
  sim.threads?.(0);
  out[name] = {};
  for (let t = 1; t <= CHECKPOINTS.at(-1); ++t) {
    sim.tick();
    if (CHECKPOINTS.includes(t)) out[name][t] = digest(nodes);
  }
  console.error(name, "done");
}
console.log(JSON.stringify(out, null, 2));
