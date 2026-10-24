// SHA-256 of the nodes' x, y, vx, vy as float64 bit patterns, so a digest
// changes on any differing bit, signed zeros and NaN payloads included.

import {createHash} from "node:crypto";

export function digest(nodes) {
  const n = nodes.length, a = new Float64Array(4 * n);
  for (let i = 0; i < n; ++i) {
    const d = nodes[i];
    a[4 * i] = d.x, a[4 * i + 1] = d.y, a[4 * i + 2] = d.vx, a[4 * i + 3] = d.vy;
  }
  return createHash("sha256").update(new Uint8Array(a.buffer)).digest("hex");
}
