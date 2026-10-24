// Thread pool client (TRD 3, Facade: "two cores, one pool"), imported by
// core.js only where threads could run. The threaded core is loaded at most
// once per page, on a shared memory, with hardwareConcurrency − 1 workers;
// until it is ready, and wherever threads fail, every simulation runs on the
// inlined core. A simulation moves between the two by copying its arrays.

import {inlined, env, check, registry, urls, LINK, SOURCE, TARGET, SCALARS, FLOATS, OUT_OF_MEMORY, WORKER_FAILED} from "./core.js";

// A specifier bundlers leave alone, for the Node-only modules.
const nodeImport = (name) => import(/* @vite-ignore */ name);

let state = "idle"; // idle | loading | ready | unavailable | retired
let threaded = null; // {exports, memory, threaded: true, workers, k}
let loading = null;
let isNode = false;

// The threaded core once its workers have started, else null.
export function ready() {
  return state === "ready" ? threaded : null;
}

export function status() {
  return state;
}

// Starts loading the pool, once.
export function request(node) {
  if (state !== "idle") return;
  isNode = node;
  state = "loading";
  loading = load().then(
    (core) => { threaded = core, state = "ready"; },
    () => { state = "unavailable"; }
  );
}

// Resolves once a load started by request() has finished either way.
export function settled() {
  return loading || Promise.resolve();
}

// Retires the pool for good, after a worker failure (TRD 3, Facade: "Failure").
export function retire() {
  if (!threaded) return;
  state = "retired";
  threaded.exports.pool_retire();
  for (const w of threaded.workers) w.terminate();
}

// Context.engage once this module is loaded: moves the simulation to the core
// it should run on and returns the workers its tick may use.
export function engage(ctx, want, setting) {
  const core = ready();
  if (ctx.core.threaded && !core) moveTo(ctx, inlined); // the pool was retired
  if (!ctx.core.threaded) {
    if (!want || !core) return 0;
    try {
      moveTo(ctx, core);
    } catch {
      // The threaded core's shared memory is full: stay on the inlined core.
      ctx.inlinedOnly = true;
      return 0;
    }
  }
  return want ? (setting == null ? core.k : Math.min(setting, core.k)) : 0;
}

// Context.step on the threaded core: a force, or integrate when `slot` is
// null. The step's vx, vy (and x, y for integrate) are saved first; if a
// worker fails, or the threaded core runs out of memory, the simulation moves
// to the inlined core and the step runs again there with the same inputs, so
// the tick still returns d3's bits.
export function step(ctx, slot, arg) {
  const ex = ctx.core.exports, h = ctx.h;
  check(ex.sim_snapshot(h, slot ? 0 : 1));
  let s = slot ? ex.force_run(h, slot.fh, arg) : ex.sim_integrate(h, arg);
  if (s === WORKER_FAILED || s === OUT_OF_MEMORY) {
    if (s === WORKER_FAILED) retire();
    else ctx.inlinedOnly = true;
    moveTo(ctx, inlined, slot ? 1 : 2);
    s = slot ? inlined.exports.force_run(ctx.h, slot.fh, arg) : inlined.exports.sim_integrate(ctx.h, arg);
  }
  check(s);
}

function copy(from, fromPtr, to, toPtr, n, Type) {
  if (n > 0 && fromPtr && toPtr) new Type(to.memory.buffer, toPtr >>> 0, n).set(new Type(from.memory.buffer, fromPtr >>> 0, n));
}

// Moves the simulation and every force bound to it into `target` by copying
// their arrays and scalars verbatim, so no bit changes and no user accessor
// runs again. `restore` also copies the node state, with vx, vy (and x, y
// when `restore` is 2) from the snapshot taken before a failed step. Nothing
// changes if it throws.
export function moveTo(ctx, target, restore = 0) {
  const fe = ctx.core.exports, te = target.exports, oh = ctx.h;
  const h = te.sim_create();
  if (!h) throw new Error("OUT_OF_MEMORY");
  let handles;
  try {
    handles = copyTo(ctx, target, h, restore);
  } catch (error) {
    te.sim_destroy(h);
    throw error;
  }
  let k = 0;
  for (const s of ctx.slots) s.fh = handles[k++];
  fe.sim_destroy(oh);
  if (registry) registry.unregister(ctx), registry.register(ctx, {core: target, h}, ctx);
  ctx.core = target, ctx.h = h, ctx.buffer = null;
}

// The copying half of moveTo, into the fresh simulation h of `target`;
// returns the new force handles in slot order.
function copyTo(ctx, target, h, restore) {
  const from = ctx.core, fe = from.exports, te = target.exports, n = ctx.n, oh = ctx.h;
  const handles = [];
  check(te.sim_set_node_count(h, n));
  if (restore) {
    const snap = fe.sim_ptr(oh, 9) >>> 0, f64 = 8 * n;
    copy(from, snap, target, te.sim_ptr(h, 2), n, Float64Array);
    copy(from, snap + f64, target, te.sim_ptr(h, 3), n, Float64Array);
    copy(from, restore === 2 ? snap + 2 * f64 : fe.sim_ptr(oh, 0), target, te.sim_ptr(h, 0), n, Float64Array);
    copy(from, restore === 2 ? snap + 3 * f64 : fe.sim_ptr(oh, 1), target, te.sim_ptr(h, 1), n, Float64Array);
    for (const i of [4, 5]) copy(from, fe.sim_ptr(oh, i), target, te.sim_ptr(h, i), n, Float64Array);
    copy(from, fe.sim_ptr(oh, 6), target, te.sim_ptr(h, 6), n, Uint8Array);
  }
  for (const s of ctx.slots) {
    const fh = te.force_create(h, s.kind);
    if (!fh) throw new Error("OUT_OF_MEMORY");
    const m = s.kind === LINK ? s.m : n;
    if (s.kind === LINK) check(te.force_set_count(h, fh, m));
    for (let which = 0; which < FLOATS[s.kind]; ++which) {
      copy(from, fe.force_ptr(oh, s.fh, which), target, te.force_ptr(h, fh, which), m, Float64Array);
    }
    if (s.kind === LINK) {
      for (const which of [SOURCE, TARGET]) copy(from, fe.force_ptr(oh, s.fh, which), target, te.force_ptr(h, fh, which), m, Uint32Array);
    }
    for (let which = 0; which < SCALARS; ++which) te.force_set_scalar(h, fh, which, fe.force_get_scalar(oh, s.fh, which));
    handles.push(fh);
  }
  return handles;
}

async function cores() {
  const n = typeof navigator === "object" && navigator && navigator.hardwareConcurrency;
  if (n) return n;
  if (!isNode) return 1;
  const os = await nodeImport("node:os");
  return os.availableParallelism ? os.availableParallelism() : os.cpus().length || 1;
}

async function compile() {
  const url = urls.core || new URL("./core-mt.wasm", import.meta.url);
  if (isNode) {
    const {readFile} = await nodeImport("node:fs/promises");
    return WebAssembly.compile(await readFile(url));
  }
  try {
    return await WebAssembly.compileStreaming(fetch(url));
  } catch {
    return WebAssembly.compile(await (await fetch(url)).arrayBuffer());
  }
}

// A shared memory with the largest maximum the engine will reserve; the
// module declares 1 GiB, and a provided memory may declare less.
function sharedMemory() {
  for (const maximum of [16384, 8192, 2048]) {
    try {
      return new WebAssembly.Memory({initial: 32, maximum, shared: true});
    } catch {
      // try a smaller reservation
    }
  }
  throw new Error("no shared memory");
}

async function load() {
  const k = (await cores()) - 1;
  if (k < 1) throw new Error("one core");
  const module = await compile();
  const memory = sharedMemory();
  const exports = new WebAssembly.Instance(module, {env: {memory, random: env.random, now: () => performance.now()}}).exports;
  const base = exports.pool_init(k) >>> 0;
  if (!base) throw new Error("pool_init");
  const region = exports.pool_info(3), failed = exports.pool_info(2);
  const url = urls.worker || new URL("./worker.js", import.meta.url);
  const workers = await Promise.all(Array.from({length: k}, (_, i) =>
    spawn(url, {module, memory, tid: i + 1, region: base + i * region, failed})));
  return {exports, memory, threaded: true, workers, k};
}

async function spawn(url, data) {
  let worker;
  if (isNode) {
    const [{Worker}, {fileURLToPath}] = await Promise.all([nodeImport("node:worker_threads"), nodeImport("node:url")]);
    worker = new Worker(typeof url === "string" ? url : fileURLToPath(url));
    worker.unref();
  } else {
    worker = new Worker(url, {type: "module"});
  }
  return new Promise((resolve, reject) => {
    let running = false;
    const started = () => { running = true, resolve(worker); };
    // After start-up a worker's error is already in shared memory (worker.js),
    // where the spinning main thread sees it; the event itself is dropped.
    const failed = (error) => { if (!running) reject(error); };
    if (isNode) worker.once("message", started), worker.on("error", failed);
    else worker.onmessage = started, worker.onerror = (event) => { event.preventDefault(), failed(event); };
    worker.postMessage(data);
  });
}
