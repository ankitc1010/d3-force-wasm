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

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const NONE: u32 = 0xffff_ffff;
pub const KEY_LEVELS = 32;
/// d3 itself loops forever once two distinct points share a cell whose
/// bounds are adjacent floats; the build stops splitting there instead.
const MAX_DEPTH = 2200;

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
    parent: u32,
    slot: u32,
    sorted: bool,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
};

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
    stack: []Frame = &.{},
    /// Traversal stack for the force kernels' inlined `visit`; every cell is
    /// pushed at most once per traversal, so `len` entries always suffice.
    vstack: []u32 = &.{},
    cap: u32 = 0,

    pub fn deinit(t: *Tree, a: Allocator) void {
        a.free(t.cells);
        a.free(t.perm);
        a.free(t.perm_tmp);
        a.free(t.keys);
        a.free(t.keys_tmp);
        a.free(t.diff);
        a.free(t.stack);
        a.free(t.vstack);
        t.* = .{};
    }

    fn reserve(t: *Tree, a: Allocator, n: u32) !void {
        if (n <= t.cap) return;
        t.perm = try a.realloc(t.perm, n);
        t.perm_tmp = try a.realloc(t.perm_tmp, n);
        t.keys = try a.realloc(t.keys, n);
        t.keys_tmp = try a.realloc(t.keys_tmp, n);
        t.diff = try a.realloc(t.diff, n);
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

        // Run boundaries between distinct positions, in sorted order.
        const m = t.m;
        t.diff[0] = 0;
        for (1..m) |k| {
            const p = t.perm[k];
            const q = t.perm[k - 1];
            t.diff[k] = t.diff[k - 1] + @intFromBool(xs[p] != xs[q] or ys[p] != ys[q]);
        }

        try t.emit(a, xs, ys);
        if (t.vstack.len < t.len) t.vstack = try a.realloc(t.vstack, t.cells.len);
    }

    /// Fast-mode variant of `prepare` (TRD 2, fast tree): a square extent over
    /// the bounding box, 16 quantised bits per axis interleaved into a 32-bit
    /// Morton key, so the radix sort skips its four constant top bytes. The
    /// midpoint semantics of d3-quadtree are not needed for the FMM tree.
    pub fn prepareFast(t: *Tree, a: Allocator, xs: []const f64, ys: []const f64) !bool {
        const n: u32 = @intCast(xs.len);
        try t.reserve(a, n);
        const nan = std.math.nan(f64);
        t.extent = .{ nan, nan, nan, nan };
        t.len = 0;
        t.root = NONE;
        var bx0 = std.math.inf(f64);
        var by0 = std.math.inf(f64);
        var bx1 = -std.math.inf(f64);
        var by1 = -std.math.inf(f64);
        var m: u32 = 0;
        for (0..n) |i| {
            const x = xs[i];
            const y = ys[i];
            if (x != x or y != y) continue;
            if (x < bx0) bx0 = x;
            if (x > bx1) bx1 = x;
            if (y < by0) by0 = y;
            if (y > by1) by1 = y;
            t.perm[m] = @intCast(i);
            m += 1;
        }
        t.m = m;
        if (bx0 > bx1 or by0 > by1) return false;
        var side = @max(bx1 - bx0, by1 - by0);
        if (!(side > 0)) side = 1;
        t.extent = .{ bx0, by0, bx0 + side, by0 + side };
        const scale = 65536.0 / side;
        for (t.perm[0..m], t.keys[0..m]) |i, *key| {
            const qx: u32 = @intFromFloat(@min(65535, @floor((xs[i] - bx0) * scale)));
            const qy: u32 = @intFromFloat(@min(65535, @floor((ys[i] - by0) * scale)));
            key.* = spread16(qx) | spread16(qy) << 1;
        }
        t.radixSort(m);
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

        // Bounding box with addAll's comparisons (first of -0 / 0 wins).
        var bx0 = std.math.inf(f64);
        var by0 = std.math.inf(f64);
        var bx1 = -std.math.inf(f64);
        var by1 = -std.math.inf(f64);
        var m: u32 = 0;
        for (0..n) |i| {
            const x = xs[i];
            const y = ys[i];
            if (x != x or y != y) continue;
            if (x < bx0) bx0 = x;
            if (x > bx1) bx1 = x;
            if (y < by0) by0 = y;
            if (y > by1) by1 = y;
            t.perm[m] = @intCast(i);
            m += 1;
        }
        t.m = m;
        if (bx0 > bx1 or by0 > by1) return false;
        t.cover(bx0, by0);
        t.cover(bx1, by1);

        // Morton keys by d3's midpoint test.
        const e = t.extent;
        for (t.perm[0..m], t.keys[0..m]) |i, *key| {
            const x = xs[i];
            const y = ys[i];
            var x0 = e[0];
            var y0 = e[1];
            var x1 = e[2];
            var y1 = e[3];
            var k: u64 = 0;
            inline for (0..KEY_LEVELS) |_| {
                const xm = (x0 + x1) / 2;
                const ym = (y0 + y1) / 2;
                const right = x >= xm;
                if (right) x0 = xm else x1 = xm;
                const bottom = y >= ym;
                if (bottom) y0 = ym else y1 = ym;
                k = k << 2 | @as(u64, @intFromBool(bottom)) << 1 | @intFromBool(right);
            }
            key.* = k;
        }

        t.radixSort(m);
        return true;
    }

    /// Stable 8-pass LSD radix sort of keys[0..m] carrying perm; passes whose
    /// byte is constant across all keys are skipped.
    fn radixSort(t: *Tree, m: u32) void {
        var src_k = t.keys;
        var src_p = t.perm;
        var dst_k = t.keys_tmp;
        var dst_p = t.perm_tmp;
        var hist: [256]u32 = undefined;
        var shift: u6 = 0;
        while (true) : (shift += 8) {
            @memset(&hist, 0);
            for (src_k[0..m]) |k| hist[@as(u8, @truncate(k >> shift))] += 1;
            if (hist[@as(u8, @truncate(src_k[0] >> shift))] != m) {
                var sum: u32 = 0;
                for (&hist) |*h| {
                    const c = h.*;
                    h.* = sum;
                    sum += c;
                }
                for (src_k[0..m], src_p[0..m]) |k, p| {
                    const b = @as(u8, @truncate(k >> shift));
                    dst_k[hist[b]] = k;
                    dst_p[hist[b]] = p;
                    hist[b] += 1;
                }
                std.mem.swap([]u64, &src_k, &dst_k);
                std.mem.swap([]u32, &src_p, &dst_p);
            }
            if (shift == 56) break;
        }
        t.keys = src_k;
        t.perm = src_p;
        t.keys_tmp = dst_k;
        t.perm_tmp = dst_p;
    }

    fn allSame(t: *const Tree, f: Frame, xs: []const f64, ys: []const f64) bool {
        if (f.sorted) return t.diff[f.hi - 1] == t.diff[f.lo];
        const p0 = t.perm[f.lo];
        for (t.perm[f.lo + 1 .. f.hi]) |p| {
            if (xs[p] != xs[p0] or ys[p] != ys[p0]) return false;
        }
        return true;
    }

    fn push(t: *Tree, a: Allocator, sp: *usize, f: Frame) !void {
        if (sp.* == t.stack.len) t.stack = try a.realloc(t.stack, t.stack.len * 2);
        t.stack[sp.*] = f;
        sp.* += 1;
    }

    fn emit(t: *Tree, a: Allocator, xs: []const f64, ys: []const f64) !void {
        const e = t.extent;
        var sp: usize = 0;
        try t.push(a, &sp, .{ .lo = 0, .hi = t.m, .depth = 0, .parent = NONE, .slot = 0, .sorted = true, .x0 = e[0], .y0 = e[1], .x1 = e[2], .y1 = e[3] });
        while (sp > 0) {
            sp -= 1;
            const f = t.stack[sp];
            if (t.len == t.cells.len) t.cells = try a.realloc(t.cells, t.cells.len * 2);
            const idx = t.len;
            t.len += 1;
            t.cells[idx] = .{ .child = .{ NONE, NONE, NONE, NONE }, .first = f.lo, .count = f.hi - f.lo, .x0 = f.x0, .y0 = f.y0, .x1 = f.x1, .y1 = f.y1 };
            if (f.parent == NONE) t.root = idx else t.cells[f.parent].child[f.slot] = idx;
            if (f.depth >= MAX_DEPTH or t.allSame(f, xs, ys)) continue;

            const xm = (f.x0 + f.x1) / 2;
            const ym = (f.y0 + f.y1) / 2;
            var split: [5]u32 = undefined;
            split[0] = f.lo;
            split[4] = f.hi;
            if (f.sorted and f.depth < KEY_LEVELS) {
                // Children are contiguous key ranges; find the three boundaries.
                const shift: u6 = @intCast(62 - 2 * f.depth);
                var k = f.lo;
                for (1..4) |q| {
                    while (k < f.hi and (t.keys[k] >> shift & 3) < q) k += 1;
                    split[q] = k;
                }
            } else {
                // Below the key resolution: stable partition by d3's midpoint test.
                var counts = [4]u32{ 0, 0, 0, 0 };
                for (t.perm[f.lo..f.hi]) |p| counts[quadrant(xs[p], ys[p], xm, ym)] += 1;
                var off: [4]u32 = undefined;
                var sum = f.lo;
                for (0..4) |q| {
                    off[q] = sum;
                    split[q] = sum;
                    sum += counts[q];
                }
                for (t.perm[f.lo..f.hi]) |p| {
                    const q = quadrant(xs[p], ys[p], xm, ym);
                    t.perm_tmp[off[q]] = p;
                    off[q] += 1;
                }
                @memcpy(t.perm[f.lo..f.hi], t.perm_tmp[f.lo..f.hi]);
            }
            const sorted = f.sorted and f.depth < KEY_LEVELS;
            var q: u32 = 4;
            while (q > 0) {
                q -= 1;
                if (split[q] == split[q + 1]) continue;
                const right = q & 1 != 0;
                const bottom = q & 2 != 0;
                try t.push(a, &sp, .{
                    .lo = split[q],
                    .hi = split[q + 1],
                    .depth = f.depth + 1,
                    .parent = idx,
                    .slot = q,
                    .sorted = sorted,
                    .x0 = if (right) xm else f.x0,
                    .y0 = if (bottom) ym else f.y0,
                    .x1 = if (right) f.x1 else xm,
                    .y1 = if (bottom) f.y1 else ym,
                });
            }
        }
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
