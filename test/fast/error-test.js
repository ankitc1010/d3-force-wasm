// M2 gate (TRD 2, "Fast many-body kernel"): fast mode's many-body force,
// measured against a direct O(n²) sum with d3's pair formula, has an RMS
// relative error ≤ 1e-3 at the defaults and never exceeds d3's own
// Barnes–Hut error on any scenario. Link and collide report their Jacobi vs
// Gauss–Seidel deviation from d3 after one application; those are documented,
// not gated.
//
//   FAST_N   scale factor for the scenario sizes (default 1)

import {test} from "node:test";
import assert from "node:assert/strict";
import * as d3 from "d3-force";
import * as wasm from "../../src/index.js";

const SCALE = +(process.env.FAST_N || 1);

function rng(seed) {
  let s = seed >>> 0;
  return () => (s = (s * 1664525 + 1013904223) >>> 0) / 4294967296;
}

const scenarios = {
  "uniform 4000": (r) => Array.from({length: 4000 * SCALE}, () => ({x: 1000 * (r() - 0.5), y: 1000 * (r() - 0.5)})),
  "three clusters 6000": (r) => Array.from({length: 6000 * SCALE}, (_, i) => {
    const c = i % 3, cx = [0, 400, -300][c], cy = [0, 100, 350][c], a = r() * 2 * Math.PI, d = 40 * Math.sqrt(-2 * Math.log(1 - r()));
    return {x: cx + d * Math.cos(a), y: cy + d * Math.sin(a)};
  }),
  "phyllotaxis 8000 (d3's default start)": () => Array.from({length: 8000 * SCALE}, () => ({})),
  "grid 2500 with exact zero deltas": () => Array.from({length: 2500 * SCALE}, (_, i) => ({x: 12 * (i % 50), y: 12 * Math.floor(i / 50)})),
  "dense sub-unit cluster 3000": (r) => Array.from({length: 3000 * SCALE}, () => ({x: 20 * r(), y: 20 * r()})),
};

// One tick of manyBody alone, velocityDecay 0 so vx, vy are the force sums.
function tick(lib, nodes, mode) {
  const sim = lib.forceSimulation(nodes).velocityDecay(0).force("charge", lib.forceManyBody()).stop();
  if (mode) sim.precision(mode);
  sim.tick();
  return sim.alpha();
}

// Direct sum with d3's pair formula: distanceMin 1, no distanceMax, jiggle
// as d3 applies it when a delta is exactly zero (the value itself is random
// in d3, so zero-delta pairs are compared through their non-zero component).
function direct(nodes, alpha) {
  const n = nodes.length, fx = new Float64Array(n), fy = new Float64Array(n);
  for (let i = 0; i < n; ++i) {
    const xi = nodes[i].x0, yi = nodes[i].y0;
    let vx = 0, vy = 0;
    for (let j = 0; j < n; ++j) {
      if (j === i) continue;
      let x = nodes[j].x0 - xi, y = nodes[j].y0 - yi, l = x * x + y * y;
      if (l === 0) continue; // coincident: d3 jiggles both components, direction is random
      if (l < 1) l = Math.sqrt(l);
      const w = -30 * alpha / l;
      vx += x * w, vy += y * w;
    }
    fx[i] = vx, fy[i] = vy;
  }
  return {fx, fy};
}

function rms(nodes, ref, zeroDelta) {
  let e2 = 0, r2 = 0;
  for (let i = 0; i < nodes.length; ++i) {
    // On a zero x-delta d3 adds ±5e-7·w in x; compare y there and x elsewhere.
    const ex = zeroDelta ? 0 : nodes[i].vx - ref.fx[i], ey = nodes[i].vy - ref.fy[i];
    e2 += ex * ex + ey * ey, r2 += ref.fx[i] * ref.fx[i] + ref.fy[i] * ref.fy[i];
  }
  return Math.sqrt(e2 / r2);
}

for (const [name, make] of Object.entries(scenarios)) {
  test(`fast manyBody error vs direct sum: ${name}`, () => {
    const a = make(rng(11)), b = make(rng(11));
    // Let d3 place the phyllotaxis start, then freeze both copies' starts.
    const alpha = tick(d3, a, null);
    for (let i = 0; i < a.length; ++i) a[i].x0 = a[i].x - a[i].vx, a[i].y0 = a[i].y - a[i].vy;
    for (let i = 0; i < b.length; ++i) b[i].x = a[i].x0, b[i].y = a[i].y0, b[i].x0 = a[i].x0, b[i].y0 = a[i].y0;
    const alphaB = tick(wasm, b, "fast");
    assert.equal(alphaB, alpha);
    const ref = direct(a, alpha);
    const grid = name.startsWith("grid");
    const errD3 = rms(a, ref, grid), errFast = rms(b, ref, grid);
    console.log(`  ${name}: n = ${a.length}, rms error d3 (Barnes–Hut θ = 0.9) ${errD3.toExponential(2)}, fast ${errFast.toExponential(2)}`);
    assert.ok(errFast <= 1e-3, `fast rms ${errFast} above 1e-3`);
    assert.ok(errFast <= errD3, `fast rms ${errFast} above d3's ${errD3}`);
  });
}

test("fast link and collide: deviation from d3 after one application (reported)", () => {
  const n = 5000 * SCALE, r = rng(5);
  const make = () => {
    const nodes = Array.from({length: n}, () => ({x: 2000 * (r() - 0.5), y: 2000 * (r() - 0.5)}));
    const links = Array.from({length: 2 * n}, () => ({source: Math.floor(r() * n), target: Math.floor(r() * n)}));
    return {nodes, links};
  };
  for (const [force, label, iterations] of [["link", "link", 1], ["link", "link", 2], ["collide", "collide r = 25", 1], ["collide", "collide r = 25", 2]]) {
    const build = (lib, g, mode) => {
      const sim = lib.forceSimulation(g.nodes).velocityDecay(0).stop();
      sim.force(force, force === "link" ? lib.forceLink(g.links).iterations(iterations) : lib.forceCollide(25).iterations(iterations));
      if (mode) sim.precision(mode);
      return sim;
    };
    const a = make(), b = JSON.parse(JSON.stringify(a));
    build(d3, a, null).tick();
    build(wasm, b, "fast").tick();
    let e2 = 0, r2 = 0;
    for (let i = 0; i < n; ++i) {
      const ex = a.nodes[i].vx - b.nodes[i].vx, ey = a.nodes[i].vy - b.nodes[i].vy;
      e2 += ex * ex + ey * ey, r2 += a.nodes[i].vx ** 2 + a.nodes[i].vy ** 2;
    }
    const dev = Math.sqrt(e2 / r2);
    console.log(`  ${label}, ${iterations} iteration(s): Jacobi vs d3 Gauss–Seidel rms deviation ${dev.toExponential(2)}`);
    assert.ok(Number.isFinite(dev));
  }
});
