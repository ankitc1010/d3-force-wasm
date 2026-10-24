// Shared memories whose maximum is at or above `limit` pages fail to
// construct: the pool falls back to a smaller maximum, or stays off.
const limit = +process.argv[2];
const Memory = WebAssembly.Memory;
WebAssembly.Memory = function(descriptor) {
  if (descriptor && descriptor.shared && descriptor.maximum >= limit) throw new RangeError("reservation failed");
  return new Memory(descriptor);
};
WebAssembly.Memory.prototype = Memory.prototype;
const {testing} = await import("../../../src/core.js");
const {pair, same, report} = await import("./common.mjs");
await testing.request();
const [a, b] = pair();
let diff = null;
for (let t = 1; t <= 10 && !diff; ++t) a.sim.tick(), b.sim.tick(), diff = same(a, b);
report({diff, status: testing.pool.status(), threads: b.sim.threads()});
