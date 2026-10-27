// Two probes on top of profile-do.js:
//  1. the copyIn/copyOut tax of the drop-in node-object interface;
//  2. traversal in Morton order vs index order (locality), which is what the
//     zig core does. Morton order changes the jiggle draw order, so the probe
//     runs with a no-op random and only measures time.

import {generator} from "../test/parity/scenarios.js";
import {Tree, lcg} from "./do-force.js";

const n = +(process.argv[2] || 50000), reps = +(process.argv[3] || 10);
const r = generator(7);
const nodes = Array.from({length: n}, () => ({}));
const links = Array.from({length: 2 * n}, () => ({source: Math.floor(r() * n), target: Math.floor(r() * n)}));

import * as doF from "./do-force.js";
const sim = doF.forceSimulation(nodes).force("charge", doF.forceManyBody()).force("link", doF.forceLink(links))
    .force("center", doF.forceCenter()).stop();
sim.tick(2);

const x = Float64Array.from(nodes, d => d.x), y = Float64Array.from(nodes, d => d.y);
const vx = new Float64Array(n), vy = new Float64Array(n);

function ms(f) {
  f();
  const t0 = performance.now();
  for (let i = 0; i < reps; ++i) f();
  return (performance.now() - t0) / reps;
}

// 1. copy tax
const copy = () => {
  for (let i = 0; i < n; ++i) {
    const d = nodes[i];
    x[i] = d.x, y[i] = d.y, vx[i] = d.vx, vy[i] = d.vy;
    d.x = x[i], d.y = y[i], d.vx = vx[i], d.vy = vy[i];
  }
};
console.log(`n = ${n}`);
console.log(`copy in + out   ${ms(copy).toFixed(2)} ms`);

// 2. traversal order probe over a built tree
const tree = new Tree();
tree.reserve(n);
tree.build(x, y, n);
const strengths = Float64Array.from(nodes, () => -30);

// accumulate, as in do-force
(function accumulate() {
  const child = tree.child, first = tree.first, count = tree.count, perm = tree.perm;
  const cxs = tree.cxs, cys = tree.cys, value = tree.value;
  for (let c = tree.len - 1; c >= 0; --c) {
    const b = 4 * c;
    let strength = 0;
    if (child[b] >= 0 || child[b + 1] >= 0 || child[b + 2] >= 0 || child[b + 3] >= 0) {
      let weight = 0, sx = 0, sy = 0;
      for (let q = 0; q < 4; ++q) {
        const ch = child[b + q];
        if (ch >= 0) {
          const v = value[ch], w = Math.abs(v);
          if (w) strength += v, weight += w, sx += w * cxs[ch], sy += w * cys[ch];
        }
      }
      cxs[c] = sx / weight;
      cys[c] = sy / weight;
    } else {
      const f = first[c], cnt = count[c];
      const head = perm[f + cnt - 1];
      cxs[c] = x[head];
      cys[c] = y[head];
      for (let t = f + cnt; t > f;) strength += strengths[perm[--t]];
    }
    value[c] = strength;
  }
})();

const noop = () => 0.5;
const alpha = 1, theta2 = 0.81, distanceMin2 = 1, distanceMax2 = Infinity;

function apply(order) {
  const child = tree.child, first = tree.first, count = tree.count, perm = tree.perm;
  const cx0 = tree.cx0, cy0 = tree.cy0, cx1 = tree.cx1, cy1 = tree.cy1;
  const cxs = tree.cxs, cys = tree.cys, value = tree.value;
  const stack = tree.walk;
  const outX = vx, outY = vy;
  for (let p = 0; p < n; ++p) {
    const i = order ? perm[p] : p;
    const nx = x[i], ny = y[i];
    let vx1 = outX[i], vy1 = outY[i];
    let sp = 1;
    stack[0] = tree.root;
    while (sp > 0) {
      const c = stack[--sp];
      const v = value[c];
      if (!v) continue;
      let dx = cxs[c] - nx;
      let dy = cys[c] - ny;
      const w = cx1[c] - cx0[c];
      let l = dx * dx + dy * dy;
      if (w * w / theta2 < l) {
        if (l < distanceMax2) {
          if (dx === 0) dx = noop(), l += dx * dx;
          if (dy === 0) dy = noop(), l += dy * dy;
          if (l < distanceMin2) l = Math.sqrt(distanceMin2 * l);
          vx1 += dx * v * alpha / l;
          vy1 += dy * v * alpha / l;
        }
        continue;
      }
      const b = 4 * c;
      const c0 = child[b], c1 = child[b + 1], c2 = child[b + 2], c3 = child[b + 3];
      if (c0 >= 0 || c1 >= 0 || c2 >= 0 || c3 >= 0) {
        if (c3 >= 0) stack[sp++] = c3;
        if (c2 >= 0) stack[sp++] = c2;
        if (c1 >= 0) stack[sp++] = c1;
        if (c0 >= 0) stack[sp++] = c0;
        continue;
      }
      if (l >= distanceMax2) continue;
      const f = first[c], cnt = count[c];
      const head = perm[f + cnt - 1];
      if (head !== i || cnt > 1) {
        if (dx === 0) dx = noop(), l += dx * dx;
        if (dy === 0) dy = noop(), l += dy * dy;
        if (l < distanceMin2) l = Math.sqrt(distanceMin2 * l);
      }
      for (let t = f + cnt; t > f;) {
        const j = perm[--t];
        if (j !== i) {
          const wj = strengths[j] * alpha / l;
          vx1 += dx * wj;
          vy1 += dy * wj;
        }
      }
    }
    outX[i] = vx1;
    outY[i] = vy1;
  }
}

console.log(`traversal, index order   ${ms(() => apply(0)).toFixed(2)} ms`);
console.log(`traversal, Morton order  ${ms(() => apply(1)).toFixed(2)} ms`);
