// Side-by-side demo: d3-force and d3-force-wasm tick the same seeded graph
// once per frame. Exact mode is bit-exact, so after every tick the two node
// arrays are compared with Object.is and any divergence is reported. Fast
// mode (O(n) fast multipole many-body) is approximate by design, so the
// readout there is the RMS position deviation as a share of the extent.

import * as d3 from "d3-force";
import * as wasm from "d3-force-wasm";

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

function build(lib, n, preset, mode) {
  const {nodes, links} = graph(n);
  const sim = lib.forceSimulation(nodes).force("charge", lib.forceManyBody()).stop();
  if (preset !== "charge") sim.force("link", lib.forceLink(links)).force("center", lib.forceCenter());
  if (preset === "collide") sim.force("collide", lib.forceCollide(3));
  if (mode === "fast" && sim.precision) sim.precision("fast");
  // Threads (0.3+): "auto" uses every core where the page is isolated.
  if (sim.threads) sim.threads($("threads").value === "auto" ? null : 0);
  return {sim, nodes, links};
}

// Workers the wasm side's last tick used, and why it is 0 when it is.
function workers(sim) {
  if (!sim.threads) return "– (this version has no threads)";
  const k = sim.threads();
  if (k) return `${k} + main thread`;
  if (!globalThis.crossOriginIsolated) return "0 (page not cross-origin isolated)";
  if ($("threads").value === "0") return "0 (one thread selected)";
  return +$("n").value < 2000 ? "0 (below 2,000 nodes)" : "0 (starting…)";
}

// RMS distance between the two layouts, relative to the reference's extent.
function deviation(a, b) {
  let d2 = 0, x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (let i = 0; i < a.length; ++i) {
    const p = a[i], q = b[i], dx = p.x - q.x, dy = p.y - q.y;
    d2 += dx * dx + dy * dy;
    if (p.x < x0) x0 = p.x; if (p.x > x1) x1 = p.x;
    if (p.y < y0) y0 = p.y; if (p.y > y1) y1 = p.y;
  }
  return Math.sqrt(d2 / a.length) / Math.max(x1 - x0, y1 - y0, 1e-12);
}

const pct = (v) => v < 1e-4 ? `${(v * 100).toExponential(1)}%` : `${(v * 100).toFixed(2)}%`;

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
  const n = +$("n").value, preset = $("forces").value, mode = $("mode").value;
  $("wasm-mode").textContent = mode;
  live = {a: build(d3, n, preset), b: build(wasm, n, preset, mode), mode, ma: new Meter(), mb: new Meter(), tick: 0, diverged: 0, dev: 0};
  paused = false;
  $("pause").textContent = "Pause";
  frame = requestAnimationFrame(loop);
}

// A side switched off is neither ticked nor drawn, so the other side gets
// the whole frame; the comparison numbers need both sides running.
function loop() {
  const s = live, jsOn = $("js-on").checked, wasmOn = $("wasm-on").checked;
  const lead = jsOn ? s.a.sim : wasmOn ? s.b.sim : null;
  const running = lead && lead.alpha() >= lead.alphaMin();
  if (running) {
    // Alternate which library goes first so neither always gets a warm cache.
    if (s.tick & 1) {
      if (wasmOn) s.mb.add(timeTick(s.b.sim));
      if (jsOn) s.ma.add(timeTick(s.a.sim));
    } else {
      if (jsOn) s.ma.add(timeTick(s.a.sim));
      if (wasmOn) s.mb.add(timeTick(s.b.sim));
    }
    ++s.tick;
    if (jsOn && wasmOn) {
      if (s.mode === "fast") s.dev = deviation(s.a.nodes, s.b.nodes);
      else if (!s.diverged && !identical(s.a.nodes, s.b.nodes)) s.diverged = s.tick;
    }
  }
  const c = colors(), drawLinks = $("links").checked;
  if (jsOn) draw($("js-canvas"), s.a, c.js, drawLinks);
  if (wasmOn) draw($("wasm-canvas"), s.b, c.wasm, drawLinks);

  $("js-ms").textContent = jsOn ? `${s.ma.mean.toFixed(2)} ms/tick` : "off";
  $("wasm-ms").textContent = wasmOn ? `${s.mb.mean.toFixed(2)} ms/tick` : "off";
  const both = jsOn && wasmOn;
  $("speedup").textContent = both && s.mb.mean > 0 ? `${(s.ma.mean / s.mb.mean).toFixed(2)}×` : "–";
  $("tick").textContent = lead && !running ? `${s.tick} (settled)` : s.tick;
  const parity = $("parity");
  if (!both) parity.textContent = "– (one side off)", parity.className = "";
  else if (s.mode === "fast") parity.textContent = `fast: ${pct(s.dev)} of extent from d3`, parity.className = "";
  else parity.textContent = s.diverged ? `diverged at tick ${s.diverged}` : "bit-identical", parity.className = s.diverged ? "bad" : "ok";
  $("workers").textContent = wasmOn ? workers(s.b.sim) : "–";

  if (running && !paused) frame = requestAnimationFrame(loop);
}

// Turning a side off just stops it; turning it back on restarts both, since
// the side that was off has fallen behind and the comparison needs them in step.
for (const [id, panel] of [["js-on", "js"], ["wasm-on", "wasm"]]) {
  $(id).onchange = () => {
    document.querySelector(`.panel.${panel}`).classList.toggle("off", !$(id).checked);
    if ($(id).checked) start();
    else if (!paused) cancelAnimationFrame(frame), frame = requestAnimationFrame(loop);
  };
}

$("restart").onclick = start;
$("n").onchange = start;
$("forces").onchange = start;
$("mode").onchange = start;
$("threads").onchange = start;
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
    [1000, "default", 300], [5000, "default", 300], [10000, "default", 300], [20000, "default", 100], [50000, "default", 30], [10000, "collide", 300]
  ];
  for (const [n, preset, ticks] of scenarios) {
    const label = `${n.toLocaleString()} nodes, ${preset === "collide" ? "+ collide" : "manyBody + link + center"}, ${ticks} ticks`;
    $("bench-status").textContent = `Running ${label}…`;
    await nextFrame();
    const a = build(d3, n, preset), b = build(wasm, n, preset, "exact"), c = build(wasm, n, preset, "fast");
    let ta = 0, tb = 0, tc = 0;
    for (let k = 0; k < ticks; k += 10) {
      // Rotate the order so no library always runs on a warm cache.
      const order = [[a, (v) => ta += v], [b, (v) => tb += v], [c, (v) => tc += v]];
      for (let r = 0; r < 3; ++r) {
        const [s, add] = order[(r + k / 10) % 3];
        add(timeTick10(s.sim));
      }
      await nextFrame();
    }
    const same = identical(a.nodes, b.nodes), dev = deviation(a.nodes, c.nodes);
    const tr = document.createElement("tr");
    tr.innerHTML = `<td>${label}</td><td>${ta.toFixed(0)} ms</td><td>${tb.toFixed(0)} ms</td><td><b>${(ta / tb).toFixed(2)}×</b></td>`
      + `<td>${tc.toFixed(0)} ms</td><td><b>${(ta / tc).toFixed(2)}×</b></td>`
      + `<td class="${same ? "ok" : "bad"}">${same ? "yes" : "no"}</td><td>${pct(dev)}</td>`;
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
$("source").textContent = window.D3FW_SOURCE || "d3-force-wasm";

start();
