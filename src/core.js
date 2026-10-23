// Loader and sync layer (TRD, Architecture: "Ownership rules"). One wasm
// instance per page; each nodes array gets one Context, a simulation region
// in the core that mirrors the nodes' x, y, vx, vy, fx, fy as typed arrays.

import bytes from "./core-bytes.js";

// The running force's random source, called by the core's jiggle.
let random = null;

const imports = {env: {random: () => random()}};

// Synchronous where allowed (Node, Deno, Bun, workers, Firefox, Safari);
// Chrome refuses it on the main thread for modules over 4 KB, so there the
// module waits once for async instantiation. The JS fallback that avoids
// this wait is M4 (TRD, Build: "Embedding and loading").
let instance;
try {
  instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports);
} catch {
  instance = (await WebAssembly.instantiate(bytes, imports)).instance;
}
const core = instance.exports;

// Force kinds, scalar slots and array slots; see src/core/force.zig.
export const CENTER = 0, COLLIDE = 1, LINK = 2, MANY_BODY = 3, RADIAL = 4, X = 5, Y = 6;
export const STRENGTH = 0, CX = 1, CY = 2, THETA2 = 3, DISTANCE_MIN2 = 4, DISTANCE_MAX2 = 5, ITERATIONS = 6,
    PRECISION = 7, ORDER = 8, OPENING = 9, SEED = 10;
export const F0 = 0, F1 = 1, F2 = 2, SOURCE = 3, TARGET = 4;

const statuses = {"-1": "BAD_HANDLE", "-2": "OUT_OF_MEMORY", "-3": "BAD_ARGUMENT"};

function check(status) {
  if (status < 0) throw new Error(statuses[status] || "core status " + status);
  return status;
}

const contexts = new WeakMap();
const registry = typeof FinalizationRegistry === "function"
  ? new FinalizationRegistry((h) => core.sim_destroy(h))
  : null;

class Context {
  constructor() {
    if (!(this.h = core.sim_create())) throw new Error("OUT_OF_MEMORY");
    this.n = 0;
    this.live = false; // true while a simulation tick owns the arrays
    this.buffer = null;
    this.precision = null; // null = exact; {order, opening} = fast (TRD 2)
    if (registry) registry.register(this, this.h);
  }

  resize(n) {
    if (n !== this.n) check(core.sim_set_node_count(this.h, n)), this.n = n, this.buffer = null;
  }

  // Views are re-made after memory growth or a resize moved the arrays.
  views() {
    if (this.buffer === core.memory.buffer) return;
    const b = this.buffer = core.memory.buffer, h = this.h, n = this.n;
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

  integrate(velocityDecay) {
    check(core.sim_integrate(this.h, velocityDecay));
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
  }

  bind(nodes) {
    const ctx = context(nodes);
    if (ctx !== this.ctx) {
      if (this.ctx) core.force_destroy(this.ctx.h, this.fh);
      if (!(this.fh = core.force_create(ctx.h, this.kind))) throw new Error("OUT_OF_MEMORY");
      this.ctx = ctx;
    }
    ctx.resize(nodes.length);
  }

  count(m) {
    check(core.force_set_count(this.ctx.h, this.fh, m));
  }

  // A view of one parameter array; valid until the next core call.
  f64(which, m) {
    return new Float64Array(core.memory.buffer, core.force_ptr(this.ctx.h, this.fh, which) >>> 0, m);
  }

  u32(which, m) {
    return new Uint32Array(core.memory.buffer, core.force_ptr(this.ctx.h, this.fh, which) >>> 0, m);
  }

  scalar(which, v) {
    core.force_set_scalar(this.ctx.h, this.fh, which, v);
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
      check(core.force_run(ctx.h, this.fh, alpha));
    } finally {
      random = previous;
      if (!ctx.live) ctx.copyOut(nodes);
    }
  }
}

// The Slot of a native force function, if any.
export const slot = Symbol("slot");
