// Facade behaviours outside the tick loop, checked against d3-force itself:
// forces used standalone, the timer and events, and the API surface.

import {test} from "node:test";
import assert from "node:assert/strict";
import * as d3 from "d3-force";
import * as wasm from "../src/index.js";

function lcg() {
  let s = 1;
  return () => (s = (1664525 * s + 1013904223) % 4294967296) / 4294967296;
}

function nodes(n) {
  return Array.from({length: n}, (_, i) => ({index: i, x: (i * 37) % 23 - 11, y: (i * 53) % 19 - 9, vx: 0, vy: 0}));
}

function assertSame(a, b, message) {
  for (let i = 0; i < a.length; ++i) {
    for (const f of ["x", "y", "vx", "vy"]) {
      assert.ok(Object.is(a[i][f], b[i][f]), `${message}: node ${i} ${f}: d3 ${a[i][f]} vs wasm ${b[i][f]}`);
    }
  }
}

const standalone = {
  center: (lib) => lib.forceCenter(3, -2),
  collide: (lib) => lib.forceCollide(6),
  link: (lib) => lib.forceLink([{source: 0, target: 1}, {source: 1, target: 2}, {source: 3, target: 3}]),
  manyBody: (lib) => lib.forceManyBody(),
  radial: (lib) => lib.forceRadial(20),
  x: (lib) => lib.forceX(4),
  y: (lib) => lib.forceY(-4),
};

for (const [name, make] of Object.entries(standalone)) {
  test(`standalone ${name}: initialize(nodes, random) then force(alpha) matches d3`, () => {
    const a = nodes(40), b = nodes(40);
    const fa = make(d3), fb = make(wasm);
    fa.initialize(a, lcg()), fb.initialize(b, lcg());
    for (let k = 0; k < 20; ++k) {
      fa(0.5 - k * 0.02), fb(0.5 - k * 0.02);
      assertSame(a, b, `call ${k}`);
    }
  });
}

test("a native force shared by two node arrays follows its latest initialize", () => {
  const a1 = nodes(30), a2 = nodes(12), b1 = nodes(30), b2 = nodes(12);
  const fa = d3.forceManyBody(), fb = wasm.forceManyBody();
  const sa = d3.forceSimulation(a1).force("charge", fa).stop();
  const sb = wasm.forceSimulation(b1).force("charge", fb).stop();
  sa.tick(3), sb.tick(3);
  fa.initialize(a2, lcg()), fb.initialize(b2, lcg());
  sa.tick(3), sb.tick(3);
  assertSame(a1, b1, "simulation nodes");
  assertSame(a2, b2, "re-initialized nodes");
});

// Runs a simulation on the real timer until "end", recording events.
function run(lib) {
  return new Promise((resolve) => {
    const n = nodes(50), events = [];
    const sim = lib.forceSimulation(n)
        .alphaDecay(0.3)
        .force("charge", lib.forceManyBody())
        .force("center", lib.forceCenter())
        .on("tick.a", () => events.push("tick"))
        .on("tick.b", () => events.push("tick.b"))
        .on("end", () => resolve({n, events, sim}));
    sim.on("tick.b", null);
  });
}

test("restart, tick and end events follow d3's timer", async () => {
  const [a, b] = await Promise.all([run(d3), run(wasm)]);
  assert.deepEqual(b.events, a.events);
  assert.ok(a.events.length > 5);
  assertSame(a.n, b.n, "after end");
  assert.ok(Object.is(a.sim.alpha(), b.sim.alpha()));
});

test("stop halts and restart resumes", async () => {
  const sim = wasm.forceSimulation(nodes(5)).force("charge", wasm.forceManyBody());
  let ticks = 0;
  sim.on("tick", () => ++ticks).stop();
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(ticks, 0);
  sim.restart();
  await new Promise((r) => setTimeout(r, 120));
  sim.stop();
  const seen = ticks;
  assert.ok(seen > 0);
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(ticks, seen);
});

test("on() getters, typename lists and d3-dispatch errors", () => {
  const sim = wasm.forceSimulation().stop(), f = () => {};
  assert.equal(sim.on("tick.x", f), sim);
  assert.equal(sim.on("tick.x"), f);
  assert.equal(sim.on("end.x"), undefined);
  sim.on("tick.y end.y", f);
  assert.equal(sim.on("end.y"), f);
  sim.on(".y", null);
  assert.equal(sim.on("tick.y"), undefined);
  assert.equal(sim.on("tick.x"), f);
  assert.throws(() => sim.on("foo", f), /^Error: unknown type: foo$/);
  assert.throws(() => sim.on("tick", 42), /^Error: invalid callback: 42$/);
});

test("exports and accessors mirror d3-force", () => {
  assert.deepEqual(Object.keys(wasm).sort(), Object.keys(d3).sort());
  const a = d3.forceManyBody().theta(0.5).distanceMin(2).distanceMax(9);
  const b = wasm.forceManyBody().theta(0.5).distanceMin(2).distanceMax(9);
  assert.deepEqual([b.theta(), b.distanceMin(), b.distanceMax()], [a.theta(), a.distanceMin(), a.distanceMax()]);
  const sa = d3.forceSimulation().velocityDecay(0.3).stop(), sb = wasm.forceSimulation().velocityDecay(0.3).stop();
  assert.ok(Object.is(sb.velocityDecay(), sa.velocityDecay()));
  assert.ok(Object.is(sb.alphaDecay(), sa.alphaDecay()));
  assert.throws(() => wasm.forceSimulation([{id: "a"}]).force("link", wasm.forceLink([{source: "a", target: "b"}]).id((d) => d.id)),
    /^Error: node not found: b$/);
});
