# d3-force-wasm

A drop-in replacement for [d3-force](https://github.com/d3/d3-force) v3 with a WebAssembly core written in Zig. It has the same API, gives the **same results to the last bit**, and runs about **5× faster** than d3-force on a single thread.

```diff
- import {forceSimulation, forceManyBody, forceLink, forceCenter} from "d3-force";
+ import {forceSimulation, forceManyBody, forceLink, forceCenter} from "d3-force-wasm";
```

Nothing else in your code changes. Nodes and links are still your own objects, mutated in place, and accessors, events, custom forces, `fx`/`fy` and `randomSource` all behave exactly as they do in d3-force.

## Why

d3-force spends most of each tick on its Barnes–Hut quadtree. That means a fresh tree of JS objects every tick, pointer-chasing through it, and a callback per visited cell per node. Above a few thousand nodes, those allocations also cause garbage-collection pauses that show up as stutter.

d3-force-wasm keeps d3's arithmetic and changes everything around it:

- **O(n) tree build.** A Morton-key radix sort replaces d3-quadtree's incremental insertion, and it produces the identical tree, including cell bounds, leaf order and visit order.
- **No per-tick allocation.** Positions, velocities and the tree live in flat typed arrays in wasm memory and are reused every tick.
- **Inlined traversal.** The `visit` callbacks become a plain loop over an index stack.
- **One boundary crossing per tick.** Node fields are copied in once, every built-in force runs inside wasm, and results are copied out once.

## Performance

Milliseconds per tick with forceManyBody + forceLink + forceCenter on a random graph with m = 2n links. Measured with Node 22 on an arm64 phone (Vivo X200), single thread, 100 ticks after warm-up:

| Nodes | d3-force | d3-force-wasm | Speed-up |
|---:|---:|---:|---:|
| 1,000 | 5.6 ms | 1.2 ms | **4.8×** |
| 10,000 | 73 ms | 14 ms | **5.4×** |
| 10,000 + forceCollide | 101 ms | 20 ms | **5.1×** |
| 50,000 | 522 ms | 98 ms | **5.3×** |

To see it in your own browser, open the **[live demo](https://ankitc1010.github.io/d3-force-wasm/)**.

## Bit-exact by design

Given the same inputs and the same random source, every tick produces the same `f64` positions and velocities as d3-force 3.0.0. That rests on a few rules:

- **Only correctly rounded operations** run in the core: `+`, `−`, `×`, `÷` and `sqrt` give identical results in JavaScript and wasm on every engine. The layout steps that use `cos` and `sin` (the phyllotaxis start positions) stay in JS.
- **The same operations in the same order.** Every kernel is a line-by-line port of d3's code, with strict float mode. There is no reassociation, no fused multiply-add, and no summation split across SIMD lanes.
- **The same tree.** The O(n) build reproduces d3-quadtree's cells exactly, so every sum sees the same operands in the same order.
- **The same random stream.** Jiggle calls the force's own `random` function at exactly the moment d3 does. That holds for the default LCG and for any `randomSource` you supply.

The test suite enforces this. A parity harness runs d3-force and d3-force-wasm side by side and compares `x`, `y`, `vx`, `vy` with `Object.is` after **every tick**. It covers 32 scenarios × 50 seeds × 300 ticks: every force alone and combined, accessors as functions, NaN accessors, coincident and near-duplicate points, coordinates near 1e300 and at infinity, exact Barnes–Hut ties, `fx`/`fy` toggling, custom forces between native ones, resizing `nodes()`, and custom random sources. d3-force's own test suite also runs unchanged.

## Install

```sh
npm install d3-force-wasm
```

There are no runtime dependencies. The wasm binary is inlined in the package, so there is no `.wasm` file to serve and no bundler plugin to configure.

**TypeScript:** the API is d3-force's, so the types are too. Install `@types/d3-force` alongside it:

```sh
npm install --save-dev @types/d3-force
```

### Using the `d3` umbrella package

If you import everything from `d3`, alias `d3-force` in your bundler. The export names are identical, so this is a configuration change only:

```js
// vite.config.js
export default {resolve: {alias: {"d3-force": "d3-force-wasm"}}};
```

```js
// webpack.config.js
module.exports = {resolve: {alias: {"d3-force": "d3-force-wasm"}}};
```

## Usage

The API is [d3-force's](https://d3js.org/d3-force), unchanged:

```js
import {forceSimulation, forceManyBody, forceLink, forceCenter} from "d3-force-wasm";

const simulation = forceSimulation(nodes)
    .force("charge", forceManyBody())
    .force("link", forceLink(links).id((d) => d.id))
    .force("center", forceCenter(width / 2, height / 2))
    .on("tick", render);
```

Exports: `forceSimulation`, `forceCenter`, `forceCollide`, `forceLink`, `forceManyBody`, `forceRadial`, `forceX`, `forceY`.

## Fast mode

Exact mode reproduces d3-force bit for bit, and that also fixes its algorithm: Barnes–Hut is O(n log n). For large graphs you can opt into **fast mode**, which keeps the same forces and parameters but computes them in O(n):

```js
const simulation = forceSimulation(nodes)
    .precision("fast")   // or .precision("fast", {order: 12, opening: 2}) for more accuracy
    .force("charge", forceManyBody())
    .force("link", forceLink(links))
    .force("center", forceCenter());
```

- **manyBody** becomes a fast multipole method. At the defaults (`order: 8`, `opening: 1.5`) its RMS error against the true n-body sum is about 1e-6, two orders of magnitude *closer* to the exact sum than d3's θ = 0.9 Barnes–Hut approximation. `distanceMin`, `distanceMax` and `theta` keep their meaning; pairs closer than `distanceMin` are always computed directly.
- **collide** becomes a uniform grid and **link** a sweep over adjacency lists. Both apply every pair's push from both ends in one pass (Jacobi) instead of in sequence (Gauss–Seidel), which converges to the same layout; stiff graphs may want `iterations(2)`.
- **What stays the same:** the API, the defaults, `fx`/`fy`, custom forces, and `randomSource` (fast mode draws it once per force per tick to seed its jiggle).
- **What you give up:** bit-identical output. With manyBody + link + center + collide, positions stay within about 1–2% of the layout's extent of d3's over 300 ticks; link + center alone drifts to about 5%, and a dense collide-only packing settles into a different but equally valid arrangement. The many-body force itself is more accurate than d3's; the drift comes from the Jacobi link and collide sweeps and from chaos amplifying tiny differences.
- Below 2,000 nodes fast mode runs the exact kernels, so small simulations stay bit-exact. `precision()` returns the current mode and `precision("exact")` switches back at the next tick.

Milliseconds per tick with forceManyBody + forceLink + forceCenter, m = 2n, Node 22 on the same arm64 phone as the table above, single thread (d3-force at one million nodes is not shown; it takes about 15 s per tick):

| Nodes | d3-force | exact | fast | fast vs d3 | fast vs exact |
|---:|---:|---:|---:|---:|---:|
| 10,000 | 74 ms | 14 ms | 11 ms | **6.7×** | 1.3× |
| 10,000 + forceCollide | 107 ms | 21 ms | 12 ms | **8.7×** | 1.7× |
| 100,000 | 1,248 ms | 242 ms | 120 ms | **10.4×** | 2.0× |
| 1,000,000 | — | 4.8 s | 1.6 s | — | 3.0× |

The gap between the two modes grows with n, as O(n) against O(n log n) should; multithreading, the next milestone, applies to both.

## Compatibility

- **Runtimes:** Node 18+, Deno, Bun, Web Workers, and current Chrome, Firefox and Safari (16.4+).
- **Top-level await in Chrome.** Chrome refuses to compile wasm modules over 4 KB synchronously on the main thread. There, the module waits once for asynchronous instantiation when it's imported. Everywhere else, including Node, it loads synchronously. Your bundler needs to support top-level await: Vite, Rollup, esbuild and webpack 5 all do with an ES2022 target.
- **Custom forces** work as before. Each one costs an O(n) copy of node fields out of wasm before it runs and back in after, so consecutive custom forces cost one round trip.
- **Forces used standalone**, via `force.initialize(nodes, random)` then `force(alpha)`, behave as in d3-force. They expect `node.index` to match the node's position in `nodes`, which the simulation always ensures.
- **Links** must point at nodes in the simulation's `nodes` array, as they do whenever ids are resolved by `forceLink`.

## Demo

**[ankitc1010.github.io/d3-force-wasm](https://ankitc1010.github.io/d3-force-wasm/)** runs the same graph through both libraries side by side and shows the live time per tick, the speed-up, and whether the output is still bit-identical. It loads the published package from npm.

To run it against your local build:

```sh
git clone https://github.com/ankitc1010/d3-force-wasm.git
cd d3-force-wasm
npm install
npm run demo        # needs Zig 0.16.0; then open http://localhost:8080
```

## Development

You need [Zig 0.16.0](https://ziglang.org/download/) and Node 18+.

| Command | What it does |
|---|---|
| `npm run build:wasm` | Builds `core.wasm` and inlines it into `src/core-bytes.js` |
| `npm test` | Tree tests, facade tests, and d3-force's own test suite |
| `npm run test:parity` | Bitwise parity against d3-force (`PARITY_SEEDS=50` for the full gate) |
| `npm run test:zig` | Zig unit tests in ReleaseSafe |
| `npm run demo` | Serves the demo against the local build on http://localhost:8080 |

The layout:

```
src/core/      Zig core: tree build, force kernels, exported ABI
src/*.js       JS facade: d3-force's API, sync layer, dispatch and timer
test/parity/   bitwise parity corpus against d3-force
test/d3/       d3-force's own tests, unchanged except the import path
docs/          side-by-side demo page (GitHub Pages)
```

## Roadmap

0.1 shipped the exact mode on a single thread; 0.2 adds the opt-in O(n) fast mode. Next:

- **Threads**: multi-core execution on cross-origin-isolated pages (and Node), still bit-exact in exact mode and thread-count independent in fast mode.
- **Loader**: feature detection, a UMD build, and a size gate in CI.
- **1.0** once the benchmark targets are met on two machines.

## License

[ISC](LICENSE). d3-force-wasm is a port of [d3-force](https://github.com/d3/d3-force) by Mike Bostock (ISC), whose copyright notice is included in the licence file.
