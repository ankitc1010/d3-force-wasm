// A worker traps inside a phase: the step reruns on the inlined core, the
// tick returns d3's bits without throwing, and later ticks run on one thread.
import {testing} from "../../../src/core.js";
import {pair, same, report} from "./common.mjs";

await testing.request();
const [a, b] = pair();
let retiredAt = 0, diff = null;
for (let t = 1; t <= 60 && !diff; ++t) {
  if (t === 5) testing.tune(3, 2); // worker 2 traps when it next joins a phase
  a.sim.tick(), b.sim.tick();
  diff = same(a, b);
  if (!retiredAt && testing.pool.status() === "retired") retiredAt = t;
}
report({diff, retiredAt, status: testing.pool.status(), threadsAfter: b.sim.threads()});
