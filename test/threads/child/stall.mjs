// A worker stops making progress inside a phase it joined: after the
// no-progress timeout the step fails over to the inlined core, with d3's bits.
import {testing} from "../../../src/core.js";
import {pair, same, report} from "./common.mjs";

await testing.request();
testing.tune(2, 200); // timeout in ms, so the test is quick
const [a, b] = pair();
let diff = null, worst = 0, retiredAt = 0;
for (let t = 1; t <= 30 && !diff; ++t) {
  if (t === 3) testing.tune(5, 1);
  const t0 = performance.now();
  a.sim.tick(), b.sim.tick();
  worst = Math.max(worst, performance.now() - t0);
  diff = same(a, b);
  if (!retiredAt && testing.pool.status() === "retired") retiredAt = t;
}
report({diff, retiredAt, status: testing.pool.status(), worstTickMs: Math.round(worst)});
