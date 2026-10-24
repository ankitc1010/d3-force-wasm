// A worker is terminated without an exception, possibly mid-phase: either it
// never joins again and the pool runs on, or the 2 s no-progress timeout
// fails the step over to the inlined core. Never a hang, never a wrong bit.
import {testing} from "../../../src/core.js";
import {pair, same, report} from "./common.mjs";

await testing.request();
testing.tune(2, 200); // timeout in ms, so the test is quick
const [a, b] = pair(20000);
let diff = null, worst = 0;
for (let t = 1; t <= 12 && !diff; ++t) {
  if (t === 3) testing.pool.ready().workers[1].terminate();
  const t0 = performance.now();
  a.sim.tick(), b.sim.tick();
  worst = Math.max(worst, performance.now() - t0);
  diff = same(a, b);
}
report({diff, status: testing.pool.status(), worstTickMs: Math.round(worst)});
