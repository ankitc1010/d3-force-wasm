# Can plain JavaScript get d3-force-wasm's speed-up?

**Short answer: most of it.** A data-oriented pure-JS port of this repo's Zig
kernels — same algorithms, same arithmetic, bit-identical output — runs
**1.9–2.9× faster than d3-force**, recovering roughly **two thirds of the
wasm core's speed-up**, and it eliminates the garbage-collection pauses
entirely, which was the point of moving to wasm in the first place. What
remains is a ~1.6× codegen gap that only wasm (or threads) closes.

The theory was: the win comes not from wasm but from keeping the node state
in flat typed arrays and designing the algorithms around them. To test it,
`do-force.js` ports the Zig core back into JavaScript while keeping exactly
the parts that are *not* wasm:

- **Structure of arrays.** `x, y, vx, vy, fx, fy` are `Float64Array`s owned
  by the simulation; node objects are copied in and out once per tick, the
  same contract the wasm facade has. The copy costs ~0.3 ms per tick at
  50,000 nodes — noise.
- **O(n) tree build** (`tree.zig` → JS): d3's `cover` arithmetic, 64-bit
  Morton keys computed with d3's own midpoint test, a stable LSD radix sort,
  cells emitted in preorder over contiguous key ranges. The tree is
  d3-quadtree's, cell for cell — including exact cell bounds and leaf chain
  order — but flat typed arrays instead of a fresh heap of objects per tick.
- **Inlined traversal** (`many_body.zig` → JS): the `visit` callback becomes
  a loop over an explicit stack.
- **Zero allocation per tick.** Every buffer is allocated once and reused.

Because statement order is d3's throughout, the output is *bit-identical* to
d3-force 3.0.0. That is the control that makes the comparison honest: any
speed difference is pure implementation efficiency, not a different
approximation.

## Parity

`parity-do.js` runs do-force and the wasm core side by side with d3-force,
comparing `x, y, vx, vy` of every node with `Object.is` after **every tick**
— the same gate this repo applies to its wasm core:

```
node experiment/parity-do.js 300
✓ default-10 … default-1000, coincident, fixed, nan, scalefree, extreme, clustered
All 13500 tick comparisons bit-identical across do-force, wasm and d3-force.
```

Scenarios cover the benchmark workload at three sizes, fully coincident
points (leaf chains + jiggles), `fx`/`fy`-pinned nodes, NaN coordinates,
preferential-attachment links on empty starts, coordinates near 1e300, and a
clustered mix. The fun part of the coincident case: d3's tree has 3 cells;
an early version of the port produced 67, because the radix sort swaps its
buffers and a stale reference computed the coincident-run boundaries on the
unsorted order. The parity gate caught it immediately.

## Performance

`bench-do.js`, each implementation isolated in its own process (so GC
attribution is exact), Node 26 arm64 Mac, 30 ticks × 3 rounds, minimum;
manyBody + link + center on a random graph with m = 2n links:

| Nodes | d3-force | do (js) | vs d3 | d3-force-wasm | vs d3 |
|---:|---:|---:|---:|---:|---:|
| 1,000 | 2.9 ms | 1.5 ms | **1.9×** | 0.9 ms | **3.1×** |
| 10,000 | 41.6 ms | 16.5 ms | **2.5×** | 11.4 ms | **3.7×** |
| 50,000 | 272.3 ms | 92.9 ms | **2.9×** | 59.8 ms | **4.6×** |

GC pauses during the 90 timed ticks per row (PerformanceObserver, `gc`):

| Nodes | d3-force | do (js) | wasm |
|---:|---:|---:|---:|
| 1,000 | 104 pauses, 18.6 ms | 4 pauses, 0.4 ms | 1 pause, 0.2 ms |
| 10,000 | 483 pauses, 113.1 ms | 2 pauses, 0.3 ms | 0 |
| 50,000 | 2,765 pauses, 726.1 ms | 1 pause, 0.7 ms | 0 |

d3-force triggers a young-generation scavenge every few ticks at 50k nodes —
one every ~9 ticks per simulation in absolute terms, ~0.3 ms each. In Node
that totals ~3% of wall time; in a browser, where the heap is shared with
the page and pauses compete with a 16 ms frame budget, the same allocation
rate is exactly the "stutter" the README describes. The data-oriented JS
version has the same profile as wasm: essentially nothing to collect.

## What moved the needle

`profile-do.js` probes the pieces (50k nodes):

- **Tree build: 26.6 ms/tick (~25%).** The 32 midpoint tests per point
  dominate it; the radix sort is cheap (1.4 ms re-sorting sorted data, since
  passes with a constant byte are skipped).
- **Traversal order matters: ~30%.** Applying forces in Morton order — the
  order the tree's points already sit in — instead of node index order takes
  the traversal from 78 ms to 53 ms, because consecutive nodes then visit
  the same cells. Morton order changes which node draws each jiggle, so
  do-force uses the wasm core's scheme: a first pass abandons any node that
  would draw from `random` (flagged, unwritten, nothing drawn), then the
  flagged nodes rerun in ascending index order, drawing exactly what d3
  draws in d3's order, since nodes that never jiggle never draw. Parity
  holds at 300 ticks.
- **The drop-in tax is noise.** Copying node objects in and out costs
  ~0.3 ms of a 95 ms tick at 50k.

## What is left for wasm

At 50k nodes do-force spends ~1.6× longer than wasm on identical work. Both
run the same loops over the same bytes; the difference is codegen — bounds
checks, register allocation, addressing modes — which no amount of JS
data-orientation removes. Two caveats cut the other way:

- The wasm package's **threads** multiply its lead (31–42× over d3 at
  100k in the README). The same trick is available to a JS core via
  SharedArrayBuffer, and the Morton chunking this experiment needed for
  parity is precisely what makes such a split safe.
- This port reproduces d3's **exact** algorithm. The wasm package's fast
  mode (O(n) FMM, uniform grid) is a different tier entirely.

## Running it

```sh
node experiment/parity-do.js 300       # bitwise gate vs d3-force and wasm
node experiment/bench-do.js            # table above, one process per lib
RUN_ONLY=do node experiment/bench-do.js 50000 30   # one implementation alone
node experiment/profile-do.js 50000    # build/traversal/copy decomposition
```
