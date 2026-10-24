//! Thread pool (TRD 3, Design: "One primitive, two builds" and "Job slot and
//! barrier"). Every parallel kernel phase is one `parallelFor(ctx, n, func)`.
//! In core.wasm and in native builds it is a plain loop on the calling
//! thread. In core-mt.wasm the main thread publishes the phase in a job slot
//! in shared memory and takes chunks alongside the workers that join it;
//! when the chunks run out it seals the phase and spins until every worker
//! that joined has checked in. A chunk function writes only what its
//! chunk owns and the scratch row of its `tid`, and reads only what nothing
//! writes during the phase, so results do not depend on which thread ran
//! which chunk.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// True in core-mt.wasm (wasm with threads).
pub const threaded = builtin.target.cpu.arch.isWasm() and !builtin.single_threaded;

pub const Error = error{WorkerFailed};

/// Most workers a pool may have; tid 0 is the main thread.
pub const MAX_WORKERS = 63;
/// One worker's stack, with its TLS block at the bottom.
pub const REGION: u32 = 512 * 1024;

/// Test knobs (`pool_tune`): a non-zero `test_chunk` replaces every chunk
/// size and `test_cut` the largest job subtree, so small scenarios split too.
pub var test_chunk: u32 = 0;
pub var test_cut: u32 = 0;

/// The thread running this code: 0 on the main thread. Only debug checks
/// read it.
pub threadlocal var tid: u32 = 0;

pub inline fn chunkSize(default: u32) u32 {
    return if (test_chunk != 0) test_chunk else default;
}

/// Chunks of `size` items over `n` items.
pub inline fn chunks(n: u32, size: u32) u32 {
    return (n + size - 1) / size;
}

pub const Range = struct { lo: u32, hi: u32 };

/// The items of chunk `c`.
pub inline fn range(n: u32, size: u32, c: u32) Range {
    const lo = c * size;
    return .{ .lo = lo, .hi = @min(n, lo + size) };
}

/// The most points a job subtree may hold (TRD 3, "The cut").
pub fn cutLimit(m: u32) u32 {
    if (test_cut != 0) return test_cut;
    return @max(m / 64, 64);
}

/// Threads that may run chunks: per-thread scratch has this many rows.
pub fn threads() u32 {
    return if (threaded) 1 + mt.workers else 1;
}

/// Runs `func(ctx, c, tid)` for every chunk c < n, on any thread.
pub fn parallelFor(ctx: anytype, n: u32, comptime func: fn (@TypeOf(ctx), u32, u32) void) Error!void {
    if (threaded) {
        const T = Trampoline(@TypeOf(ctx), func);
        return mt.dispatch(@ptrCast(@constCast(ctx)), n, &T.call);
    } else {
        var c: u32 = 0;
        while (c < n) : (c += 1) func(ctx, c, 0);
    }
}

/// Runs every later phase on the main thread until cleared. Exact collide
/// uses it after its first iteration, so no kernel has a parallel phase after
/// its first random draw (TRD 3, Facade: "Failure").
pub fn setInline(on: bool) void {
    if (threaded) mt.inline_only = on;
}

const ChunkFn = *const fn (*anyopaque, u32, u32) void;

fn Trampoline(comptime P: type, comptime func: fn (P, u32, u32) void) type {
    return struct {
        fn call(p: *anyopaque, c: u32, t: u32) void {
            func(@ptrCast(@alignCast(p)), c, t);
        }
    };
}

pub fn tune(which: u32, v: f64) void {
    switch (which) {
        0 => test_chunk = @intFromFloat(v),
        1 => test_cut = @intFromFloat(v),
        2 => if (threaded) {
            mt.timeout_ms = v;
        },
        3 => if (threaded) {
            mt.slot.trap_tid = @intFromFloat(v);
        },
        4 => if (threaded) {
            mt.spin_ms = v;
        },
        5 => if (threaded) {
            mt.slot.stall_tid = @intFromFloat(v);
        },
        else => {},
    }
}

pub const mt = if (threaded) struct {
    extern "env" fn now() f64;

    /// The job slot (TRD 3, "Job slot and barrier"). The contended counters
    /// and each worker's progress counter sit on their own lines.
    const Slot = extern struct {
        generation: u32 align(64) = 0,
        func: u32 = 0,
        ctx: u32 = 0,
        n_chunks: u32 = 0,
        active: u32 = 0,
        hold: u32 = 0,
        sleepers: u32 = 0,
        failed: u32 = 0,
        retire: u32 = 0,
        trap_tid: u32 = 0,
        /// Test hook: this worker stops making progress inside a phase.
        stall_tid: u32 = 0,
        /// The phase's generation (low 16 bits) in the high half; in the low
        /// half the workers that joined it and, once the main thread's chunks
        /// ran out, the SEALED bit. A worker reads the slot only after joining.
        ticket: u32 align(64) = 0,
        next_chunk: u32 align(64) = 0,
        checked_in: u32 align(64) = 0,
        progress: [MAX_WORKERS + 1][16]u32 align(64) = .{.{0} ** 16} ** (MAX_WORKERS + 1),
    };

    const SEALED: u32 = 1 << 15;

    inline fn tag(g: u32) u32 {
        return (g & 0xffff) << 16;
    }

    pub var slot: Slot = .{};
    pub var workers: u32 = 0;
    pub var timeout_ms: f64 = 2000;
    /// Idle workers spin this long after a phase before they sleep, unless
    /// `hold` keeps them spinning: long enough for back-to-back ticks, since
    /// a wake-up costs 0.4 to 3 ms on the benchmark phone.
    pub var spin_ms: f64 = 2;
    pub var inline_only = false;
    /// Diagnostics (`pool_stat`): phases dispatched and the main thread's
    /// time spent waiting for check-ins.
    pub var phases: f64 = 0;
    pub var wait_ms: f64 = 0;

    pub fn init(a: Allocator, k: u32) u32 {
        if (workers != 0 or k == 0 or k > MAX_WORKERS or tlsSize() > 4096) return 0;
        const mem = a.alignedAlloc(u8, .@"16", @as(usize, k) * REGION) catch return 0;
        workers = k;
        slot.active = k;
        return @intCast(@intFromPtr(mem.ptr));
    }

    fn dispatch(ctx: *anyopaque, n: u32, func: ChunkFn) Error!void {
        const k = workers;
        if (n <= 1 or k == 0 or slot.active == 0 or inline_only or slot.retire != 0) {
            var c: u32 = 0;
            while (c < n) : (c += 1) func(ctx, c, 0);
            return;
        }
        if (@atomicLoad(u32, &slot.failed, .seq_cst) != 0) return error.WorkerFailed;
        const g = slot.generation +% 1;
        slot.func = @intCast(@intFromPtr(func));
        slot.ctx = @intCast(@intFromPtr(ctx));
        slot.n_chunks = n;
        @atomicStore(u32, &slot.next_chunk, 0, .seq_cst);
        @atomicStore(u32, &slot.checked_in, 0, .seq_cst);
        @atomicStore(u32, &slot.ticket, tag(g), .seq_cst);
        @atomicStore(u32, &slot.generation, g, .seq_cst);
        if (@atomicLoad(u32, &slot.sleepers, .seq_cst) != 0) _ = notify(&slot.generation, std.math.maxInt(u32));
        phases += 1;

        while (true) {
            const c = @atomicRmw(u32, &slot.next_chunk, .Add, 1, .seq_cst);
            if (c >= n) break;
            func(ctx, c, 0);
        }

        // Seal: workers that have not joined by now skip this phase, so a
        // sleeping or descheduled worker never holds it up.
        var ticket = @atomicLoad(u32, &slot.ticket, .seq_cst);
        while (@cmpxchgWeak(u32, &slot.ticket, ticket, ticket | SEALED, .seq_cst, .seq_cst)) |actual| ticket = actual;
        const joined = ticket & (SEALED - 1);
        if (@atomicLoad(u32, &slot.checked_in, .seq_cst) == joined) return;
        // Fail only on a stall: 2 s in which no worker finished a chunk or
        // checked in, so a long but healthy phase never trips it.
        const t0 = now();
        var t_progress = t0;
        var seen = progressSum(k);
        var spins: u32 = 0;
        while (@atomicLoad(u32, &slot.checked_in, .seq_cst) != joined) {
            if (@atomicLoad(u32, &slot.failed, .seq_cst) != 0) return error.WorkerFailed;
            spins +%= 1;
            if (spins & 4095 != 0) continue;
            const p = progressSum(k);
            const t_now = now();
            if (p != seen) {
                seen = p;
                t_progress = t_now;
            } else if (t_now - t_progress > timeout_ms) {
                @atomicStore(u32, &slot.failed, MAX_WORKERS + 1, .seq_cst);
                return error.WorkerFailed;
            }
        }
        wait_ms += now() - t0;
    }

    fn progressSum(k: u32) u32 {
        var s: u32 = @atomicLoad(u32, &slot.checked_in, .seq_cst);
        for (1..k + 1) |t| s +%= @atomicLoad(u32, &slot.progress[t][0], .monotonic);
        return s;
    }

    /// Entry of a worker (`worker_start`): its own stack and TLS first, then
    /// the job loop, which returns only when the pool is retired. Every
    /// instance's stack pointer starts at the main thread's stack top, so
    /// nothing here may touch the stack before it is moved.
    pub fn workerStart(t: u32, region: u32) callconv(.c) void {
        asm volatile (
            \\ local.get %[top]
            \\ global.set __stack_pointer
            :
            : [top] "r" (region + REGION),
        );
        __wasm_init_tls(@ptrFromInt(region));
        workerLoop(t);
    }

    noinline fn workerLoop(t: u32) void {
        tid = t;
        var seen: u32 = 0;
        while (true) {
            var g = @atomicLoad(u32, &slot.generation, .seq_cst);
            if (g == seen) {
                var t0 = now();
                var spins: u32 = 0;
                while (true) {
                    g = @atomicLoad(u32, &slot.generation, .seq_cst);
                    if (g != seen) break;
                    spins +%= 1;
                    if (spins & 255 != 0) continue;
                    if (@atomicLoad(u32, &slot.retire, .seq_cst) != 0) return;
                    if (@atomicLoad(u32, &slot.hold, .seq_cst) != 0) continue;
                    if (now() - t0 < spin_ms) continue;
                    // Dekker with `dispatch`: the main thread bumps
                    // generation and then reads sleepers; this side bumps
                    // sleepers and then reads generation, so one of them sees
                    // the other and no wake-up is lost.
                    _ = @atomicRmw(u32, &slot.sleepers, .Add, 1, .seq_cst);
                    if (@atomicLoad(u32, &slot.generation, .seq_cst) == seen and @atomicLoad(u32, &slot.retire, .seq_cst) == 0) {
                        _ = wait32(&slot.generation, seen);
                    }
                    _ = @atomicRmw(u32, &slot.sleepers, .Sub, 1, .seq_cst);
                    t0 = now();
                }
            }
            seen = g;
            if (@atomicLoad(u32, &slot.retire, .seq_cst) != 0) return;
            if (t > @atomicLoad(u32, &slot.active, .seq_cst) or !join(g)) continue;
            // V8 tells other threads that a shared memory grew through an
            // interrupt, handled at their next stack check; until then their
            // bounds checks use the old size. The main thread may have grown
            // memory just before this phase, so a call into JS (whose entry
            // check handles the interrupt) comes before any chunk. Without it
            // a worker traps "memory access out of bounds" on new memory.
            _ = now();
            // Joined: the main thread waits for this check-in before it
            // rewrites the slot, so the reads below see this phase.
            const func: ChunkFn = @ptrFromInt(slot.func);
            const ctx: *anyopaque = @ptrFromInt(slot.ctx);
            const n = slot.n_chunks;
            if (slot.trap_tid == t) @trap();
            while (@atomicLoad(u32, &slot.stall_tid, .monotonic) == t) {}
            while (true) {
                const c = @atomicRmw(u32, &slot.next_chunk, .Add, 1, .seq_cst);
                if (c >= n) break;
                func(ctx, c, t);
                _ = @atomicRmw(u32, &slot.progress[t][0], .Add, 1, .monotonic);
            }
            _ = @atomicRmw(u32, &slot.checked_in, .Add, 1, .seq_cst);
        }
    }

    /// Joins phase `g` unless it is sealed or already replaced.
    fn join(g: u32) bool {
        var t = @atomicLoad(u32, &slot.ticket, .seq_cst);
        while (true) {
            if (t & ~(SEALED | (SEALED - 1)) != tag(g) or t & SEALED != 0) return false;
            t = @cmpxchgWeak(u32, &slot.ticket, t, t + 1, .seq_cst, .seq_cst) orelse return true;
        }
    }

    pub fn hold(delta: i32) void {
        _ = @atomicRmw(u32, &slot.hold, .Add, @bitCast(delta), .seq_cst);
        if (delta > 0 and @atomicLoad(u32, &slot.sleepers, .seq_cst) != 0) {
            // Wake sleepers now, so they are spinning by the first phase. A
            // wake-up without a new generation sends them back to waiting.
            _ = notify(&slot.generation, std.math.maxInt(u32));
        }
    }

    pub fn setActive(a: u32) u32 {
        const prev = slot.active;
        slot.active = @min(a, workers);
        return prev;
    }

    pub fn retire() void {
        @atomicStore(u32, &slot.retire, 1, .seq_cst);
        _ = @atomicRmw(u32, &slot.generation, .Add, 1, .seq_cst);
        _ = notify(&slot.generation, std.math.maxInt(u32));
    }

    fn wait32(ptr: *u32, expected: u32) u32 {
        return asm volatile (
            \\ local.get %[ptr]
            \\ local.get %[expected]
            \\ i64.const -1
            \\ memory.atomic.wait32 0
            \\ local.set %[ret]
            : [ret] "=r" (-> u32),
            : [ptr] "r" (ptr),
              [expected] "r" (expected),
        );
    }

    fn notify(ptr: *u32, count: u32) u32 {
        return asm volatile (
            \\ local.get %[ptr]
            \\ local.get %[count]
            \\ memory.atomic.notify 0
            \\ local.set %[ret]
            : [ret] "=r" (-> u32),
            : [ptr] "r" (ptr),
              [count] "r" (count),
        );
    }

    extern fn __wasm_init_tls(memory: [*]u8) void;

    fn tlsSize() u32 {
        return asm volatile (
            \\ .globaltype __tls_size, i32, immutable
            \\ global.get __tls_size
            \\ local.set %[ret]
            : [ret] "=r" (-> u32),
        );
    }
} else struct {
    pub const workers: u32 = 0;
};
