// Loader and sync layer (TRD, Architecture: "Ownership rules"). Each nodes
// array gets one Context, a simulation region that mirrors the nodes' x, y,
// vx, vy, fx, fy as typed arrays. A Context starts in the inlined core; once
// the page's thread pool is ready (TRD 3, Facade), a simulation of at least
// `threshold` nodes moves to the threaded core. The pool, the move and the
// failover live in pool.js, imported only where threads could run, so other
// pages never load them.

import packed from "./core-bytes.js";

// The running force's random source, called by the core's jiggle.
let random = null;

export const env = {random: () => random()};

// The embedded module is deflated (scripts/embed-wasm.js); inflating it is
// the one wait at import, under a millisecond for this size.
const bytes = new Uint8Array(await new Response(new Blob([Uint8Array.from(atob(packed), (c) => c.charCodeAt(0))])
    .stream().pipeThrough(new DecompressionStream("deflate"))).arrayBuffer());

// Synchronous where allowed (Node, Deno, Bun, workers, Firefox, Safari);
// Chrome refuses it on the main thread for modules over 4 KB, so there the
// module waits once more for async instantiation.
let instance;
try {
  instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), {env});
} catch {
  instance = (await WebAssembly.instantiate(bytes, {env})).instance;
}
export const inlined = {exports: instance.exports, memory: instance.exports.memory, threaded: false};

// Force kinds, scalar slots and array slots; see src/core/force.zig.
export const CENTER = 0, COLLIDE = 1, LINK = 2, MANY_BODY = 3, RADIAL = 4, X = 5, Y = 6;
export const STRENGTH = 0, CX = 1, CY = 2, THETA2 = 3, DISTANCE_MIN2 = 4, DISTANCE_MAX2 = 5, ITERATIONS = 6,
    PRECISION = 7, ORDER = 8, OPENING = 9, SEED = 10;
export const F0 = 0, F1 = 1, F2 = 2, SOURCE = 3, TARGET = 4;
export const SCALARS = 11;

// Float parameter arrays per force kind, in force.zig's floatArrays order.
export const FLOATS = [0, 1, 3, 1, 2, 2, 2];

export const OUT_OF_MEMORY = -2, WORKER_FAILED = -4;
const statuses = {"-1": "BAD_HANDLE", "-2": "OUT_OF_MEMORY", "-3": "BAD_ARGUMENT", "-4": "WORKER_FAILED"};

export function check(status) {
  if (status < 0) throw new Error(statuses[status] || "core status " + status);
  return status;
}

// Simulations below this size stay on the inlined core (TRD 3, Requirements).
let threshold = 2000;

const contexts = new WeakMap();
export const registry = typeof FinalizationRegistry === "function"
  ? new FinalizationRegistry(({core, h}) => core.exports.sim_destroy(h))
  : null;

// Whether threads could run here at all; detection is by capability.
const isNode = typeof process === "object" && !!(process.versions && process.versions.node)
    && typeof WorkerGlobalScope === "undefined";

function capable() {
  return isNode || globalThis.crossOriginIsolated === true && typeof SharedArrayBuffer === "function"
      && typeof Worker === "function" && typeof Atomics === "object";
}

// pool.js, once a simulation big enough for threads has asked for it.
let threads = null, loading = null;
export const urls = {core: null, worker: null};

function loadThreads() {
  if (!loading) {
    loading = !capable() ? Promise.resolve() : import("./pool.js").then((m) => {
      threads = m;
      m.request(isNode);
      return m.settled();
    }, () => {});
  }
  return loading;
}

// Where core-mt.wasm and worker.js are fetched from, for bundlers that do not
// rewrite `new URL(…, import.meta.url)` (TRD 2, Public API and loader).
export function configure(options) {
  if (options && options.coreURL != null) urls.core = options.coreURL;
  if (options && options.workerURL != null) urls.worker = options.workerURL;
}

class Context {
  constructor() {
    this.core = inlined;
    if (!(this.h = inlined.exports.sim_create())) throw new Error("OUT_OF_MEMORY");
    this.n = 0;
    this.live = false; // true while a simulation tick owns the arrays
    this.buffer = null;
    this.precision = null; // null = exact; {order, opening} = fast (TRD 2)
    this.slots = new Set(); // every native force bound to these nodes
    this.inlinedOnly = false; // set by an OUT_OF_MEMORY on the threaded core
    if (registry) registry.register(this, {core: this.core, h: this.h}, this);
  }

  resize(n) {
    if (n !== this.n) check(this.core.exports.sim_set_node_count(this.h, n)), this.n = n, this.buffer = null;
  }

  // Views are re-made after memory growth or a resize moved the arrays.
  views() {
    const b = this.core.memory.buffer;
    if (this.buffer === b) return;
    const core = this.core.exports, h = this.h, n = this.n;
    this.buffer = b;
    this.x = new Float64Array(b, core.sim_ptr(h, 0) >>> 0, n);
    this.y = new Float64Array(b, core.sim_ptr(h, 1) >>> 0, n);
    this.vx = new Float64Array(b, core.sim_ptr(h, 2) >>> 0, n);
    this.vy = new Float64Array(b, core.sim_ptr(h, 3) >>> 0, n);
    this.fx = new Float64Array(b, core.sim_ptr(h, 4) >>> 0, n);
    this.fy = new Float64Array(b, core.sim_ptr(h, 5) >>> 0, n);
    this.fixed = new Uint8Array(b, core.sim_ptr(h, 6) >>> 0, n);
  }

  copyIn(nodes) {
    const n = nodes.length;
    this.resize(n), this.views();
    const {x, y, vx, vy, fx, fy, fixed} = this;
    for (let i = 0, d; i < n; ++i) {
      d = nodes[i];
      x[i] = d.x, y[i] = d.y, vx[i] = d.vx, vy[i] = d.vy;
      fx[i] = d.fx, fy[i] = d.fy; // read only when fixed
      fixed[i] = (d.fx != null) | (d.fy != null) << 1;
    }
  }

  copyOut(nodes) {
    this.views();
    const {x, y, vx, vy} = this;
    for (let i = 0, n = this.n, d; i < n; ++i) {
      d = nodes[i];
      d.x = x[i], d.y = y[i], d.vx = vx[i], d.vy = vy[i];
    }
  }

  // The workers a tick of n nodes may use (0 on the inlined core), after
  // moving to the core it should run on (TRD 3, Facade: "Moving a
  // simulation across"). `setting` is the simulation's threads(): null for
  // auto, else the most workers it may use.
  engage(n, setting) {
    const want = setting !== 0 && n >= threshold && !this.inlinedOnly;
    if (threads) return threads.engage(this, want, setting);
    if (want) loadThreads();
    return 0;
  }

  // Runs one step: a force, or integrate when `slot` is null. pool.js runs
  // the threaded core's steps, with their failover (TRD 3, Facade: "Failure").
  step(slot, arg) {
    if (this.core.threaded) return threads.step(this, slot, arg);
    const ex = this.core.exports;
    check(slot ? ex.force_run(this.h, slot.fh, arg) : ex.sim_integrate(this.h, arg));
  }

  integrate(velocityDecay) {
    this.step(null, velocityDecay);
  }
}

export function context(nodes) {
  let c = contexts.get(nodes);
  if (!c) contexts.set(nodes, c = new Context());
  return c;
}

// A native force's handle in the core: rebinds when initialized on another
// nodes array, and runs inside a tick or standalone with its own copies.
export class Slot {
  constructor(kind) {
    this.kind = kind;
    this.ctx = null;
    this.fh = 0;
    this.m = 0; // array length, as of the last count()
  }

  bind(nodes) {
    const ctx = context(nodes);
    if (ctx !== this.ctx) {
      if (this.ctx) this.ctx.core.exports.force_destroy(this.ctx.h, this.fh), this.ctx.slots.delete(this);
      if (!(this.fh = ctx.core.exports.force_create(ctx.h, this.kind))) throw new Error("OUT_OF_MEMORY");
      this.ctx = ctx, this.m = 0;
      ctx.slots.add(this);
    }
    ctx.resize(nodes.length);
  }

  count(m) {
    check(this.ctx.core.exports.force_set_count(this.ctx.h, this.fh, m));
    this.m = m;
  }

  // A view of one parameter array; valid until the next core call.
  f64(which, m) {
    const core = this.ctx.core;
    return new Float64Array(core.memory.buffer, core.exports.force_ptr(this.ctx.h, this.fh, which) >>> 0, m);
  }

  u32(which, m) {
    const core = this.ctx.core;
    return new Uint32Array(core.memory.buffer, core.exports.force_ptr(this.ctx.h, this.fh, which) >>> 0, m);
  }

  scalar(which, v) {
    this.ctx.core.exports.force_set_scalar(this.ctx.h, this.fh, which, v);
  }

  run(nodes, alpha, rand) {
    const ctx = this.ctx, fast = ctx.precision;
    if (!ctx.live) ctx.copyIn(nodes);
    // Fast mode: the FMM parameters, and one draw of the force's random per
    // run as the seed for hashed jiggle (TRD 2, "d3 semantics kept").
    this.scalar(PRECISION, fast ? 1 : 0);
    if (fast) {
      this.scalar(ORDER, fast.order), this.scalar(OPENING, fast.opening);
      if (this.kind === MANY_BODY || this.kind === LINK || this.kind === COLLIDE) this.scalar(SEED, rand());
    }
    const previous = random;
    random = rand;
    try {
      ctx.step(this, alpha);
    } finally {
      random = previous;
      if (!ctx.live) ctx.copyOut(nodes);
    }
  }
}

// The Slot of a native force function, if any.
export const slot = Symbol("slot");

// Test-only knobs (TRD 3, Testing): the threshold, and the threaded core's
// chunk and cut overrides (pool_tune), so small scenarios split too.
export const testing = {
  get pool() { return threads; },
  threshold(n) { threshold = n; },
  tune(which, v) {
    const core = threads && threads.ready();
    if (core) core.exports.pool_tune(which, v);
  },
  request: loadThreads
};
