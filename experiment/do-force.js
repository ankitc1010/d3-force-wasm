// Data-oriented force layout in plain JavaScript — the experiment side of
// testing whether d3-force-wasm's speed-up comes from wasm or from the
// data-oriented design around it.
//
// This is a port of this repo's Zig core back into JS, keeping everything
// that is not wasm:
//
//   - Structure of arrays. x, y, vx, vy, fx, fy are Float64Arrays owned by
//     the simulation; node objects are copied in and out once per tick, just
//     as the wasm facade does.
//   - O(n) tree build (tree.zig): d3's cover arithmetic, 64-bit Morton keys
//     from d3's own midpoint test, an LSD radix sort, cells emitted in
//     preorder over contiguous key ranges. The tree is d3-quadtree's, cell
//     for cell, but flat typed arrays instead of allocated objects.
//   - No allocation per tick. Every buffer is allocated once and reused;
//     a steady-state tick allocates nothing.
//   - Inlined traversal (many_body.zig): the visit callback becomes a loop
//     over an explicit stack.
//
// Statement order is d3's everywhere, so the output is bit-identical to
// d3-force 3.0.0 (see parity-do.js). f64 in JS and wasm are the same IEEE
// arithmetic, and only correctly rounded operations appear here, exactly as
// the Zig core requires.

const NONE = -1;
const KEY_LEVELS = 32; // Morton key depth; deeper levels split by midpoint test
const MAX_DEPTH = 2200; // d3 loops forever past this; the build stops instead

// d3-force's lcg.js, verbatim: (a*s + c) % 2^32 stays under 2^53, so the
// f64 arithmetic is exact and draws match d3's stream.
export function lcg() {
  let s = 1;
  return () => (s = (1664525 * s + 1013904223) % 4294967296) / 4294967296;
}

const jiggle = (random) => (random() - 0.5) * 1e-6;

function constant(x) {
  return function () {
    return x;
  };
}

function index(d) {
  return d.index;
}

// ---------------------------------------------------------------------------
// The quadtree: d3-quadtree's tree over flat arrays.
// ---------------------------------------------------------------------------

export class Tree {
  constructor() {
    this.cap = 0;
    this.cellCap = 0;

    // Point order: perm is Morton-sorted; the keys ride alongside during the
    // sort (a 64-bit key kept as two u32 halves).
    this.perm = new Uint32Array(0);
    this.permTmp = new Uint32Array(0);
    this.keyLo = new Uint32Array(0); // levels 16..31 of the key
    this.keyHi = new Uint32Array(0); // levels 0..15
    this.tmpLo = new Uint32Array(0);
    this.tmpHi = new Uint32Array(0);
    this.diff = new Uint32Array(0); // diff[k] = distinct positions in perm[1..k]
    this.rest = new Uint32Array(0); // nodes with a NaN coordinate, in index order
    this.hist = new Int32Array(256);

    // Cells in preorder, structure of arrays. child[q] is NONE for leaves.
    this.child = new Int32Array(0);
    this.first = new Int32Array(0);
    this.count = new Int32Array(0);
    this.cx0 = new Float64Array(0);
    this.cy0 = new Float64Array(0);
    this.cx1 = new Float64Array(0);
    this.cy1 = new Float64Array(0);
    // Per-force summaries, written by the kernels that use them.
    this.cxs = new Float64Array(0);
    this.cys = new Float64Array(0);
    this.value = new Float64Array(0);

    // Build frames, structure of arrays.
    this.fLo = new Uint32Array(0);
    this.fHi = new Uint32Array(0);
    this.fDepth = new Int32Array(0);
    this.fParent = new Int32Array(0);
    this.fSlot = new Int32Array(0);
    this.fSorted = new Uint8Array(0);
    this.fX0 = new Float64Array(0);
    this.fY0 = new Float64Array(0);
    this.fX1 = new Float64Array(0);
    this.fY1 = new Float64Array(0);

    // Extent after cover, as d3's tree._x0 .. _y1; NaN when empty.
    this.x0 = NaN;
    this.y0 = NaN;
    this.x1 = NaN;
    this.y1 = NaN;
    this.root = NONE;
    this.len = 0; // cells used
    this.m = 0; // points in the tree
    this.depth = 0; // deepest cell, so walks can size their stacks
    this.walk = new Int32Array(64); // depth-first walk stack
  }

  reserve(n) {
    if (n <= this.cap) return;
    this.cap = Math.max(n, this.cap * 2, 16);
    this.perm = new Uint32Array(this.cap);
    this.permTmp = new Uint32Array(this.cap);
    this.keyLo = new Uint32Array(this.cap);
    this.keyHi = new Uint32Array(this.cap);
    this.tmpLo = new Uint32Array(this.cap);
    this.tmpHi = new Uint32Array(this.cap);
    this.diff = new Uint32Array(this.cap);
    this.rest = new Uint32Array(this.cap);
    this.cellCap = 2 * this.cap + 64;
    this.child = new Int32Array(4 * this.cellCap);
    this.first = new Int32Array(this.cellCap);
    this.count = new Int32Array(this.cellCap);
    this.cx0 = new Float64Array(this.cellCap);
    this.cy0 = new Float64Array(this.cellCap);
    this.cx1 = new Float64Array(this.cellCap);
    this.cy1 = new Float64Array(this.cellCap);
    this.cxs = new Float64Array(this.cellCap);
    this.cys = new Float64Array(this.cellCap);
    this.value = new Float64Array(this.cellCap);
    this.growFrames(256);
  }

  growFrames(need) {
    if (need <= this.fLo.length) return;
    const cap = Math.max(need, 2 * this.fLo.length || 64);
    const lo = new Uint32Array(cap), hi = new Uint32Array(cap);
    lo.set(this.fLo), hi.set(this.fHi);
    const depth = new Int32Array(cap), parent = new Int32Array(cap), slot = new Int32Array(cap);
    depth.set(this.fDepth), parent.set(this.fParent), slot.set(this.fSlot);
    const sorted = new Uint8Array(cap);
    sorted.set(this.fSorted);
    const x0 = new Float64Array(cap), y0 = new Float64Array(cap);
    const x1 = new Float64Array(cap), y1 = new Float64Array(cap);
    x0.set(this.fX0), y0.set(this.fY0), x1.set(this.fX1), y1.set(this.fY1);
    this.fLo = lo, this.fHi = hi;
    this.fDepth = depth, this.fParent = parent, this.fSlot = slot;
    this.fSorted = sorted;
    this.fX0 = x0, this.fY0 = y0, this.fX1 = x1, this.fY1 = y1;
  }

  // d3-quadtree's cover, statement for statement (with the build's depth
  // guard, where d3 itself would loop forever on adjacent floats).
  cover(x, y) {
    if (x !== x || y !== y) return;
    let x0 = this.x0, y0 = this.y0, x1 = this.x1, y1 = this.y1;
    if (x0 !== x0) {
      x1 = (x0 = Math.floor(x)) + 1;
      y1 = (y0 = Math.floor(y)) + 1;
    } else {
      let z = x1 - x0 || 1;
      let guard = 0;
      while ((x0 > x || x >= x1 || y0 > y || y >= y1) && guard++ < MAX_DEPTH) {
        const i = (y < y0) << 1 | (x < x0);
        z *= 2;
        switch (i) {
          case 0: x1 = x0 + z, y1 = y0 + z; break;
          case 1: x0 = x1 - z, y1 = y0 + z; break;
          case 2: x1 = x0 + z, y0 = y1 - z; break;
          case 3: x0 = x1 - z, y0 = y1 - z; break;
        }
      }
    }
    this.x0 = x0, this.y0 = y0, this.x1 = x1, this.y1 = y1;
  }

  build(xs, ys, n) {
    // Bounding box with addAll's comparisons; m counts points with finite
    // coordinates, exactly as addAll skips NaN points.
    let bx0 = Infinity, by0 = Infinity, bx1 = -Infinity, by1 = -Infinity, m = 0;
    for (let i = 0; i < n; ++i) {
      const x = xs[i], y = ys[i];
      if (x !== x || y !== y) continue;
      if (x < bx0) bx0 = x;
      if (x > bx1) bx1 = x;
      if (y < by0) by0 = y;
      if (y > by1) by1 = y;
      ++m;
    }
    this.m = m;
    this.root = NONE;
    this.len = 0;
    this.depth = 0;
    if (!(bx0 <= bx1) || !(by0 <= by1)) return;

    this.x0 = NaN, this.y0 = NaN, this.x1 = NaN, this.y1 = NaN;
    this.cover(bx0, by0);
    this.cover(bx1, by1);
    const e0 = this.x0, e1 = this.y0, e2 = this.x1, e3 = this.y1;

    // Compact the finite points and compute their Morton keys by d3's own
    // midpoint test, so every bit is the branch d3's insertion would take.
    // Points with a NaN coordinate are left out of the tree and collected in
    // rest, as addAll skips them; the force still traverses them.
    const perm = this.perm, keyLo = this.keyLo, keyHi = this.keyHi, rest = this.rest;
    let k = 0, r = 0;
    for (let i = 0; i < n; ++i) {
      const x = xs[i], y = ys[i];
      if (x !== x || y !== y) {
        rest[r++] = i;
        continue;
      }
      perm[k] = i;
      let x0 = e0, y0 = e1, x1 = e2, y1 = e3, hi = 0, lo = 0;
      for (let d = 0; d < KEY_LEVELS; ++d) {
        const xm = (x0 + x1) / 2, ym = (y0 + y1) / 2;
        const right = x >= xm;
        if (right) x0 = xm; else x1 = xm;
        const bottom = y >= ym;
        if (bottom) y0 = ym; else y1 = ym;
        const q = (bottom ? 2 : 0) | (right ? 1 : 0);
        if (d < 16) hi = hi * 4 + q; else lo = lo * 4 + q;
      }
      keyHi[k] = hi;
      keyLo[k] = lo;
      ++k;
    }

    this.radixSort();

    // Run boundaries between distinct positions, in sorted order. perm is
    // re-read here: the radix sort swaps its buffers.
    const diff = this.diff, sortedPerm = this.perm;
    if (m > 0) {
      diff[0] = 0;
      let p = sortedPerm[0];
      for (let t = 1; t < m; ++t) {
        const q = sortedPerm[t];
        diff[t] = diff[t - 1] + ((xs[q] !== xs[p] || ys[q] !== ys[p]) ? 1 : 0);
        p = q;
      }
    }

    this.emit(xs, ys);

    // A depth-first walk that pushes up to four children holds at most
    // 3 * depth + 1 cells.
    const stride = 3 * this.depth + 4;
    if (this.walk.length < stride) this.walk = new Int32Array(stride);
  }

  // Stable LSD radix sort of the 64-bit keys, low bytes first, carrying perm.
  radixSort() {
    const m = this.m;
    if (m < 2) return;
    let aP = this.perm, aLo = this.keyLo, aHi = this.keyHi;
    let bP = this.permTmp, bLo = this.tmpLo, bHi = this.tmpHi;
    const hist = this.hist;
    for (let pass = 0; pass < 8; ++pass) {
      const src = pass < 4 ? aLo : aHi;
      const shift = (pass & 3) * 8;
      hist.fill(0);
      let sum = 0, same = true;
      const first = (src[0] >>> shift) & 255;
      for (let t = 0; t < m; ++t) {
        const b = (src[t] >>> shift) & 255;
        hist[b] += 1;
        if (b !== first) same = false;
      }
      if (same) continue; // every byte equal: the pass would move nothing
      for (let b = 0; b < 256; ++b) {
        const c = hist[b];
        hist[b] = sum;
        sum += c;
      }
      for (let t = 0; t < m; ++t) {
        const o = hist[(src[t] >>> shift) & 255]++;
        bP[o] = aP[t];
        bLo[o] = aLo[t];
        bHi[o] = aHi[t];
      }
      let tP = aP; aP = bP; bP = tP;
      let tLo = aLo; aLo = bLo; bLo = tLo;
      let tHi = aHi; aHi = bHi; bHi = tHi;
    }
    this.perm = aP, this.permTmp = bP;
    this.keyLo = aLo, this.keyHi = aHi;
    this.tmpLo = bLo, this.tmpHi = bHi;
  }

  pushFrame(lo, hi, dep, parent, slot, sorted, x0, y0, x1, y1) {
    this.growFrames(this.sp + 1);
    const sp = this.sp++;
    this.fLo[sp] = lo, this.fHi[sp] = hi;
    this.fDepth[sp] = dep, this.fParent[sp] = parent, this.fSlot[sp] = slot;
    this.fSorted[sp] = sorted;
    this.fX0[sp] = x0, this.fY0[sp] = y0, this.fX1[sp] = x1, this.fY1[sp] = y1;
  }

  // Emits cells in preorder over contiguous key ranges, splitting coincident
  // runs by d3's midpoint test below the key resolution. Children in 0..3
  // order, exactly d3-quadtree's visit order.
  emit(xs, ys) {
    const m = this.m, perm = this.perm, diff = this.diff;
    const child = this.child, first = this.first, count = this.count;
    const cx0 = this.cx0, cy0 = this.cy0, cx1 = this.cx1, cy1 = this.cy1;
    const e0 = this.x0, e1 = this.y0, e2 = this.x1, e3 = this.y1;
    let len = 0, depth = 0;

    this.sp = 0;
    this.pushFrame(0, m, 0, NONE, 0, 1, e0, e1, e2, e3);

    while (this.sp > 0) {
      const sp = --this.sp;
      const lo = this.fLo[sp], hi = this.fHi[sp], dep = this.fDepth[sp];
      const parent = this.fParent[sp], slot = this.fSlot[sp], sorted = this.fSorted[sp];
      const x0 = this.fX0[sp], y0 = this.fY0[sp], x1 = this.fX1[sp], y1 = this.fY1[sp];

      const me = len++;
      first[me] = lo;
      count[me] = hi - lo;
      cx0[me] = x0, cy0[me] = y0, cx1[me] = x1, cy1[me] = y1;
      child[4 * me] = NONE, child[4 * me + 1] = NONE, child[4 * me + 2] = NONE, child[4 * me + 3] = NONE;
      if (parent >= 0) child[4 * parent + slot] = me;
      if (dep > depth) depth = dep;

      // A quadrant is a leaf exactly when every point in it is coincident,
      // which is what d3's incremental insertion produces.
      const allSame = sorted
        ? diff[hi - 1] === diff[lo]
        : scanSame(xs, ys, perm, lo, hi);
      if (dep >= MAX_DEPTH || allSame) continue;

      if (sorted && dep < KEY_LEVELS) {
        // Children are contiguous key ranges; find the three boundaries,
        // then push the non-empty children 3..0 so 0 pops first (preorder).
        // Every child here is key-sorted too: the parent was, and the
        // parent's depth is below the key resolution.
        const xm = (x0 + x1) / 2, ym = (y0 + y1) / 2;
        let b1 = lo, b2 = lo, b3 = lo;
        let k = lo;
        for (let q = 1; q < 4; ++q) {
          while (k < hi && quadKey(this.keyHi, this.keyLo, k, dep) < q) ++k;
          if (q === 1) b1 = k; else if (q === 2) b2 = k; else b3 = k;
        }
        if (b3 < hi) this.pushFrame(b3, hi, dep + 1, me, 3, 1,
          xm, ym, x1, y1);
        if (b2 < b3) this.pushFrame(b2, b3, dep + 1, me, 2, 1,
          x0, ym, xm, y1);
        if (b1 < b2) this.pushFrame(b1, b2, dep + 1, me, 1, 1,
          xm, y0, x1, ym);
        if (lo < b1) this.pushFrame(lo, b1, dep + 1, me, 0, 1,
          x0, y0, xm, ym);
      } else {
        // Below the key resolution: stable partition by the midpoint test,
        // which is idempotent, so the subtree can be walked the same way
        // d3's insertion would walk it.
        const xm = (x0 + x1) / 2, ym = (y0 + y1) / 2;
        const permTmp = this.permTmp;
        let c0 = 0, c1 = 0, c2 = 0, c3 = 0;
        for (let t = lo; t < hi; ++t) {
          const p = perm[t];
          if (ys[p] >= ym) {
            if (xs[p] >= xm) c3 += 1; else c2 += 1;
          } else {
            if (xs[p] >= xm) c1 += 1; else c0 += 1;
          }
        }
        const o3 = hi - c3, o2 = o3 - c2, o1 = o2 - c1, o0 = lo;
        let w0 = o0, w1 = o1, w2 = o2, w3 = o3;
        for (let t = lo; t < hi; ++t) {
          const p = perm[t];
          if (ys[p] >= ym) {
            if (xs[p] >= xm) permTmp[w3++] = p; else permTmp[w2++] = p;
          } else {
            if (xs[p] >= xm) permTmp[w1++] = p; else permTmp[w0++] = p;
          }
        }
        for (let t = lo; t < hi; ++t) perm[t] = permTmp[t];
        for (let q = 3; q >= 0; --q) {
          const blo = q === 0 ? o0 : q === 1 ? o1 : q === 2 ? o2 : o3;
          const bhi = q === 0 ? o1 : q === 1 ? o2 : q === 2 ? o3 : hi;
          if (blo >= bhi) continue;
          this.pushFrame(blo, bhi, dep + 1, me, q, 0,
            q & 1 ? xm : x0, q & 2 ? ym : y0, q & 1 ? x1 : xm, q & 2 ? y1 : ym);
        }
      }
    }

    this.len = len;
    this.depth = depth;
    this.root = len > 0 ? 0 : NONE;
  }
}

// The two key bits of point perm[t] at `depth`: 0..3 in visit order.
function quadKey(keyHi, keyLo, t, depth) {
  return depth < 16
    ? (keyHi[t] >>> (30 - 2 * depth)) & 3
    : (keyLo[t] >>> (30 - 2 * (depth - 16))) & 3;
}

function scanSame(xs, ys, perm, lo, hi) {
  const p0 = perm[lo];
  const x0 = xs[p0], y0 = ys[p0];
  for (let t = lo + 1; t < hi; ++t) {
    const p = perm[t];
    if (xs[p] !== x0 || ys[p] !== y0) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Forces. Signatures follow d3-force; initialize takes the simulation's SoA
// state as a third argument, which d3's forces don't need because they read
// the node objects themselves.
// ---------------------------------------------------------------------------

// forceManyBody: d3's Barnes-Hut over the flat tree, the visit callback
// inlined into a loop over an explicit stack.
export function forceManyBody() {
  var nodes,
      state,
      random,
      strength = constant(-30),
      theta2 = 0.81,
      distanceMin2 = 1,
      distanceMax2 = Infinity,
      strengths = new Float64Array(0),
      flags = new Uint8Array(0),
      tree = new Tree(),
      // Traversal state, refreshed by force() at entry so that traverse can
      // live at this level and no closure is built per tick.
      X, Y, VX, VY, ROOT, CHILD, FIRST, COUNT, PERM, REST, STACK,
      CX0, CY0, CX1, CY1, CXS, CYS, VALUE;

  function initialize() {
    if (!nodes) return;
    var n = nodes.length;
    if (strengths.length < n) strengths = new Float64Array(Math.max(n, 2 * strengths.length));
    if (flags.length < n) flags = new Uint8Array(Math.max(n, 2 * flags.length));
    for (var i = 0; i < n; ++i) strengths[i] = +strength(nodes[i], i, nodes);
    tree.reserve(n);
  }

  // visitAfter: cells are numbered in preorder, so a reverse sweep is a
  // valid post-order and every child is final when its parent sums it.
  function accumulate() {
    var x = state.x, y = state.y;
    var child = tree.child, first = tree.first, count = tree.count, perm = tree.perm;
    var cxs = tree.cxs, cys = tree.cys, value = tree.value;
    var strength = 0;
    for (var c = tree.len - 1; c >= 0; --c) {
      var b = 4 * c;
      if (child[b] >= 0 || child[b + 1] >= 0 || child[b + 2] >= 0 || child[b + 3] >= 0) {
        strength = 0;
        var weight = 0, sx = 0, sy = 0;
        for (var q = 0; q < 4; ++q) {
          var ch = child[b + q];
          if (ch >= 0) {
            var v = value[ch], w = Math.abs(v);
            if (w) { // `c = Math.abs(q.value)` is truthy: not 0, not NaN
              strength += v;
              weight += w;
              sx += w * cxs[ch];
              sy += w * cys[ch];
            }
          }
        }
        cxs[c] = sx / weight;
        cys[c] = sy / weight;
      } else {
        // The leaf chain runs head first, in descending index order.
        var f = first[c], cnt = count[c];
        var head = perm[f + cnt - 1];
        cxs[c] = x[head];
        cys[c] = y[head];
        strength = 0;
        for (var t = f + cnt; t > f;) strength += strengths[perm[--t]];
      }
      value[c] = strength;
    }
  }

  function force(alpha) {
    var n = nodes.length;
    X = state.x, Y = state.y, VX = state.vx, VY = state.vy;
    tree.build(X, Y, n);
    if (tree.root === NONE) return;
    accumulate();

    ROOT = tree.root, CHILD = tree.child, FIRST = tree.first, COUNT = tree.count, PERM = tree.perm;
    REST = tree.rest;
    CX0 = tree.cx0, CY0 = tree.cy0, CX1 = tree.cx1, CY1 = tree.cy1;
    CXS = tree.cxs, CYS = tree.cys, VALUE = tree.value;
    STACK = tree.walk;

    // Nodes are traversed in Morton order — the order the tree's points
    // already sit in — because consecutive nodes then visit the same cells,
    // and that locality is worth about 30% over index order. A node that
    // would draw from random (a coincident cell) is abandoned unwritten and
    // flagged; afterwards the flagged nodes rerun in ascending index order,
    // drawing what d3 draws in d3's order, since nodes that never jiggle
    // never draw. This is the scheme of the wasm core's exact many_body.
    var m = tree.m, flagged = 0;
    for (var p = 0; p < m; ++p) {
      var i0 = PERM[p];
      if (!traverse(i0, false, alpha)) flags[i0] = 1, ++flagged;
    }
    for (var q = m; q < n; ++q) traverse(REST[q - m], false, alpha); // NaN nodes draw nothing
    if (flagged) {
      for (var i1 = 0; i1 < n; ++i1) {
        if (flags[i1]) {
          flags[i1] = 0;
          traverse(i1, true, alpha);
        }
      }
    }
  }

  // d3's traversal for node i, over the flat tree. With `record` false it
  // returns false without writing anything at the first point where d3
  // would call random; with it true, the draws happen in d3's order.
  function traverse(i, record, alpha) {
    var nx = X[i], ny = Y[i];
    var vx1 = VX[i], vy1 = VY[i];
    var sp = 1;
    STACK[0] = ROOT;
    while (sp > 0) {
      var c = STACK[--sp];
      var v = VALUE[c];
      if (!v) continue; // `!quad.value`: 0, -0 and NaN

      var dx = CXS[c] - nx;
      var dy = CYS[c] - ny;
      var w = CX1[c] - CX0[c];
      var l = dx * dx + dy * dy;

      // Barnes-Hut approximation.
      if (w * w / theta2 < l) {
        if (l < distanceMax2) {
          if (dx === 0 || dy === 0) {
            if (!record) return false;
            if (dx === 0) { dx = jiggle(random); l += dx * dx; }
            if (dy === 0) { dy = jiggle(random); l += dy * dy; }
          }
          if (l < distanceMin2) l = Math.sqrt(distanceMin2 * l);
          vx1 += dx * v * alpha / l;
          vy1 += dy * v * alpha / l;
        }
        continue;
      }

      var b = 4 * c;
      var c0 = CHILD[b], c1 = CHILD[b + 1], c2 = CHILD[b + 2], c3 = CHILD[b + 3];
      if (c0 >= 0 || c1 >= 0 || c2 >= 0 || c3 >= 0) {
        // `return` (undefined): descend, pushing children 3..0.
        if (c3 >= 0) STACK[sp++] = c3;
        if (c2 >= 0) STACK[sp++] = c2;
        if (c1 >= 0) STACK[sp++] = c1;
        if (c0 >= 0) STACK[sp++] = c0;
        continue;
      }
      if (l >= distanceMax2) continue;

      // Leaf: process points directly.
      var f = FIRST[c], cnt = COUNT[c];
      var head = PERM[f + cnt - 1];
      if (head !== i || cnt > 1) {
        if (dx === 0 || dy === 0) {
          if (!record) return false;
          if (dx === 0) { dx = jiggle(random); l += dx * dx; }
          if (dy === 0) { dy = jiggle(random); l += dy * dy; }
        }
        if (l < distanceMin2) l = Math.sqrt(distanceMin2 * l);
      }
      for (var t = f + cnt; t > f;) {
        var j = PERM[--t];
        if (j !== i) {
          var wj = strengths[j] * alpha / l;
          vx1 += dx * wj;
          vy1 += dy * wj;
        }
      }
    }
    VX[i] = vx1;
    VY[i] = vy1;
    return true;
  }

  force.initialize = function (_nodes, _random, _state) {
    nodes = _nodes;
    random = _random;
    state = _state;
    initialize();
  };
  force.strength = function (_) {
    return arguments.length ? (strength = typeof _ === "function" ? _ : constant(+_), initialize(), force) : strength;
  };
  force.distanceMin = function (_) {
    return arguments.length ? (distanceMin2 = _ * _, force) : Math.sqrt(distanceMin2);
  };
  force.distanceMax = function (_) {
    return arguments.length ? (distanceMax2 = _ * _, force) : Math.sqrt(distanceMax2);
  };
  force.theta = function (_) {
    return arguments.length ? (theta2 = _ * _, force) : Math.sqrt(theta2);
  };

  return force;
}

// forceLink: Gauss-Seidel over the edge list in user order, over SoA.
export function forceLink(links) {
  var id = index,
      strength = defaultStrength,
      distance = constant(30),
      nodes,
      random,
      state,
      iterations = 1,
      count,
      bias,
      strengths,
      distances,
      source,
      target,
      m = 0;

  if (links == null) links = [];

  function defaultStrength(link) {
    return 1 / Math.min(count[link.source.index], count[link.target.index]);
  }

  function find(nodeById, nodeId) {
    var node = nodeById.get(nodeId);
    if (!node) throw new Error("node not found: " + nodeId);
    return node;
  }

  function initialize() {
    if (!nodes) return;
    var n = nodes.length;
    m = links.length;
    if (count == null || count.length < n) count = new Uint32Array(Math.max(n, 16));
    else count.fill(0, 0, n);
    var nodeById = new Map();
    for (var i = 0; i < n; ++i) nodeById.set(id(nodes[i], i, nodes), nodes[i]);
    if (source == null || source.length < m) {
      var cap = Math.max(m, 16);
      source = new Uint32Array(cap);
      target = new Uint32Array(cap);
      strengths = new Float64Array(cap);
      distances = new Float64Array(cap);
      bias = new Float64Array(cap);
    }
    for (var k = 0; k < m; ++k) {
      var link = links[k];
      link.index = k;
      if (typeof link.source !== "object") link.source = find(nodeById, link.source);
      if (typeof link.target !== "object") link.target = find(nodeById, link.target);
      source[k] = link.source.index;
      target[k] = link.target.index;
      count[source[k]] += 1;
      count[target[k]] += 1;
    }
    for (var j = 0; j < m; ++j) {
      bias[j] = count[source[j]] / (count[source[j]] + count[target[j]]);
      strengths[j] = +strength(links[j], j, links);
      distances[j] = +distance(links[j], j, links);
    }
  }

  function force(alpha) {
    var x = state.x, y = state.y, vx = state.vx, vy = state.vy;
    for (var k = 0; k < iterations; ++k) {
      for (var i = 0; i < m; ++i) {
        var s = source[i], t = target[i];
        // `a || jiggle(random)` falls through on 0, -0 and NaN.
        var dx = x[t] + vx[t] - x[s] - vx[s];
        if (dx === 0 || dx !== dx) dx = jiggle(random);
        var dy = y[t] + vy[t] - y[s] - vy[s];
        if (dy === 0 || dy !== dy) dy = jiggle(random);
        var l = Math.sqrt(dx * dx + dy * dy);
        l = (l - distances[i]) / l * alpha * strengths[i];
        dx *= l;
        dy *= l;
        var b = bias[i];
        vx[t] -= dx * b;
        vy[t] -= dy * b;
        b = 1 - b;
        vx[s] += dx * b;
        vy[s] += dy * b;
      }
    }
  }

  force.initialize = function (_nodes, _random, _state) {
    nodes = _nodes;
    random = _random;
    state = _state;
    initialize();
  };
  force.links = function (_) {
    return arguments.length ? (links = _, initialize(), force) : links;
  };
  force.id = function (_) {
    return arguments.length ? (id = _, force) : id;
  };
  force.iterations = function (_) {
    return arguments.length ? (iterations = +_, force) : iterations;
  };
  force.strength = function (_) {
    return arguments.length ? (strength = typeof _ === "function" ? _ : constant(+_), initializeStrength(), force) : strength;
  };
  force.distance = function (_) {
    return arguments.length ? (distance = typeof _ === "function" ? _ : constant(+_), initializeDistance(), force) : distance;
  };

  function initializeStrength() {
    if (!nodes) return;
    for (var i = 0; i < m; ++i) strengths[i] = +strength(links[i], i, links);
  }

  function initializeDistance() {
    if (!nodes) return;
    for (var i = 0; i < m; ++i) distances[i] = +distance(links[i], i, links);
  }

  return force;
}

// forceCenter: d3's sequential sums over SoA.
export function forceCenter(x, y) {
  var nodes, state, strength = 1;

  if (x == null) x = 0;
  if (y == null) y = 0;

  function force() {
    var xs = state.x, ys = state.y;
    var n = nodes.length, sx = 0, sy = 0;
    for (var i = 0; i < n; ++i) {
      sx += xs[i];
      sy += ys[i];
    }
    sx = (sx / n - x) * strength;
    sy = (sy / n - y) * strength;
    for (var j = 0; j < n; ++j) {
      xs[j] -= sx;
      ys[j] -= sy;
    }
  }

  force.initialize = function (_nodes, _random, _state) {
    nodes = _nodes;
    state = _state;
  };
  force.x = function (_) {
    return arguments.length ? (x = +_, force) : x;
  };
  force.y = function (_) {
    return arguments.length ? (y = +_, force) : y;
  };
  force.strength = function (_) {
    return arguments.length ? (strength = +_, force) : strength;
  };

  return force;
}

// ---------------------------------------------------------------------------
// The simulation: d3's tick over SoA, node objects copied in and out once
// per tick, as the wasm facade does.
// ---------------------------------------------------------------------------

var initialRadius = 10,
    initialAngle = Math.PI * (3 - Math.sqrt(5));

export function forceSimulation(nodes) {
  var alpha = 1,
      alphaMin = 0.001,
      alphaDecay = 1 - Math.pow(alphaMin, 1 / 300),
      alphaTarget = 0,
      velocityDecay = 0.6,
      forces = new Map(),
      random = lcg(),
      cap = 0,
      n = 0,
      x, y, vx, vy, fx, fy, fixed,
      state,
      simulation;

  if (nodes == null) nodes = [];

  function ensure() {
    if (n <= cap) return;
    cap = Math.max(n, cap * 2, 16);
    x = new Float64Array(cap);
    y = new Float64Array(cap);
    vx = new Float64Array(cap);
    vy = new Float64Array(cap);
    fx = new Float64Array(cap);
    fy = new Float64Array(cap);
    fixed = new Uint8Array(cap);
    // The state object's identity is stable, so forces that captured it see
    // the arrays grow.
    if (state == null) state = {x, y, vx, vy, fx, fy, fixed};
    else state.x = x, state.y = y, state.vx = vx, state.vy = vy, state.fx = fx, state.fy = fy, state.fixed = fixed;
  }

  function initializeNodes() {
    n = nodes.length;
    ensure();
    for (var i = 0, node; i < n; ++i) {
      node = nodes[i], node.index = i;
      if (node.fx != null) node.x = node.fx;
      if (node.fy != null) node.y = node.fy;
      if (isNaN(node.x) || isNaN(node.y)) {
        var radius = initialRadius * Math.sqrt(0.5 + i), angle = i * initialAngle;
        node.x = radius * Math.cos(angle);
        node.y = radius * Math.sin(angle);
      }
      if (isNaN(node.vx) || isNaN(node.vy)) {
        node.vx = node.vy = 0;
      }
    }
    forces.forEach(initializeForce);
  }

  function initializeForce(force) {
    if (force.initialize) force.initialize(nodes, random, state);
    return force;
  }

  function copyIn() {
    for (var i = 0; i < n; ++i) {
      var d = nodes[i];
      x[i] = d.x;
      y[i] = d.y;
      vx[i] = d.vx;
      vy[i] = d.vy;
      var b = 0;
      if (d.fx != null) fx[i] = d.fx, b |= 1;
      if (d.fy != null) fy[i] = d.fy, b |= 2;
      fixed[i] = b;
    }
  }

  function copyOut() {
    for (var i = 0; i < n; ++i) {
      var d = nodes[i];
      d.x = x[i];
      d.y = y[i];
      d.vx = vx[i];
      d.vy = vy[i];
    }
  }

  // The end of d3's tick: x += vx *= velocityDecay, or x = fx, vx = 0.
  function integrate() {
    var decay = velocityDecay;
    for (var i = 0; i < n; ++i) {
      var b = fixed[i];
      if ((b & 1) === 0) {
        vx[i] *= decay;
        x[i] += vx[i];
      } else {
        x[i] = fx[i];
        vx[i] = 0;
      }
      if ((b & 2) === 0) {
        vy[i] *= decay;
        y[i] += vy[i];
      } else {
        y[i] = fy[i];
        vy[i] = 0;
      }
    }
  }

  function tick(iterations) {
    if (iterations === undefined) iterations = 1;
    if (!(0 < iterations)) return simulation;
    n = nodes.length;
    ensure();
    copyIn();
    for (var k = 0; k < iterations; ++k) {
      alpha += (alphaTarget - alpha) * alphaDecay;
      forces.forEach(function (force) {
        force(alpha, state);
      });
      integrate();
    }
    copyOut();
    return simulation;
  }

  initializeNodes();

  return simulation = {
    tick: tick,
    restart: function () {
      return simulation;
    },
    stop: function () {
      return simulation;
    },
    nodes: function (_) {
      return arguments.length ? (nodes = _, initializeNodes(), simulation) : nodes;
    },
    alpha: function (_) {
      return arguments.length ? (alpha = +_, simulation) : alpha;
    },
    alphaMin: function (_) {
      return arguments.length ? (alphaMin = +_, simulation) : alpha;
    },
    alphaDecay: function (_) {
      return arguments.length ? (alphaDecay = +_, simulation) : +alphaDecay;
    },
    alphaTarget: function (_) {
      return arguments.length ? (alphaTarget = +_, simulation) : alpha;
    },
    velocityDecay: function (_) {
      return arguments.length ? (velocityDecay = 1 - _, simulation) : 1 - velocityDecay;
    },
    randomSource: function (_) {
      return arguments.length ? (random = _, forces.forEach(initializeForce), simulation) : random;
    },
    force: function (name, _) {
      return arguments.length > 1 ? ((_ == null ? forces.delete(name) : forces.set(name, initializeForce(_))), simulation) : forces.get(name);
    },
    on: function () {
      return simulation;
    }
  };
}
