//! Background work on snapshots of buffer text.
//!
//! An `Executor` has one thread that runs the jobs of many `Worker`s, one
//! at a time. Each worker has one job, for example the syntax tree of one
//! buffer. The main thread sends a worker snapshots of a rope, and the job
//! reads them while the user edits the buffer. To add a feature that needs
//! the editor text, such as syntax trees, search or spell checks, write a
//! job type and make a `Worker` of it.
//!
//! These rules make it safe:
//!
//! - Only the main thread changes reference counts: it makes, retains and
//!   releases all snapshots. The executor thread only reads nodes.
//! - The rope never changes a node that a snapshot holds, so a job can read
//!   a snapshot while the main thread edits the rope.
//! - When a job does not need a snapshot any more, it calls
//!   `Context.retire`. The main thread releases retired snapshots later.
//!
//! A job type has these declarations:
//!
//!     /// The result of one `process` call.
//!     pub const Output = T;
//!     /// The maximum number of `retire` calls in one `process` call.
//!     pub const max_retire: usize = N;
//!     /// Executor thread. The job owns `text.snap`, and it must retire it in
//!     /// this call or later (for example, a job can keep the last snapshot
//!     /// to compare with the next one). Null means no output for this text.
//!     /// A long job must stop soon after `ctx.cancelled()` becomes true.
//!     pub fn process(job: *Job, ctx: *Context, text: Text) ?Output
//!     /// Frees an output that nobody took. Either thread.
//!     pub fn discard(job: *Job, out: Output) void
//!     /// Main thread, when the worker stops. Retire the snapshots that the
//!     /// job keeps, and free its state.
//!     pub fn finish(job: *Job, ctx: *Context) void
//!
//! The worker processes only the newest text. A new `submit` replaces a
//! request that the job did not start, and a new output replaces an output
//! that the main thread did not take.
//!
//! Without threads (for example a single-threaded build), the executor runs
//! each job at once in `submit`. The results are the same.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const rope_zig = @import("rope");
const Rope = rope_zig.Rope;
const Snapshot = rope_zig.Snapshot;

/// A snapshot and the buffer version that it shows.
pub const Text = struct { snap: Snapshot, version: u64 };

/// Lets a job give back snapshots and see if it must stop. In `process`,
/// `retire` puts the snapshot in a list for the main thread. In `finish`,
/// on the main thread, it releases the snapshot at once.
pub const Context = struct {
    ptr: *anyopaque,
    retireFn: *const fn (ptr: *anyopaque, snap: Snapshot) void,
    cancel: *const std.atomic.Value(bool),

    pub fn retire(ctx: *Context, snap: Snapshot) void {
        ctx.retireFn(ctx.ptr, snap);
    }

    /// True after the main thread started to destroy the worker. Then the
    /// output is not used, so a long job can stop at once.
    pub fn cancelled(ctx: *const Context) bool {
        return ctx.cancel.load(.monotonic);
    }
};

/// The part of a worker that the executor knows.
const Task = struct {
    runFn: *const fn (task: *Task) void,
    /// True while the task is in the queue. The executor mutex protects it.
    queued: bool = false,
};

/// One thread that runs the jobs of all its workers, one job at a time.
/// Make it before the workers, and destroy it after them.
pub const Executor = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Null without threads: then `submit` runs the job at once.
    thread: ?Io.Future(void) = null,

    /// The mutex protects the fields below it, and the shared fields of all
    /// workers of this executor.
    mutex: Io.Mutex = .init,
    /// The thread waits on this for a task or for `stop`.
    wake: Io.Condition = .init,
    /// `Worker.destroy` waits on this until its task is not running.
    idle: Io.Condition = .init,
    /// The workers with a request, in order.
    queue: std.ArrayList(*Task) = .empty,
    running: ?*Task = null,
    stop: bool = false,

    /// Starts the thread. If the `Io` cannot run work concurrently, the
    /// executor runs each job in `submit`.
    pub fn create(gpa: std.mem.Allocator, io: Io) !*Executor {
        const self = try gpa.create(Executor);
        self.* = .{ .gpa = gpa, .io = io };
        self.thread = io.concurrent(run, .{self}) catch null;
        return self;
    }

    /// An executor without a thread, for tests of that mode.
    pub fn createInline(gpa: std.mem.Allocator, io: Io) !*Executor {
        const self = try gpa.create(Executor);
        self.* = .{ .gpa = gpa, .io = io };
        return self;
    }

    /// Stops the thread. Destroy all workers first.
    pub fn destroy(self: *Executor) void {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        std.debug.assert(self.queue.items.len == 0);
        self.stop = true;
        self.wake.signal(io);
        self.mutex.unlock(io);
        if (self.thread) |*t| t.await(io);
        self.queue.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn run(self: *Executor) void {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (true) {
            while (self.queue.items.len == 0 and !self.stop) self.wake.waitUncancelable(io, &self.mutex);
            if (self.stop) return;
            const task = self.queue.orderedRemove(0);
            task.queued = false;
            self.running = task;
            self.mutex.unlock(io);
            task.runFn(task); // the slow part, without the lock
            self.mutex.lockUncancelable(io);
            self.running = null;
            self.idle.broadcast(io);
        }
    }
};

pub fn Worker(comptime Job: type) type {
    return struct {
        const Self = @This();

        /// An output and the text that it is for. The receiver owns both:
        /// it frees the output and releases the snapshot with `release`.
        pub const Result = struct { text: Text, output: Job.Output };

        /// The most `retire` calls for one request: the job's calls and one
        /// call by the worker (for the output that a new output replaces, or
        /// for the text of a request without output).
        const retire_per_request = Job.max_retire + 1;

        executor: *Executor,
        rope: *Rope,
        job: Job,
        task: Task = .{ .runFn = runTask },
        /// Set by `destroy`. The job reads it through `Context.cancelled`.
        cancel: std.atomic.Value(bool) = .init(false),

        // The executor mutex protects the fields below.

        /// The main thread waits on this in `wait`.
        done: Io.Condition = .init,
        /// The newest request. It holds two references to the snapshot:
        /// one for the job, and one for the result.
        request: ?Text = null,
        result: ?Result = null,
        /// The version of the last request that the job finished.
        done_version: ?u64 = null,
        /// Snapshots for the main thread to release.
        retired: std.ArrayList(Snapshot) = .empty,

        /// The version of the last `submit`. Only the main thread uses it.
        submitted: ?u64 = null,

        /// Makes a worker. `rope` must stay at its address until `destroy`.
        /// On error, the caller keeps ownership of `job`.
        pub fn create(executor: *Executor, rope: *Rope, job: Job) !*Self {
            const gpa = executor.gpa;
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{ .executor = executor, .rope = rope, .job = job };
            // `submit` keeps this capacity free, so the executor thread does
            // not allocate in `retire`.
            try self.retired.ensureTotalCapacity(gpa, 2 * retire_per_request);
            return self;
        }

        /// Stops the work for this worker and frees all that it holds. A job
        /// that runs now sees `cancelled`, and this waits until it returns.
        pub fn destroy(self: *Self) void {
            const ex = self.executor;
            const io = ex.io;
            self.cancel.store(true, .monotonic);
            ex.mutex.lockUncancelable(io);
            if (self.task.queued) {
                const i = std.mem.indexOfScalar(*Task, ex.queue.items, &self.task).?;
                _ = ex.queue.orderedRemove(i);
                self.task.queued = false;
            }
            while (ex.running == &self.task) ex.idle.waitUncancelable(io, &ex.mutex);
            ex.mutex.unlock(io);

            // The executor does not use this worker now, so no lock is
            // necessary.
            if (self.request) |r| {
                self.rope.release(r.snap);
                self.rope.release(r.snap);
            }
            if (self.result) |r| {
                Job.discard(&self.job, r.output);
                self.rope.release(r.text.snap);
            }
            self.drainLocked();
            var ctx = self.context(retireNow);
            Job.finish(&self.job, &ctx);
            self.retired.deinit(ex.gpa);
            ex.gpa.destroy(self);
        }

        /// Sends a snapshot of the rope to the job, unless the last request
        /// had the same version.
        pub fn submit(self: *Self, version: u64) !void {
            if (self.submitted == version) return;
            const ex = self.executor;
            const io = ex.io;
            {
                ex.mutex.lockUncancelable(io);
                defer ex.mutex.unlock(io);
                self.drainLocked();
                // At most two requests are open: one in the job, one in
                // `request`. Each can retire `retire_per_request` snapshots.
                try self.retired.ensureUnusedCapacity(ex.gpa, 2 * retire_per_request);
                if (ex.thread != null and !self.task.queued) try ex.queue.ensureUnusedCapacity(ex.gpa, 1);

                const snap = self.rope.snapshot();
                _ = self.rope.retain(snap);
                if (self.request) |old| {
                    self.rope.release(old.snap);
                    self.rope.release(old.snap);
                }
                self.request = .{ .snap = snap, .version = version };
                self.submitted = version;
                if (ex.thread != null and !self.task.queued) {
                    ex.queue.appendAssumeCapacity(&self.task);
                    self.task.queued = true;
                    ex.wake.signal(io);
                }
            }
            // Without a thread, run the job now, without the lock.
            if (ex.thread == null) self.task.runFn(&self.task);
        }

        /// The newest result, or null. It does not wait.
        pub fn take(self: *Self) ?Result {
            const ex = self.executor;
            ex.mutex.lockUncancelable(ex.io);
            defer ex.mutex.unlock(ex.io);
            self.drainLocked();
            const r = self.result;
            self.result = null;
            return r;
        }

        /// Waits until the job finished the request for `version`, then
        /// returns the newest result, as `take` does. Submit `version`
        /// first. The result is null if the job gave no output, or if a
        /// `take` got the output before.
        pub fn wait(self: *Self, version: u64) ?Result {
            std.debug.assert(self.submitted == version);
            const ex = self.executor;
            const io = ex.io;
            ex.mutex.lockUncancelable(io);
            defer ex.mutex.unlock(io);
            while (self.done_version != version) self.done.waitUncancelable(io, &ex.mutex);
            self.drainLocked();
            const r = self.result;
            self.result = null;
            return r;
        }

        /// A snapshot of the rope now, for the main thread. Release it with
        /// `release`.
        pub fn snapshot(self: *Self) Snapshot {
            return self.rope.snapshot();
        }

        /// Releases the snapshot of a `Result`, or of `snapshot`.
        pub fn release(self: *Self, snap: Snapshot) void {
            self.rope.release(snap);
        }

        fn context(self: *Self, retireFn: *const fn (ptr: *anyopaque, snap: Snapshot) void) Context {
            return .{ .ptr = self, .retireFn = retireFn, .cancel = &self.cancel };
        }

        fn drainLocked(self: *Self) void {
            for (self.retired.items) |snap| self.rope.release(snap);
            self.retired.clearRetainingCapacity();
        }

        /// Runs the job on the newest request: on the executor thread, or in
        /// `submit` without a thread.
        fn runTask(task: *Task) void {
            const self: *Self = @fieldParentPtr("task", task);
            const ex = self.executor;
            const io = ex.io;
            ex.mutex.lockUncancelable(io);
            const text = self.request orelse {
                ex.mutex.unlock(io);
                return;
            };
            self.request = null;
            ex.mutex.unlock(io);

            var ctx = self.context(retireQueued);
            const output = Job.process(&self.job, &ctx, text);

            ex.mutex.lockUncancelable(io);
            defer ex.mutex.unlock(io);
            if (output) |out| {
                if (self.result) |old| {
                    Job.discard(&self.job, old.output);
                    self.retireLocked(old.text.snap);
                }
                self.result = .{ .text = text, .output = out };
            } else {
                self.retireLocked(text.snap);
            }
            self.done_version = text.version;
            self.done.broadcast(io);
        }

        fn retireLocked(self: *Self, snap: Snapshot) void {
            // `submit` keeps capacity free. If a job retires more than
            // `max_retire`, try to grow the list. The allocator is
            // thread-safe. Without memory, the snapshot leaks.
            if (self.retired.unusedCapacitySlice().len > 0) {
                self.retired.appendAssumeCapacity(snap);
            } else {
                self.retired.append(self.executor.gpa, snap) catch {};
            }
        }

        fn retireQueued(ptr: *anyopaque, snap: Snapshot) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const ex = self.executor;
            ex.mutex.lockUncancelable(ex.io);
            defer ex.mutex.unlock(ex.io);
            self.retireLocked(snap);
        }

        fn retireNow(ptr: *anyopaque, snap: Snapshot) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.rope.release(snap);
        }
    };
}

// Tests

/// A job that counts the newlines of the text. It keeps the last snapshot
/// to show how a job holds a snapshot between calls.
const CountJob = struct {
    last: ?Snapshot = null,
    processed: usize = 0,

    pub const Output = usize;
    pub const max_retire: usize = 1;

    pub fn process(job: *CountJob, ctx: *Context, text: Text) ?usize {
        if (job.last) |old| ctx.retire(old);
        job.last = text.snap;
        job.processed += 1;
        var n: usize = 0;
        var it = text.snap.chunks();
        while (it.next()) |chunk| n += std.mem.countScalar(u8, chunk, '\n');
        return n;
    }

    pub fn discard(_: *CountJob, _: usize) void {}

    pub fn finish(job: *CountJob, ctx: *Context) void {
        if (job.last) |s| ctx.retire(s);
        job.last = null;
    }
};

fn expectCounts(ex: *Executor) !void {
    const gpa = testing.allocator;
    var rope = try Rope.fromSlice(gpa, "a\nb\n");
    defer rope.deinit(); // asserts that no node leaks
    var other = try Rope.fromSlice(gpa, "x\n");
    defer other.deinit();

    const W = Worker(CountJob);
    const w = try W.create(ex, &rope, .{});
    defer w.destroy();
    // A second worker on the same executor.
    const w2 = try W.create(ex, &other, .{});
    defer w2.destroy();

    var version: u64 = 0;
    try w.submit(version);
    try w2.submit(version);
    const r0 = w.wait(version).?;
    try testing.expectEqual(2, r0.output);
    try testing.expectEqual(version, r0.text.version);
    w.release(r0.text.snap);
    const r2 = w2.wait(version).?;
    try testing.expectEqual(1, r2.output);
    w2.release(r2.text.snap);

    // Many edits and requests without a wait. The job can skip some. Keep
    // the newest result: without a thread, `take` gets the last one.
    var newest: ?W.Result = null;
    for (0..200) |i| {
        try rope.insert(rope.len(), if (i % 2 == 0) "x\n" else "y");
        version += 1;
        try w.submit(version);
        if (w.take()) |r| {
            if (newest) |old| w.release(old.text.snap);
            newest = r;
        }
    }
    if (w.wait(version)) |r| {
        if (newest) |old| w.release(old.text.snap);
        newest = r;
    }
    const last = newest orelse return error.NoResult;
    defer w.release(last.text.snap);
    try testing.expectEqual(version, last.text.version);
    try testing.expectEqual(2 + 100, last.output);
    try testing.expectEqual(rope.len(), last.text.snap.len());

    // The same version again is not a new request.
    try w.submit(version);
    try testing.expectEqual(null, w.take());
}

test "a worker processes snapshots while the rope changes" {
    const ex = try Executor.create(testing.allocator, testing.io);
    defer ex.destroy();
    try expectCounts(ex);
}

test "without a thread, submit runs the job at once" {
    const ex = try Executor.createInline(testing.allocator, testing.io);
    defer ex.destroy();
    try expectCounts(ex);
}

test "destroy releases a request that is still open" {
    const gpa = testing.allocator;
    const ex = try Executor.create(gpa, testing.io);
    defer ex.destroy();
    var rope = try Rope.fromSlice(gpa, "text");
    defer rope.deinit();
    const w = try Worker(CountJob).create(ex, &rope, .{});
    for (0..10) |v| {
        try rope.insert(0, "z");
        try w.submit(v);
    }
    w.destroy();
}

/// A job that runs until it is cancelled.
const SlowJob = struct {
    started: *std.atomic.Value(bool),

    pub const Output = void;
    pub const max_retire: usize = 1;

    pub fn process(job: *SlowJob, ctx: *Context, text: Text) ?void {
        job.started.store(true, .monotonic);
        while (!ctx.cancelled()) std.atomic.spinLoopHint();
        ctx.retire(text.snap);
        return null;
    }

    pub fn discard(_: *SlowJob, _: void) void {}
    pub fn finish(_: *SlowJob, _: *Context) void {}
};

test "destroy cancels a job that runs" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const gpa = testing.allocator;
    const ex = try Executor.create(gpa, testing.io);
    defer ex.destroy();
    if (ex.thread == null) return error.SkipZigTest;
    var rope = try Rope.fromSlice(gpa, "text");
    defer rope.deinit();
    var started: std.atomic.Value(bool) = .init(false);
    const w = try Worker(SlowJob).create(ex, &rope, .{ .started = &started });
    try w.submit(0);
    while (!started.load(.monotonic)) std.atomic.spinLoopHint();
    w.destroy(); // without the cancel flag, this would not return
}
