// A simulation left to its timer: the pool starts, the timer runs until
// alpha falls below alphaMin, and then the process exits by itself.
import {wasm} from "./common.mjs";

const nodes = Array.from({length: 3000}, () => ({}));
let used = 0;
const sim = wasm.forceSimulation(nodes).force("charge", wasm.forceManyBody()).alphaDecay(0.05)
    .on("tick", () => { used = Math.max(used, sim.threads()); })
    .on("end", () => console.log(JSON.stringify({ended: true, used})));
