// Browser-thread helpers for the native Page ABI.
//
// These functions never expose a DOM object across the FFI boundary. Frame
// metadata is copied to JSON and selectors are resolved/clicked synchronously
// on Runtime.workerMain, where the Session and every Frame are owned.

const std = @import("std");
const lp = @import("darkpanda");

const Allocator = std.mem.Allocator;
const Frame = lp.Frame;
const Session = lp.Session;
const Runner = lp.Session.Runner;
const Element = lp.Element;

pub const ClickOptions = struct {
    frame_id: u32 = 0,
    timeout_ms: u32,
    pierce_shadow: bool = false,
    move_delay_ms: u32 = 16,
    press_delay_ms: u32 = 60,
};

const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

const FrameInfo = struct {
    frameId: u32,
    parentFrameId: ?u32,
    url: []const u8,
    name: []const u8,
    isRoot: bool,
    attached: bool,
    visible: bool,
    ownerRect: ?Rect,
    childCount: usize,
};

pub fn framesJson(allocator: Allocator, session: *Session, root_frame_id: u32) ![]u8 {
    const page = session.livePage(root_frame_id) orelse return error.PageClosed;
    var frames: std.ArrayList(FrameInfo) = .empty;
    defer frames.deinit(allocator);
    try appendFrameInfo(allocator, &frames, &page.frame, null, true, true);
    return std.json.Stringify.valueAlloc(allocator, frames.items, .{});
}

fn appendFrameInfo(
    allocator: Allocator,
    frames: *std.ArrayList(FrameInfo),
    frame: *Frame,
    parent_id: ?u32,
    parent_attached: bool,
    parent_visible: bool,
) !void {
    var attached = parent_attached;
    var visible = parent_visible;
    var owner_rect: ?Rect = null;
    if (frame.iframe) |iframe| {
        const owner = iframe.asElement();
        const parent = frame.parent orelse frame;
        attached = attached and owner.asNode().isConnected();
        const rect = owner.getBoundingClientRect(parent);
        owner_rect = .{
            .x = rect.getX(),
            .y = rect.getY(),
            .width = rect.getWidth(),
            .height = rect.getHeight(),
        };
        visible = visible and attached and owner.checkVisibilityCached(null, parent) and
            positiveFinite(rect.getWidth()) and positiveFinite(rect.getHeight());
    }

    try frames.append(allocator, .{
        .frameId = frame._frame_id,
        .parentFrameId = parent_id,
        .url = frame.url,
        .name = frame.window._name,
        .isRoot = parent_id == null,
        .attached = attached,
        .visible = visible,
        .ownerRect = owner_rect,
        .childCount = frame.child_frames.items.len,
    });
    for (frame.child_frames.items) |child| {
        try appendFrameInfo(allocator, frames, child, frame._frame_id, attached, visible);
    }
}

fn positiveFinite(value: f64) bool {
    return std.math.isFinite(value) and value > 0;
}

pub fn click(
    session: *Session,
    root_frame_id: u32,
    selector: []const u8,
    opts: ClickOptions,
) !void {
    const target_frame_id = if (opts.frame_id == 0) root_frame_id else opts.frame_id;
    const initial_page = session.livePage(root_frame_id) orelse return error.PageClosed;
    if (initial_page.findFrameByFrameId(target_frame_id) == null) {
        return error.FrameNotFound;
    }

    var timer = try std.time.Timer.start();
    var runner = session.runner(.{});
    while (true) {
        if (session.isCancelled()) return error.Cancelled;

        // Re-resolve on every iteration. A queued navigation can replace the
        // root Page or reconstruct a child Frame while retaining its frame id.
        const page = session.livePage(root_frame_id) orelse return error.PageClosed;
        const frame = page.findFrameByFrameId(target_frame_id) orelse
            return error.FrameNotFound;
        if (try lp.actions.querySelectorNative(selector, opts.pierce_shadow, frame)) |element| {
            try ensureFrameInteractive(frame);
            try ensureElementInteractive(frame, element);
            const point = Frame.user_input.pointForElement(frame, element);

            // Match the three independent Chrome input commands. Every helper
            // returns after its event-level microtask checkpoints, then the
            // boundary pumps one event-loop turn and sleeps only after all V8
            // scopes have exited.
            const move = try resolveInteractiveHit(
                session,
                root_frame_id,
                target_frame_id,
                selector,
                opts.pierce_shadow,
                point,
            );
            try Frame.user_input.movePointerToElement(move.frame, move.element, point);
            try phaseBoundary(session, root_frame_id, opts.move_delay_ms, &runner);

            const press = try resolveInteractiveHit(
                session,
                root_frame_id,
                target_frame_id,
                selector,
                opts.pierce_shadow,
                point,
            );
            const state = try Frame.user_input.pressElement(press.frame, press.element, point);
            try phaseBoundary(session, root_frame_id, opts.press_delay_ms, &runner);

            const release = try resolveReleaseHit(
                session,
                root_frame_id,
                target_frame_id,
                selector,
                opts.pierce_shadow,
                point,
            );
            try Frame.user_input.releaseElement(release.frame, release.element, point, state);
            if (release.validation_error) |err| return err;
            try settleAfterClick(session, root_frame_id, opts.timeout_ms, &runner);
            return;
        }

        const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (elapsed >= opts.timeout_ms) return error.Timeout;
        const remaining = opts.timeout_ms - elapsed;
        switch (try runner.tickForFrame(root_frame_id, @min(remaining, 50), .{ .until = .done })) {
            .done => std.Thread.sleep(std.time.ns_per_ms * @as(u64, @min(remaining, 25))),
            .ok => |recommended_sleep_ms| if (recommended_sleep_ms > 0) {
                std.Thread.sleep(std.time.ns_per_ms * @as(u64, @min(recommended_sleep_ms, remaining)));
            },
        }
    }
}

const PhaseTarget = struct {
    frame: *Frame,
    element: *Element,
};

fn resolveInteractiveHit(
    session: *Session,
    root_frame_id: u32,
    target_frame_id: u32,
    selector: []const u8,
    pierce_shadow: bool,
    point: Frame.user_input.Point,
) !PhaseTarget {
    const page = session.livePage(root_frame_id) orelse return error.PageClosed;
    const frame = page.findFrameByFrameId(target_frame_id) orelse return error.FrameDetached;
    try ensureFrameInteractive(frame);
    const selected = (try lp.actions.querySelectorNative(selector, pierce_shadow, frame)) orelse
        return error.ElementDetached;
    try ensureElementInteractive(frame, selected);
    const hit = (try Frame.user_input.nativeElementFromPoint(frame, point, true)) orelse
        return error.ElementObscured;
    if (!Frame.user_input.nativeHitBelongsTo(frame, hit, selected)) {
        return error.ElementObscured;
    }
    return .{ .frame = frame, .element = hit };
}

const ReleaseTarget = struct {
    frame: *Frame,
    element: *Element,
    validation_error: ?anyerror,
};

fn resolveReleaseHit(
    session: *Session,
    root_frame_id: u32,
    target_frame_id: u32,
    selector: []const u8,
    pierce_shadow: bool,
    point: Frame.user_input.Point,
) !ReleaseTarget {
    const page = session.livePage(root_frame_id) orelse return error.PageClosed;
    const frame = page.findFrameByFrameId(target_frame_id) orelse return error.FrameDetached;
    try ensureFrameInteractive(frame);

    // Always release the physical button at the current coordinate, even when
    // the selected element moved or an overlay appeared after pointerdown.
    // Report the actionability failure only after pointerup/mouseup have been
    // dispatched, preventing a stuck native press state.
    const hit = (try Frame.user_input.nativeElementFromPoint(frame, point, true)) orelse
        return error.ElementObscured;
    const selected = (try lp.actions.querySelectorNative(selector, pierce_shadow, frame)) orelse {
        return .{ .frame = frame, .element = hit, .validation_error = error.ElementDetached };
    };

    var validation_error: ?anyerror = null;
    ensureElementInteractive(frame, selected) catch |err| {
        validation_error = err;
    };
    if (validation_error == null and !Frame.user_input.nativeHitBelongsTo(frame, hit, selected)) {
        validation_error = error.ElementObscured;
    }
    return .{ .frame = frame, .element = hit, .validation_error = validation_error };
}

fn ensureFrameInteractive(frame: *Frame) !void {
    var current: *Frame = frame;
    while (current.iframe) |iframe| {
        const parent = current.parent orelse return error.FrameDetached;
        const owner = iframe.asElement();
        if (!owner.asNode().isConnected()) return error.FrameDetached;
        if (!owner.checkVisibilityCached(null, parent)) return error.FrameNotVisible;
        const rect = owner.getBoundingClientRect(parent);
        if (!positiveFinite(rect.getWidth()) or !positiveFinite(rect.getHeight())) {
            return error.FrameNotVisible;
        }
        current = parent;
    }
}

fn ensureElementInteractive(frame: *Frame, element: *Element) !void {
    if (!element.asNode().isConnected()) return error.ElementDetached;
    if (!element.checkVisibilityCached(null, frame)) return error.ElementNotVisible;
    if (element.hasPointerEventsNone(null, frame)) return error.ElementHasPointerEventsNone;
    const rect = element.getBoundingClientRect(frame);
    if (!positiveFinite(rect.getWidth()) or !positiveFinite(rect.getHeight())) {
        return error.ElementHasNoLayoutBox;
    }
}

fn phaseBoundary(session: *Session, root_frame_id: u32, delay_ms: u32, runner: *Runner) !void {
    var timer = try std.time.Timer.start();
    while (true) {
        if (session.isCancelled()) return error.Cancelled;
        const elapsed_ms: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (elapsed_ms >= delay_ms) {
            // Run work which became due exactly at the boundary. A zero delay
            // still represents a separate browser task, not two synchronous
            // event dispatches in one foreign-call stack.
            _ = try runner.tickForFrame(root_frame_id, 0, .{ .until = .done });
            return;
        }
        const remaining = delay_ms - elapsed_ms;
        const quantum = @min(remaining, 10);
        switch (try runner.tickForFrame(root_frame_id, quantum, .{ .until = .done })) {
            .done => std.Thread.sleep(std.time.ns_per_ms * @as(u64, quantum)),
            .ok => |recommended_sleep_ms| if (recommended_sleep_ms > 0) {
                std.Thread.sleep(std.time.ns_per_ms * @as(u64, @min(recommended_sleep_ms, quantum)));
            },
        }
    }
}

fn settleAfterClick(
    session: *Session,
    root_frame_id: u32,
    requested_timeout_ms: u32,
    runner: *Runner,
) !void {
    // Let requests, postMessage delivery and timer/macrotask work initiated by
    // the click make progress before returning to a foreign caller. A page with
    // a perpetual timer must not turn a successful click into a timeout, so the
    // settle budget is bounded and expiry is success, not an error.
    const budget_ms = @min(requested_timeout_ms, 2_000);
    if (budget_ms == 0) return;
    var timer = try std.time.Timer.start();
    while (true) {
        if (session.isCancelled()) return error.Cancelled;
        const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
        if (elapsed >= budget_ms) return;
        const remaining = budget_ms - elapsed;
        switch (try runner.tickForFrame(root_frame_id, @min(remaining, 50), .{ .until = .done })) {
            .done => return,
            .ok => |recommended_sleep_ms| if (recommended_sleep_ms > 0) {
                std.Thread.sleep(std.time.ns_per_ms * @as(u64, @min(recommended_sleep_ms, remaining)));
            },
        }
    }
}
