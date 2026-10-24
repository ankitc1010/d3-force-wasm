// A healthy phase longer than the timeout is not a failure: the timeout
// counts time without progress, not phase length.
import {testing} from "../../../src/core.js";
import {wasm, report} from "./common.mjs";

await testing.request();
testing.tune(2, 30); // 30 ms timeout
const nodes = Array.from({length: 100000}, () => ({}));
const sim = wasm.forceSimulation(nodes).force("charge", wasm.forceManyBody()).stop();
sim.threads(1);
const t0 = performance.now();
sim.tick(2);
report({status: testing.pool.status(), threads: sim.threads(), tickMs: Math.round((performance.now() - t0) / 2)});
