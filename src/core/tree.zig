//! O(n) region quadtree, structurally identical to the one d3-quadtree's
//! `addAll` produces (TRD, Zig core design: "Tree build, O(n), both modes").
//!
//! d3's tree is a function of the extent and the point set alone: a quadrant
//! is a leaf exactly when every point in it is coincident (`===` on x and y),
//! and internal otherwise. So instead of inserting, the build
//!   1. reproduces `addAll`'s bounding box and `cover` arithmetic for the extent,
//!   2. quantises each point to a 64-bit Morton key by walking 32 levels with
//!      d3's own midpoint test (`x >= (x0 + x1) / 2`), so every bit is the
//!      branch d3 would take,
//!   3. LSD radix sorts the keys (stable, so equal keys stay in index order),
//!   4. emits cells in preorder over contiguous key ranges.
//! Points still unseparated after 32 levels continue with the same midpoint
//! test on their sub-range (stable partition), so the tree matches d3 at every
//! depth. Cells are numbered in preorder with children in 0..3 order, which is
//! exactly d3-quadtree's `visit` order.
//!
//! Every step runs on the thread pool (TRD 3, Kernels: "Exact mode"). Steps 1
//! to 3 split by point. Step 4 splits by subtree: the main thread walks the
//! top of the tree down to the cut (TRD 3, "The cut"), each job subtree counts
//! its cells, and with those counts every cell is written at the index the
//! serial preorder walk would give it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pool = @import("pool.zig");
const sort = @import("sort.zig");

pub const NONE: u32 = 0xffff_ffff;
pub const KEY_LEVELS = 32;
/// d3 itself loops forever once two distinct points share a cell whose
/// bounds are adjacent floats; the build stops splitting there instead.
const MAX_DEPTH = 2200;
/// Points per chunk of the key pass, whose 32 midpoint tests make it the
/// costly one; the cheap box pass takes BOX_ROWS chunks per task and the run
/// boundaries RUN_CHUNK points, so below 16k points they run inline.
const CHUNK: u32 = 1024;
const BOX_ROWS: u32 = 16;
const RUN_CHUNK: u32 = 16384;

/// One quadtree cell. `first`/`count` delimit its points in `perm`; a leaf's
/// points are all coincident and its d3 chain order is `perm[first + count - 1]`
/// down to `perm[first]` (d3 prepends on insert). Bounds are the exact
/// `x0, y0, x1, y1` d3 passes to `visit` callbacks. `x`, `y`, `value`, `r` are
/// per-force summaries filled by the force kernels.
pub const Cell = extern struct {
    child: [4]u32,
    first: u32,
    count: u32,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    x: f64 = 0,
    y: f64 = 0,
    value: f64 = 0,
    r: f64 = 0,

    pub fn isLeaf(c: *const Cell) bool {
        return c.child[0] == NONE and c.child[1] == NONE and c.child[2] == NONE and c.child[3] == NONE;
    }
};

const Frame = struct {
    lo: u32,
    hi: u32,
    depth: u32,
    /// The parent's item index in the top walk, its cell index in a job.
    parent: u32,
    slot: u32,
    sorted: bool,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
};

/// A cell of the top walk, or the root of a job subtree (`job` != NONE).
const Item = struct { f: Frame, job: u32, index: u32 = 0 };

/// A subtree emitted by one job: `cells` cells from `base`, preorder.
pub const Job = struct { f: Frame, base: u32 = 0, cells: u32 = 0, depth: u32 = 0, overflow: bool = false };

/// One chunk of nodes: its bounding box and point count, then the first
/// perm and rest positions it writes; for run boundaries, its count and base.
const Row = struct { x0: f64, y0: f64, x1: f64, y1: f64, count: u32, first: u32 = 0, rest: u32 = 0 };

pub const Tree = struct {
    /// Extent after `cover`, as `tree._x0, _y0, _x1, _y1`; NaN when empty.
    extent: [4]f64 = .{ std.math.nan(f64), std.math.nan(f64), std.math.nan(f64), std.math.nan(f64) },
    cells: []Cell = &.{},
    len: u32 = 0,
    root: u32 = NONE,
    /// Number of points in the tree (nodes with NaN x or y are left out, as in d3).
    m: u32 = 0,
    perm: []u32 = &.{},
    perm_tmp: []u32 = &.{},
    keys: []u64 = &.{},
    keys_tmp: []u64 = &.{},
    /// diff[k] = number of positions in perm[1..k] that differ from their predecessor.
    diff: []u32 = &.{},
    /// Nodes with a NaN coordinate, in index order: n − m of them.
    rest: []u32 = &.{},
    cap: u32 = 0,
    /// The deepest cell's depth (root 0), so walks can size their stacks.
    depth: u32 = 0,
    /// Job subtrees and top cells (preorder) of the last build, for kernels
    /// that sweep the tree by subtree (TRD 3, "The cut").
    jobs: []Job = &.{},
    n_jobs: u32 = 0,
    tops: []u32 = &.{},
    n_tops: u32 = 0,
    /// Stacks of depth-first walks, one row per thread: `walk_stride` cell
    /// indices for the force kernels, `frame_cap` frames for the build.
    walk: []u32 = &.{},
    walk_stride: u32 = 0,
    frames: []Frame = &.{},
    frame_cap: u32 = 0,
    /// Build scratch: the main thread's top-walk stack and items, per-chunk
    /// rows and radix histograms.
    stack: []Frame = &.{},
    items: []Item = &.{},
    n_items: u32 = 0,
    rows: []Row = &.{},
    hist: []u32 = &.{},

    pub fn deinit(t: *Tree, a: Allocator) void {
        inline for (.{ "cells", "perm", "perm_tmp", "keys", "keys_tmp", "diff", "rest", "jobs", "tops", "walk", "frames", "stack", "items", "rows", "hist" }) |name| a.free(@field(t, name));
        t.* = .{};
    }

    fn reserve(t: *Tree, a: Allocator, n: u32) !void {
        const rows = pool.chunks(n, pool.chunkSize(CHUNK)) + 1;
        if (t.rows.len < rows) t.rows = try a.realloc(t.rows, rows);
        if (n <= t.cap) return;
        t.perm = try a.realloc(t.perm, n);
        t.perm_tmp = try a.realloc(t.perm_tmp, n);
        t.keys = try a.realloc(t.keys, n);
        t.keys_tmp = try a.realloc(t.keys_tmp, n);
        t.diff = try a.realloc(t.diff, n);
        t.rest = try a.realloc(t.rest, n);
        const cells = 2 * @as(usize, n) + 64;
        if (t.cells.len < cells) t.cells = try a.realloc(t.cells, cells);
        if (t.stack.len < 256) t.stack = try a.realloc(t.stack, 256);
        t.cap = n;
    }

    fn cover(t: *Tree, x: f64, y: f64) void {
        if (std.math.isNan(x) or std.math.isNan(y)) return;
        var x0 = t.extent[0];
        var y0 = t.extent[1];
        var x1 = t.extent[2];
        var y1 = t.extent[3];
        if (std.math.isNan(x0)) {
            x0 = @floor(x);
            x1 = x0 + 1;
            y0 = @floor(y);
            y1 = y0 + 1;
        } else {
            var z = x1 - x0;
            if (z == 0 or z != z) z = 1; // `x1 - x0 || 1`
            var guard: u32 = 0;
            while ((x0 > x or x >= x1 or y0 > y or y >= y1) and guard < MAX_DEPTH) : (guard += 1) {
                const i = @as(u2, @intFromBool(y < y0)) << 1 | @intFromBool(x < x0);
                z *= 2;
                switch (i) {
                    0 => {
                        x1 = x0 + z;
                        y1 = y0 + z;
                    },
                    1 => {
                        x0 = x1 - z;
                        y1 = y0 + z;
                    },
                    2 => {
                        x1 = x0 + z;
                        y0 = y1 - z;
                    },
                    3 => {
                        x0 = x1 - z;
                        y0 = y1 - z;
                    },
                }
            }
        }
        t.extent = .{ x0, y0, x1, y1 };
    }

    /// Builds the tree over `xs[i], ys[i]` for i < xs.len. Nodes whose x or y is
    /// NaN are skipped, exactly as `addAll` skips them.
    pub fn build(t: *Tree, a: Allocator, xs: []const f64, ys: []const f64) !void {
        if (!try t.prepare(a, xs, ys)) return;
        try t.runBoundaries(xs, ys);
        try t.emit(a, xs, ys);
        try t.reserveWalks(a);
    }

    /// Sizes the per-thread walk stacks for the tree just built: a
    /// depth-first walk that pushes up to four children holds at most
    /// 3 · depth + 1 cells.
    pub fn reserveWalks(t: *Tree, a: Allocator) !void {
        t.walk_stride = 3 * t.depth + 4;
        const need = @as(usize, pool.threads()) * t.walk_stride;
        if (t.walk.len < need) t.walk = try a.realloc(t.walk, need);
    }

    /// One thread's walk stack.
    pub fn walkStack(t: *const Tree, tid: u32) []u32 {
        return t.walk[tid * t.walk_stride ..][0..t.walk_stride];
    }

    // Steps 1 and 2: bounding box, compaction, keys.

    const Prep = struct {
        t: *Tree,
        xs: []const f64,
        ys: []const f64,
        size: u32,
        fast_scale: f64 = 0,

        /// Rows [BOX_ROWS · task, BOX_ROWS · (task + 1)) of the box pass.
        fn boxes(p: *const Prep, task: u32, _: u32) void {
            const rows = pool.chunks(@intCast(p.xs.len), p.size);
            const r = pool.range(rows, BOX_ROWS, task);
            for (r.lo..r.hi) |c| p.box(@intCast(c));
        }

        /// Bounding box with addAll's comparisons (first of -0 / 0 wins) and
        /// the count of points without a NaN coordinate.
        fn box(p: *const Prep, c: u32) void {
            const r = pool.range(@intCast(p.xs.len), p.size, c);
            var bx0 = std.math.inf(f64);
            var by0 = std.math.inf(f64);
            var bx1 = -std.math.inf(f64);
            var by1 = -std.math.inf(f64);
            var m: u32 = 0;
            for (r.lo..r.hi) |i| {
                const x = p.xs[i];
                const y = p.ys[i];
                if (x != x or y != y) continue;
                if (x < bx0) bx0 = x;
                if (x > bx1) bx1 = x;
                if (y < by0) by0 = y;
                if (y > by1) by1 = y;
                m += 1;
            }
            p.t.rows[c] = .{ .x0 = bx0, .y0 = by0, .x1 = bx1, .y1 = by1, .count = m };
        }

        /// Writes the chunk's points to perm (and the rest to `rest`) at the
        /// offsets the main thread put in its row, with d3's Morton keys.
        fn exactKeys(p: *const Prep, c: u32, _: u32) void {
            const t = p.t;
            const r = pool.range(@intCast(p.xs.len), p.size, c);
            var k = t.rows[c].first;
            var rest = t.rows[c].rest;
            const e = t.extent;
            for (r.lo..r.hi) |i| {
                const x = p.xs[i];
                const y = p.ys[i];
                if (x != x or y != y) {
                    t.rest[rest] = @intCast(i);
                    rest += 1;
                    continue;
                }
                var x0 = e[0];
                var y0 = e[1];
                var x1 = e[2];
                var y1 = e[3];
                var key: u64 = 0;
                inline for (0..KEY_LEVELS) |_| {
                    const xm = (x0 + x1) / 2;
                    const ym = (y0 + y1) / 2;
                    const right = x >= xm;
                    if (right) x0 = xm else x1 = xm;
                    const bottom = y >= ym;
                    if (bottom) y0 = ym else y1 = ym;
                    key = key << 2 | @as(u64, @intFromBool(bottom)) << 1 | @intFromBool(right);
                }
                t.perm[k] = @intCast(i);
                t.keys[k] = key;
                k += 1;
            }
        }

        /// The fast tree's keys: 16 quantised bits per axis.
        fn fastKeys(p: *const Prep, c: u32, _: u32) void {
            const t = p.t;
            const r = pool.range(@intCast(p.xs.len), p.size, c);
            var k = t.rows[c].first;
            var rest = t.rows[c].rest;
            const bx0 = t.extent[0];
            const by0 = t.extent[1];
            const scale = p.fast_scale;
            for (r.lo..r.hi) |i| {
                const x = p.xs[i];
                const y = p.ys[i];
                if (x != x or y != y) {
                    t.rest[rest] = @intCast(i);
                    rest += 1;
                    continue;
                }
                const qx: u32 = @intFromFloat(@min(65535, @floor((x - bx0) * scale)));
                const qy: u32 = @intFromFloat(@min(65535, @floor((y - by0) * scale)));
                t.perm[k] = @intCast(i);
                t.keys[k] = spread16(qx) | spread16(qy) << 1;
                k += 1;
            }
        }
    };

    /// Runs the box pass and combines its rows in chunk order with the same
    /// comparisons, so the box is the serial scan's, signed zeros included,
    /// and sets each row's first perm and rest positions for the key pass.
    /// Returns the box, or null when no point has finite coordinates.
    fn box(t: *Tree, p: *const Prep, n_chunks: u32) !?[4]f64 {
        try pool.parallelFor(p, pool.chunks(n_chunks, BOX_ROWS), Prep.boxes);
        var bx0 = std.math.inf(f64);
        var by0 = std.math.inf(f64);
        var bx1 = -std.math.inf(f64);
        var by1 = -std.math.inf(f64);
        var m: u32 = 0;
        var rest: u32 = 0;
        for (t.rows[0..n_chunks], 0..) |*row, c| {
            if (row.count > 0) {
                if (row.x0 < bx0) bx0 = row.x0;
                if (row.x1 > bx1) bx1 = row.x1;
                if (row.y0 < by0) by0 = row.y0;
                if (row.y1 > by1) by1 = row.y1;
            }
            const r = pool.range(@intCast(p.xs.len), p.size, @intCast(c));
            row.first = m;
            row.rest = rest;
            m += row.count;
            rest += (r.hi - r.lo) - row.count;
        }
        t.m = m;
        if (bx0 > bx1 or by0 > by1) return null;
        return .{ bx0, by0, bx1, by1 };
    }

    /// Fast-mode variant of `prepare` (TRD 2, fast tree): a square extent over
    /// the bounding box, 16 quantised bits per axis interleaved into a 32-bit
    /// Morton key, so the radix sort runs four passes. The midpoint semantics
    /// of d3-quadtree are not needed for the FMM tree.
    pub fn prepareFast(t: *Tree, a: Allocator, xs: []const f64, ys: []const f64) !bool {
        const n: u32 = @intCast(xs.len);
        try t.reserve(a, n);
        const nan = std.math.nan(f64);
        t.extent = .{ nan, nan, nan, nan };
        t.len = 0;
        t.root = NONE;
        const size = pool.chunkSize(CHUNK);
        const n_chunks = pool.chunks(n, size);
        var p = Prep{ .t = t, .xs = xs, .ys = ys, .size = size };
        const b = try t.box(&p, n_chunks) orelse return false;
        var side = @max(b[2] - b[0], b[3] - b[1]);
        if (!(side > 0)) side = 1;
        t.extent = .{ b[0], b[1], b[0] + side, b[1] + side };
        p.fast_scale = 65536.0 / side;
        try pool.parallelFor(&p, n_chunks, Prep.fastKeys);
        try sort.sort(u64, a, &t.keys, &t.perm, &t.keys_tmp, &t.perm_tmp, &t.hist, t.m, 4);
        return true;
    }

    /// The shared first half of a build (TRD 2: the fast tree comes from the
    /// same Morton keys and radix sort): extent by `addAll`'s cover, keys by
    /// d3's midpoint test, stable radix sort of `keys` carrying `perm`. Leaves
    /// `perm[0..m]` in Morton order with `keys[0..m]` sorted alongside and the
    /// cell arrays untouched. Returns false when no point has finite coordinates.
    pub fn prepare(t: *Tree, a: Allocator, xs: []const f64, ys: []const f64) !bool {
        const n: u32 = @intCast(xs.len);
        try t.reserve(a, n);
        const nan = std.math.nan(f64);
        t.extent = .{ nan, nan, nan, nan };
        t.len = 0;
        t.root = NONE;
        t.m = 0;
        const size = pool.chunkSize(CHUNK);
        const n_chunks = pool.chunks(n, size);
        const p = Prep{ .t = t, .xs = xs, .ys = ys, .size = size };
        const b = try t.box(&p, n_chunks) orelse return false;
        t.cover(b[0], b[1]);
        t.cover(b[2], b[3]);
        try pool.parallelFor(&p, n_chunks, Prep.exactKeys);
        try sort.sort(u64, a, &t.keys, &t.perm, &t.keys_tmp, &t.perm_tmp, &t.hist, t.m, 8);
        return true;
    }

    // Step 3b: run boundaries between distinct positions, in sorted order.

    const Runs = struct {
        t: *Tree,
        xs: []const f64,
        ys: []const f64,
        size: u32,

        inline fn differs(r: *const Runs, k: usize) u32 {
            const p = r.t.perm[k];
            const q = r.t.perm[k - 1];
            return @intFromBool(r.xs[p] != r.xs[q] or r.ys[p] != r.ys[q]);
        }

        fn count(r: *const Runs, c: u32, _: u32) void {
            const g = pool.range(r.t.m, r.size, c);
            var d: u32 = 0;
            for (@max(g.lo, 1)..g.hi) |k| d += r.differs(k);
            r.t.rows[c].count = d;
        }

        fn write(r: *const Runs, c: u32, _: u32) void {
            const g = pool.range(r.t.m, r.size, c);
            var d = r.t.rows[c].first;
            if (g.lo == 0) r.t.diff[0] = 0;
            for (@max(g.lo, 1)..g.hi) |k| {
                d += r.differs(k);
                r.t.diff[k] = d;
            }
        }
    };

    fn runBoundaries(t: *Tree, xs: []const f64, ys: []const f64) !void {
        const size = pool.chunkSize(RUN_CHUNK);
        const n_chunks = pool.chunks(t.m, size);
        const r = Runs{ .t = t, .xs = xs, .ys = ys, .size = size };
        try pool.parallelFor(&r, n_chunks, Runs.count);
        var base: u32 = 0;
        for (t.rows[0..n_chunks]) |*row| {
            row.first = base;
            base += row.count;
        }
        try pool.parallelFor(&r, n_chunks, Runs.write);
    }

    // Step 4: cells.

    fn allSame(t: *const Tree, f: Frame, xs: []const f64, ys: []const f64) bool {
        if (f.sorted) return t.diff[f.hi - 1] == t.diff[f.lo];
        const p0 = t.perm[f.lo];
        for (t.perm[f.lo + 1 .. f.hi]) |p| {
            if (xs[p] != xs[p0] or ys[p] != ys[p0]) return false;
        }
        return true;
    }

    /// The four child ranges of f, in split[0..5]. Below the key resolution
    /// it stably partitions perm[f.lo..f.hi] by d3's midpoint test, which is
    /// idempotent, so a subtree can be walked twice.
    noinline fn split(t: *Tree, f: Frame, xs: []const f64, ys: []const f64, out: *[5]u32) void {
        out[0] = f.lo;
        out[4] = f.hi;
        if (f.sorted and f.depth < KEY_LEVELS) {
            // Children are contiguous key ranges; find the three boundaries.
            const shift: u6 = @intCast(62 - 2 * f.depth);
            var k = f.lo;
            for (1..4) |q| {
                while (k < f.hi and (t.keys[k] >> shift & 3) < q) k += 1;
                out[q] = k;
            }
        } else {
            const xm = (f.x0 + f.x1) / 2;
            const ym = (f.y0 + f.y1) / 2;
            var counts = [4]u32{ 0, 0, 0, 0 };
            for (t.perm[f.lo..f.hi]) |p| counts[quadrant(xs[p], ys[p], xm, ym)] += 1;
            var off: [4]u32 = undefined;
            var sum = f.lo;
            for (0..4) |q| {
                off[q] = sum;
                out[q] = sum;
                sum += counts[q];
            }
            for (t.perm[f.lo..f.hi]) |p| {
                const q = quadrant(xs[p], ys[p], xm, ym);
                t.perm_tmp[off[q]] = p;
                off[q] += 1;
            }
            @memcpy(t.perm[f.lo..f.hi], t.perm_tmp[f.lo..f.hi]);
        }
    }

    /// The child frame of f in quadrant q over keys [lo, hi).
    fn child(f: Frame, q: u32, lo: u32, hi: u32, parent: u32) Frame {
        const xm = (f.x0 + f.x1) / 2;
        const ym = (f.y0 + f.y1) / 2;
        const right = q & 1 != 0;
        const bottom = q & 2 != 0;
        return .{
            .lo = lo,
            .hi = hi,
            .depth = f.depth + 1,
            .parent = parent,
            .slot = q,
            .sorted = f.sorted and f.depth < KEY_LEVELS,
            .x0 = if (right) xm else f.x0,
            .y0 = if (bottom) ym else f.y0,
            .x1 = if (right) f.x1 else xm,
            .y1 = if (bottom) f.y1 else ym,
        };
    }

    fn leafCell(f: Frame) Cell {
        return .{ .child = .{ NONE, NONE, NONE, NONE }, .first = f.lo, .count = f.hi - f.lo, .x0 = f.x0, .y0 = f.y0, .x1 = f.x1, .y1 = f.y1 };
    }

    const Emit = struct {
        t: *Tree,
        xs: []const f64,
        ys: []const f64,

        /// Walks job j's subtree depth first, exactly as the serial build
        /// would: counts its cells and depth, or with `write` emits them from
        /// its base. A full stack marks the job for a rerun.
        fn walk(e: *const Emit, write: bool, j: u32, tid: u32) void {
            const t = e.t;
            const job = &t.jobs[j];
            const stack = t.frames[tid * t.frame_cap ..][0..t.frame_cap];
            var sp: usize = 1;
            stack[0] = job.f;
            stack[0].parent = NONE;
            var idx = job.base;
            var depth: u32 = 0;
            while (sp > 0) {
                sp -= 1;
                const f = stack[sp];
                if (write) {
                    t.cells[idx] = leafCell(f);
                    if (f.parent != NONE) t.cells[f.parent].child[f.slot] = idx;
                }
                const me = idx;
                idx += 1;
                depth = @max(depth, f.depth);
                if (f.depth >= MAX_DEPTH or t.allSame(f, e.xs, e.ys)) continue;
                var sp5: [5]u32 = undefined;
                t.split(f, e.xs, e.ys, &sp5);
                var q: u32 = 4;
                while (q > 0) {
                    q -= 1;
                    if (sp5[q] == sp5[q + 1]) continue;
                    if (sp == stack.len) {
                        job.overflow = true;
                        return;
                    }
                    stack[sp] = child(f, q, sp5[q], sp5[q + 1], me);
                    sp += 1;
                }
            }
            job.cells = idx - job.base;
            job.depth = depth;
        }

        fn count(e: *const Emit, j: u32, tid: u32) void {
            e.walk(false, j, tid);
        }

        fn emit(e: *const Emit, j: u32, tid: u32) void {
            e.walk(true, j, tid);
        }
    };

    fn push(t: *Tree, a: Allocator, sp: *usize, f: Frame) !void {
        if (sp.* == t.stack.len) t.stack = try a.realloc(t.stack, t.stack.len * 2);
        t.stack[sp.*] = f;
        sp.* += 1;
    }

    fn addItem(t: *Tree, a: Allocator, item: Item) !void {
        if (t.n_items == t.items.len) t.items = try a.realloc(t.items, @max(64, 2 * t.items.len));
        t.items[t.n_items] = item;
        t.n_items += 1;
    }

    fn emit(t: *Tree, a: Allocator, xs: []const f64, ys: []const f64) !void {
        const limit = pool.cutLimit(t.m);
        const e = t.extent;

        // The top walk, on the main thread: the serial build's preorder walk,
        // stopped at subtrees of at most `limit` points, which become jobs.
        t.n_items = 0;
        t.n_jobs = 0;
        var depth: u32 = 0;
        var sp: usize = 0;
        try t.push(a, &sp, .{ .lo = 0, .hi = t.m, .depth = 0, .parent = NONE, .slot = 0, .sorted = true, .x0 = e[0], .y0 = e[1], .x1 = e[2], .y1 = e[3] });
        while (sp > 0) {
            sp -= 1;
            const f = t.stack[sp];
            if (f.hi - f.lo <= limit) {
                if (t.n_jobs == t.jobs.len) t.jobs = try a.realloc(t.jobs, @max(64, 2 * t.jobs.len));
                t.jobs[t.n_jobs] = .{ .f = f };
                try t.addItem(a, .{ .f = f, .job = t.n_jobs });
                t.n_jobs += 1;
                continue;
            }
            try t.addItem(a, .{ .f = f, .job = NONE });
            const it = t.n_items - 1;
            depth = @max(depth, f.depth);
            if (f.depth >= MAX_DEPTH or t.allSame(f, xs, ys)) continue;
            var sp5: [5]u32 = undefined;
            t.split(f, xs, ys, &sp5);
            var q: u32 = 4;
            while (q > 0) {
                q -= 1;
                if (sp5[q] == sp5[q + 1]) continue;
                try t.push(a, &sp, child(f, q, sp5[q], sp5[q + 1], it));
            }
        }

        // Count each job's cells, growing the walk stacks until none overflows.
        const em = Emit{ .t = t, .xs = xs, .ys = ys };
        if (t.frame_cap == 0) t.frame_cap = 256;
        while (true) {
            const need = @as(usize, pool.threads()) * t.frame_cap;
            if (t.frames.len < need) t.frames = try a.realloc(t.frames, need);
            for (t.jobs[0..t.n_jobs]) |*j| j.overflow = false;
            try pool.parallelFor(&em, t.n_jobs, Emit.count);
            var overflow = false;
            for (t.jobs[0..t.n_jobs]) |j| overflow = overflow or j.overflow;
            if (!overflow) break;
            t.frame_cap *= 4;
        }

        // Indices: top cells and job subtrees interleave in preorder.
        var next: u32 = 0;
        if (t.tops.len < t.n_items) t.tops = try a.realloc(t.tops, t.items.len);
        t.n_tops = 0;
        for (t.items[0..t.n_items]) |*item| {
            item.index = next;
            if (item.job == NONE) {
                next += 1;
                t.tops[t.n_tops] = item.index;
                t.n_tops += 1;
            } else {
                const j = &t.jobs[item.job];
                j.base = next;
                next += j.cells;
                depth = @max(depth, j.depth);
            }
        }
        if (t.cells.len < next) t.cells = try a.realloc(t.cells, next);
        for (t.items[0..t.n_items]) |item| {
            if (item.job == NONE) t.cells[item.index] = leafCell(item.f);
            if (item.f.parent != NONE) t.cells[t.items[item.f.parent].index].child[item.f.slot] = item.index;
        }
        t.root = 0;
        t.len = next;
        t.depth = depth;
        try pool.parallelFor(&em, t.n_jobs, Emit.emit);
    }

    /// Writes cell indices in the order d3-quadtree calls back: `visit` (preorder,
    /// children 0..3, from a stack pushed 3..0) or `visitAfter` (post-order,
    /// children 0..3). `out` must hold `len` entries.
    pub fn order(t: *Tree, a: Allocator, after: bool, out: []u32) !void {
        if (t.root == NONE) return;
        var stack = try a.alloc(u32, @max(t.len, 1));
        defer a.free(stack);
        var sp: usize = 0;
        var w: usize = 0;
        stack[sp] = t.root;
        sp += 1;
        while (sp > 0) {
            sp -= 1;
            const c = stack[sp];
            out[w] = c;
            w += 1;
            const ch = t.cells[c].child;
            if (after) {
                for (0..4) |i| if (ch[i] != NONE) {
                    stack[sp] = ch[i];
                    sp += 1;
                };
            } else {
                var i: usize = 4;
                while (i > 0) {
                    i -= 1;
                    if (ch[i] != NONE) {
                        stack[sp] = ch[i];
                        sp += 1;
                    }
                }
            }
        }
        // visitAfter calls back in reverse of the order it collected.
        if (after) std.mem.reverse(u32, out[0..w]);
    }
};

/// Spreads the low 16 bits of `v` to the even bit positions of a u32.
inline fn spread16(v: u32) u64 {
    var x: u64 = v & 0xFFFF;
    x = (x | (x << 8)) & 0x00FF00FF;
    x = (x | (x << 4)) & 0x0F0F0F0F;
    x = (x | (x << 2)) & 0x33333333;
    x = (x | (x << 1)) & 0x55555555;
    return x;
}

inline fn quadrant(x: f64, y: f64, xm: f64, ym: f64) u2 {
    return @as(u2, @intFromBool(y >= ym)) << 1 | @intFromBool(x >= xm);
}
