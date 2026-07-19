// Copyright (C) 2026 DarkPanda contributors
//
// DedicatedWorker's cross-thread wake primitive. This wrapper intentionally
// exposes no callback/data pointer: producer threads only release V8's
// blocking foreground pump, while the owner reads its separately synchronized
// mailbox after PumpMessageLoop returns.

const v8_package = @import("v8");
const v8 = v8_package.c;

const ForegroundWake = @This();

inner: v8_package.ForegroundWake,

pub const Error = v8_package.ForegroundWake.Error;

/// Owner-thread operation. Acquire only after the worker isolate has been
/// created on, and assigned to, its final OS thread.
pub fn acquire(platform: *v8.Platform, isolate: *v8.Isolate) Error!ForegroundWake {
    return .{ .inner = try .acquire(platform, isolate) };
}

/// Create the producer-owned reference that may cross an OS-thread boundary.
pub fn retain(self: *const ForegroundWake) Error!ForegroundWake {
    return .{ .inner = try self.inner.retain() };
}

pub fn post(self: *const ForegroundWake) bool {
    return self.inner.post();
}

/// Owner-thread operation. Idempotent; after success all producer posts are
/// safe false. Delayed wakes belong to Scheduler and are deliberately absent.
pub fn close(self: *const ForegroundWake) bool {
    return self.inner.close();
}

/// Owner-thread operation, valid only after `close`. WorkerRuntime must then
/// dispose the isolate before releasing its final wake reference.
pub fn notifyIsolateShutdown(
    self: *const ForegroundWake,
    platform: *v8.Platform,
    isolate: *v8.Isolate,
) bool {
    return self.inner.notifyIsolateShutdown(platform, isolate);
}

pub fn deinit(self: *ForegroundWake) void {
    self.inner.deinit();
}
