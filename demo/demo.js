// Side-by-side demo: d3-force and d3-force-wasm tick the same seeded graph
// once per frame. Exact mode is bit-exact, so after every tick the two node
// arrays are compared with Object.is and any divergence is reported.

import * as d3 from "d3-force";
import * as wasm from "../src/index.js";

const $ = (id) => document.getElementById(id);

// Seeded data so both libraries get identical inputs.
function generator(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function graph(n) {
  const r = generator(42), links = [];
  for (let i = 1; i < n; ++i) links.push({source: i, target: Math.floor(r() * i)});
  for (let i = n; i < 2 * n; ++i) links.push({source: Math.floor(r() * n), target: Math.floor(r() * n)});
  return {nodes: Array.from({length: n}, () => ({})), links};
}

function build(lib, n, preset) {
  const {nodes, links} = graph(n);
  const sim = lib.forceSimulation(nodes).force("charge", lib.forceManyBody()).stop();
  if (preset !== "charge") sim.force("link", lib.forceLink(links)).force("center", lib.forceCenter());
  if (preset === "collide") sim.force("collide", lib.forceCollide(3));
  return {sim, nodes, links};
}

function identical(a, b) {
  for (let i = 0; i < a.length; ++i) {
    const p = a[i], q = b[i];
    if (!Object.is(p.x, q.x) || !Object.is(p.y, q.y) || !Object.is(p.vx, q.vx) || !Object.is(p.vy, q.vy)) return false;
  }
  return true;
}

// Rolling mean of the last 30 tick times.
class Meter {
  constructor() { this.v = []; }
  add(ms) { this.v.push(ms); if (this.v.length > 30) this.v.shift(); }
  get mean() { return this.v.reduce((a, b) => a + b, 0) / (this.v.length || 1); }
}

function timeTick(sim) {
  const t0 = performance.now();
  sim.tick();
  return performance.now() - t0;
}

// Drawing ----------------------------------------------------------------

function draw(canvas, state, color, drawLinks) {
  const dpr = Math.min(devicePixelRatio || 1, 2);
  const size = Math.round(canvas.clientWidth * dpr);
  if (canvas.width !== size) canvas.width = canvas.height = size;
  const ctx = canvas.getContext("2d");
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, size, size);

  const {nodes, links} = state;
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const d of nodes) {
    if (d.x < x0) x0 = d.x; if (d.x > x1) x1 = d.x;
    if (d.y < y0) y0 = d.y; if (d.y > y1) y1 = d.y;
  }
  const k = 0.92 * size / Math.max(x1 - x0, y1 - y0, 1);
  const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
  ctx.setTransform(k, 0, 0, k, size / 2 - k * cx, size / 2 - k * cy);

  if (drawLinks) {
    ctx.beginPath();
    for (const l of links) ctx.moveTo(l.source.x, l.source.y), ctx.lineTo(l.target.x, l.target.y);
    ctx.strokeStyle = color;
    ctx.globalAlpha = 0.18;
    ctx.lineWidth = 0.6 * dpr / k;
    ctx.stroke();
    ctx.globalAlpha = 1;
  }
  const r = Math.max(1.4 * dpr / k, 0);
  ctx.fillStyle = color;
  ctx.beginPath();
  for (const d of nodes) ctx.rect(d.x - r, d.y - r, 2 * r, 2 * r);
  ctx.fill();
}

// Live view ----------------------------------------------------------------

const colors = () => {
  const s = getComputedStyle(document.documentElement);
  return {js: s.getPropertyValue("--js").trim(), wasm: s.getPropertyValue("--wasm").trim()};
};

let live = null, frame = 0, paused = false;

function start() {
  cancelAnimationFrame(frame);
  const n = +$("n").value, preset = $("forces").value;
  live = {a: build(d3, n, preset), b: build(wasm, n, preset), ma: new Meter(), mb: new Meter(), tick: 0, diverged: 0};
  paused = false;
  $("pause").textContent = "Pause";
  frame = requestAnimationFrame(loop);
}

function loop() {
  const s = live;
  if (s.a.sim.alpha() >= s.a.sim.alphaMin()) {
    // Alternate which library goes first so neither always gets a warm cache.
    if (s.tick & 1) s.mb.add(timeTick(s.b.sim)), s.ma.add(timeTick(s.a.sim));
    else s.ma.add(timeTick(s.a.sim)), s.mb.add(timeTick(s.b.sim));
    ++s.tick;
    if (!s.diverged && !identical(s.a.nodes, s.b.nodes)) s.diverged = s.tick;
  }
  const c = colors(), drawLinks = $("links").checked;
  draw($("js-canvas"), s.a, c.js, drawLinks);
  draw($("wasm-canvas"), s.b, c.wasm, drawLinks);

  $("js-ms").textContent = `${s.ma.mean.toFixed(2)} ms/tick`;
  $("wasm-ms").textContent = `${s.mb.mean.toFixed(2)} ms/tick`;
  $("speedup").textContent = s.mb.mean > 0 ? `${(s.ma.mean / s.mb.mean).toFixed(2)}×` : "–";
  $("tick").textContent = s.tick;
  const parity = $("parity");
  parity.textContent = s.diverged ? `diverged at tick ${s.diverged}` : "bit-identical";
  parity.className = s.diverged ? "bad" : "ok";

  if (s.a.sim.alpha() < s.a.sim.alphaMin()) $("tick").textContent = `${s.tick} (settled)`;
  else if (!paused) frame = requestAnimationFrame(loop);
}

$("restart").onclick = start;
$("n").onchange = start;
$("forces").onchange = start;
$("pause").onclick = () => {
  paused = !paused;
  $("pause").textContent = paused ? "Resume" : "Pause";
  if (!paused) frame = requestAnimationFrame(loop);
};

// Benchmark ----------------------------------------------------------------

const nextFrame = () => new Promise((r) => setTimeout(r, 0));

async function bench() {
  const wasPaused = paused;
  paused = true;
  cancelAnimationFrame(frame);
  $("bench").disabled = true;
  const rows = $("bench-rows");
  rows.innerHTML = "";
  const scenarios = [
    [1000, "default"], [5000, "default"], [10000, "default"], [20000, "default"], [10000, "collide"]
  ];
  for (const [n, preset] of scenarios) {
    const label = `${n.toLocaleString()} nodes, ${preset === "collide" ? "+ collide" : "manyBody + link + center"}`;
    $("bench-status").textContent = `Running ${label}…`;
    await nextFrame();
    const a = build(d3, n, preset), b = build(wasm, n, preset);
    let ta = 0, tb = 0;
    for (let k = 0; k < 300; k += 10) {
      if ((k / 10) & 1) tb += timeTick10(b.sim), ta += timeTick10(a.sim);
      else ta += timeTick10(a.sim), tb += timeTick10(b.sim);
      await nextFrame();
    }
    const same = identical(a.nodes, b.nodes);
    const tr = document.createElement("tr");
    tr.innerHTML = `<td>${label}</td><td>${ta.toFixed(0)} ms</td><td>${tb.toFixed(0)} ms</td>`
      + `<td><b>${(ta / tb).toFixed(2)}×</b></td><td class="${same ? "ok" : "bad"}">${same ? "yes" : "no"}</td>`;
    rows.append(tr);
  }
  $("bench-status").textContent = "Done.";
  $("bench").disabled = false;
  paused = wasPaused;
  if (!paused) frame = requestAnimationFrame(loop);
}

function timeTick10(sim) {
  const t0 = performance.now();
  sim.tick(10);
  return performance.now() - t0;
}

$("bench").onclick = bench;

start();
