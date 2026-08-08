// Dedicated-thread runtime used by the stable C ABI.
//
// Every Browser, Session, Page and V8 operation is constructed, used and
// destroyed by workerMain.  Foreign callers only enqueue synchronous commands;
// cancellation is the sole lock-free cross-thread operation and is observed by
// Session.Runner through its existing CancelHook.

const std = @import("std");
const lp = @import("darkpanda");
const abi = @import("abi.zig");
const IdentityManifest = @import("IdentityManifest.zig");
const NetworkObservations = @import("NetworkObservations.zig");
const PageAbi = @import("Page.zig");
const CanvasBackendProvider = lp.CanvasBackendProvider;

const Allocator = std.mem.Allocator;
const allocator = std.heap.c_allocator;

// V8's platform is a once-per-process resource. The public Runtime handle is
// repeatable, but its physical engine remains alive until process exit.
var process_runtime: ?*Runtime = null;

fn optionalSlicesEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn optionalDigestsEqual(a: ?[32]u8, b: ?[32]u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, &a.?, &b.?);
}

pub const Runtime = struct {
    thread: std.Thread = undefined,

    startup_mutex: std.Thread.Mutex = .{},
    startup_condition: std.Thread.Condition = .{},
    startup_done: bool = false,
    startup_error: ?anyerror = null,

    queue_mutex: std.Thread.Mutex = .{},
    queue_condition: std.Thread.Condition = .{},
    queue: std.DoublyLinkedList = .{},
    stopping: bool = false,

    refs: std.atomic.Value(usize) = .init(0),
    refs_mutex: std.Thread.Mutex = .{},
    refs_condition: std.Thread.Condition = .{},
    closing: bool = false, // protected by registry_mutex

    active_page: std.atomic.Value(usize) = .init(0),
    active_cancel_epoch: std.atomic.Value(u64) = .init(0),
    browser_ptr: std.atomic.Value(usize) = .init(0),
    pages_mutex: std.Thread.Mutex = .{},
    pages: std.ArrayListUnmanaged(*PageRef) = .empty,
    reusable: bool = true,

    wreq_transport_path: ?[]u8 = null,
    application_locale: ?[:0]u8 = null,
    timezone: ?[:0]u8 = null,
    fingerprint_profile_json: ?[]u8 = null,
    fingerprint_profile_digest: ?[32]u8 = null,
    wreq_dns_nameservers: ?[]u8 = null,
    canvas_backend_path: ?[]u8 = null,
    canvas_driver: abi.CanvasDriver = .environment,
    canvas_fallback: abi.CanvasFallback = .disabled,
    webrtc_backend_path: ?[]u8 = null,
    webrtc_tun_bind_address: ?[]u8 = null,
    webrtc_mode: abi.WebRtcMode = .disabled,
    client_profile: lp.ClientProfile.Id = lp.ClientProfile.target_default,
    navigation_timeout_ms: u32 = 30_000,

    pub fn start(
        wreq_transport_path: ?[]const u8,
        application_locale: ?[]const u8,
        timezone: ?[]const u8,
        client_profile: lp.ClientProfile.Id,
        fingerprint_profile_json: ?[]const u8,
        fingerprint_profile_digest: ?[32]u8,
        wreq_dns_nameservers: ?[]const u8,
        canvas_backend_path: ?[]const u8,
        canvas_driver: abi.CanvasDriver,
        canvas_fallback: abi.CanvasFallback,
        webrtc_backend_path: ?[]const u8,
        webrtc_tun_bind_address: ?[]const u8,
        webrtc_mode: abi.WebRtcMode,
        navigation_timeout_ms: u32,
    ) !*Runtime {
        if (process_runtime) |self| {
            if (!self.reusable) return error.RuntimeNotReusable;
            if (!optionalSlicesEqual(self.wreq_transport_path, wreq_transport_path) or
                !optionalSlicesEqual(self.application_locale, application_locale) or
                !optionalSlicesEqual(self.timezone, timezone) or
                !optionalSlicesEqual(self.wreq_dns_nameservers, wreq_dns_nameservers) or
                !optionalSlicesEqual(self.canvas_backend_path, canvas_backend_path) or
                !optionalSlicesEqual(self.webrtc_backend_path, webrtc_backend_path) or
                !optionalSlicesEqual(self.webrtc_tun_bind_address, webrtc_tun_bind_address) or
                !optionalDigestsEqual(self.fingerprint_profile_digest, fingerprint_profile_digest) or
                self.client_profile != client_profile or
                self.canvas_driver != canvas_driver or
                self.canvas_fallback != canvas_fallback or
                self.webrtc_mode != webrtc_mode)
            {
                return error.RuntimeOptionsMismatch;
            }
            self.navigation_timeout_ms = if (navigation_timeout_ms == 0) 30_000 else navigation_timeout_ms;
            return self;
        }

        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        self.* = .{
            .navigation_timeout_ms = if (navigation_timeout_ms == 0) 30_000 else navigation_timeout_ms,
            .client_profile = client_profile,
            .fingerprint_profile_digest = fingerprint_profile_digest,
            .canvas_driver = canvas_driver,
            .canvas_fallback = canvas_fallback,
            .webrtc_mode = webrtc_mode,
        };

        if (wreq_transport_path) |path| {
            self.wreq_transport_path = try allocator.dupe(u8, path);
        }
        errdefer if (self.wreq_transport_path) |path| allocator.free(path);
        if (application_locale) |locale| {
            self.application_locale = try allocator.dupeZ(u8, locale);
        }
        errdefer if (self.application_locale) |locale| allocator.free(locale);
        if (timezone) |zone| {
            self.timezone = try allocator.dupeZ(u8, zone);
        }
        errdefer if (self.timezone) |zone| allocator.free(zone);
        if (fingerprint_profile_json) |json| {
            self.fingerprint_profile_json = try allocator.dupe(u8, json);
        }
        errdefer if (self.fingerprint_profile_json) |json| allocator.free(json);
        if (wreq_dns_nameservers) |endpoints| {
            self.wreq_dns_nameservers = try allocator.dupe(u8, endpoints);
        }
        errdefer if (self.wreq_dns_nameservers) |endpoints| allocator.free(endpoints);
        if (canvas_backend_path) |path| {
            self.canvas_backend_path = try allocator.dupe(u8, path);
        }
        errdefer if (self.canvas_backend_path) |path| allocator.free(path);
        if (webrtc_backend_path) |path| {
            self.webrtc_backend_path = try allocator.dupe(u8, path);
        }
        errdefer if (self.webrtc_backend_path) |path| allocator.free(path);
        if (webrtc_tun_bind_address) |address| {
            self.webrtc_tun_bind_address = try allocator.dupe(u8, address);
        }
        errdefer if (self.webrtc_tun_bind_address) |address| allocator.free(address);

        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});

        self.startup_mutex.lock();
        while (!self.startup_done) self.startup_condition.wait(&self.startup_mutex);
        const startup_error = self.startup_error;
        self.startup_mutex.unlock();

        if (startup_error) |err| {
            self.thread.join();
            return err;
        }
        process_runtime = self;
        return self;
    }

    pub fn stop(self: *Runtime) void {
        self.queue_mutex.lock();
        self.stopping = true;
        self.queue_condition.signal();
        self.queue_mutex.unlock();
        self.thread.join();

        for (self.pages.items) |page| allocator.destroy(page);
        self.pages.deinit(allocator);
        if (self.wreq_transport_path) |path| allocator.free(path);
        if (self.application_locale) |locale| allocator.free(locale);
        if (self.timezone) |zone| allocator.free(zone);
        if (self.fingerprint_profile_json) |json| allocator.free(json);
        if (self.wreq_dns_nameservers) |endpoints| allocator.free(endpoints);
        if (self.canvas_backend_path) |path| allocator.free(path);
        if (self.webrtc_backend_path) |path| allocator.free(path);
        if (self.webrtc_tun_bind_address) |address| allocator.free(address);
        allocator.destroy(self);
    }

    /// Logically closes one public Runtime while keeping the process-global
    /// V8 platform and its worker alive. V8 rejects initialization after
    /// DisposePlatform, so subsequent public Runtime handles must reuse this
    /// engine rather than tear it down and attempt to initialize it again.
    pub fn resetForReuse(self: *Runtime, out_error: ?*abi.Error) abi.Status {
        var command = Command.init(.{ .reset = {} });
        self.dispatch(&command);

        self.pages_mutex.lock();
        for (self.pages.items) |page| allocator.destroy(page);
        self.pages.clearRetainingCapacity();
        self.pages_mutex.unlock();

        if (command.status != .ok) {
            self.reusable = false;
            if (out_error) |err| {
                err.* = .{
                    .code = command.status,
                    .message = command.detail,
                };
                command.detail = .{};
            } else {
                abi.freeBytes(&command.detail);
            }
        }
        abi.freeBytes(&command.output);
        return command.status;
    }

    pub fn dispatch(self: *Runtime, command: *Command) void {
        self.queue_mutex.lock();
        if (self.stopping) {
            self.queue_mutex.unlock();
            command.fail(.closed, "runtime is stopping");
            command.complete();
            return;
        }
        self.queue.append(&command.node);
        self.queue_condition.signal();
        self.queue_mutex.unlock();

        command.mutex.lock();
        while (!command.done) command.condition.wait(&command.mutex);
        command.mutex.unlock();
    }

    pub fn addPage(self: *Runtime, page: *PageRef) !void {
        self.pages_mutex.lock();
        defer self.pages_mutex.unlock();
        try self.pages.append(allocator, page);
    }

    fn retain(self: *Runtime) void {
        _ = self.refs.fetchAdd(1, .acq_rel);
    }

    pub fn release(self: *Runtime) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            self.refs_mutex.lock();
            self.refs_condition.broadcast();
            self.refs_mutex.unlock();
        }
    }

    pub fn waitForNoReferences(self: *Runtime) void {
        self.refs_mutex.lock();
        while (self.refs.load(.acquire) != 0) self.refs_condition.wait(&self.refs_mutex);
        self.refs_mutex.unlock();
    }

    /// Env.requestTerminate is explicitly safe from a foreign/network thread.
    /// Epoch checks handle commands cancelled before they become active.
    pub fn interrupt(self: *Runtime, page: ?*PageRef) void {
        const active = self.active_page.load(.acquire);
        if (active == 0) return;
        if (page) |expected| {
            if (active != @intFromPtr(expected)) return;
        }
        const browser_address = self.browser_ptr.load(.acquire);
        if (browser_address == 0) return;
        const browser: *lp.Browser = @ptrFromInt(browser_address);
        browser.env.requestTerminate();
    }
};

pub const PageRef = struct {
    runtime: *Runtime,
    frame_id: u32 = 0,
    network_root_frame_id: std.atomic.Value(u32) = .init(0),
    network_observations: NetworkObservations.Store = .{},
    state: std.atomic.Value(u8) = .init(state_pending),
    /// Monotonic cancellation token. Each operation snapshots it at enqueue;
    /// cancel/close increments it, so a later operation never accidentally
    /// clears cancellation for the currently-running one.
    cancel_epoch: std.atomic.Value(u64) = .init(0),
    slot_index: u32 = 0,
    slot_generation: u32 = 0,

    pub const state_pending: u8 = 0;
    pub const state_open: u8 = 1;
    pub const state_closing: u8 = 2;
    pub const state_closed: u8 = 3;

    pub fn isOpen(self: *const PageRef) bool {
        return self.state.load(.acquire) == state_open;
    }
};

pub const Command = struct {
    node: std.DoublyLinkedList.Node = .{},
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    done: bool = false,
    status: abi.Status = .ok,
    detail: abi.Bytes = .{},
    output: abi.Bytes = .{},
    output_is_error: bool = false,
    op: Operation,

    pub const Operation = union(enum) {
        create_page: *PageRef,
        close_page: *PageRef,
        navigate: struct {
            page: *PageRef,
            url: []const u8,
            timeout_ms: u32,
            cancel_epoch: u64,
        },
        evaluate: struct {
            page: *PageRef,
            script: []const u8,
            promise_timeout_ms: u32,
            cancel_epoch: u64,
        },
        frames: struct {
            page: *PageRef,
            cancel_epoch: u64,
        },
        network_observations: struct {
            page: *PageRef,
            since_sequence: u64,
            cancel_epoch: u64,
        },
        click: struct {
            page: *PageRef,
            selector: []const u8,
            frame_id: u32,
            timeout_ms: u32,
            pierce_shadow: bool,
            move_delay_ms: u32,
            press_delay_ms: u32,
            cancel_epoch: u64,
        },
        identity_manifest: void,
        reset: void,
    };

    pub fn init(op: Operation) Command {
        return .{ .op = op };
    }

    pub fn fail(self: *Command, status: abi.Status, detail: []const u8) void {
        self.status = status;
        if (detail.len == 0) return;
        const owned = allocator.dupe(u8, detail) catch return;
        self.detail = .take(owned);
    }

    fn failError(self: *Command, status: abi.Status, err: anyerror) void {
        self.fail(status, @errorName(err));
    }

    pub fn complete(self: *Command) void {
        self.mutex.lock();
        self.done = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }
};

const WorkerContext = struct {
    runtime: *Runtime,
    config: *lp.Config,
    app: *lp.App,
    browser: *lp.Browser,
    notification: *lp.Notification,

    fn init(runtime: *Runtime) !WorkerContext {
        const config = try allocator.create(lp.Config);
        errdefer allocator.destroy(config);
        config.* = try lp.Config.initCore(allocator, "darkpanda-ffi", .{ .serve = .{} }, .{
            // A foreign call may intentionally spend longer than the CLI's
            // watchdog budget. Cancellation remains cooperative via PageRef.
            .watchdog_ms = 0,
            // The public Runtime navigation timeout must also bound the
            // underlying transfer.
            .http_timeout = @intCast(@min(
                runtime.navigation_timeout_ms,
                std.math.maxInt(u31),
            )),
            .locale = runtime.application_locale,
            .timezone = runtime.timezone,
            .client_profile = runtime.client_profile,
            .wreq_dns_nameservers = runtime.wreq_dns_nameservers,
            .webrtc_tun_bind_address = switch (runtime.webrtc_mode) {
                .disabled => null,
                .tun_bound => runtime.webrtc_tun_bind_address,
            },
        });
        errdefer config.deinit(allocator);

        const canvas_backend_options: ?CanvasBackendProvider.Options = switch (runtime.canvas_driver) {
            .environment => null,
            .software => .{
                .driver = .software,
                .fallback = .disabled,
            },
            .dynamic => .{
                .driver = .dynamic,
                .fallback = switch (runtime.canvas_fallback) {
                    .disabled => .disabled,
                    .software => .software,
                },
                .library_path = runtime.canvas_backend_path,
            },
        };
        const app = try lp.App.initWithOptions(allocator, config, .{
            .wreq_transport_path = runtime.wreq_transport_path,
            .fingerprint_profile_json = runtime.fingerprint_profile_json,
            .canvas_backend_options = canvas_backend_options,
            .webrtc_backend_path = runtime.webrtc_backend_path,
        });
        errdefer app.deinit();

        const browser = try allocator.create(lp.Browser);
        errdefer allocator.destroy(browser);
        try browser.init(app, .{}, null);
        errdefer browser.deinit();

        const notification = try lp.Notification.init(allocator);
        errdefer notification.deinit();
        errdefer notification.unregisterAll(runtime);
        try notification.register(.http_request_start, runtime, onHttpRequestStart);
        try notification.register(.http_response_header_done, runtime, onHttpResponseHeadersDone);
        try notification.register(.http_request_done, runtime, onHttpRequestDone);
        try notification.register(.http_request_fail, runtime, onHttpRequestFail);

        const browser_session = try browser.newSession(notification);
        browser_session.cancel_hook = .{
            .context = runtime,
            .check = cancellationRequested,
        };

        runtime.browser_ptr.store(@intFromPtr(browser), .release);
        return .{
            .runtime = runtime,
            .config = config,
            .app = app,
            .browser = browser,
            .notification = notification,
        };
    }

    fn deinit(self: *WorkerContext) void {
        self.runtime.browser_ptr.store(0, .release);
        self.browser.deinit();
        allocator.destroy(self.browser);
        // Browser.deinit joins every Dedicated Worker owner before listener
        // removal, so no producer can be walking Notification's immutable
        // listener lists when they are unlinked.
        self.notification.unregisterAll(self.runtime);
        self.notification.deinit();
        self.app.deinit();
        self.config.deinit(allocator);
        allocator.destroy(self.config);
    }

    fn session(self: *WorkerContext) *lp.Session {
        return &self.browser.session.?;
    }

    fn execute(self: *WorkerContext, command: *Command) void {
        switch (command.op) {
            .create_page => |page| self.createPage(command, page),
            .close_page => |page| self.closePage(command, page),
            .navigate => |op| self.navigate(command, op.page, op.url, op.timeout_ms, op.cancel_epoch),
            .evaluate => |op| self.evaluate(command, op.page, op.script, op.promise_timeout_ms, op.cancel_epoch),
            .frames => |op| self.frames(command, op.page, op.cancel_epoch),
            .network_observations => |op| self.networkObservations(
                command,
                op.page,
                op.since_sequence,
                op.cancel_epoch,
            ),
            .click => |op| self.click(
                command,
                op.page,
                op.selector,
                op.frame_id,
                op.timeout_ms,
                op.pierce_shadow,
                op.move_delay_ms,
                op.press_delay_ms,
                op.cancel_epoch,
            ),
            .identity_manifest => self.identityManifest(command),
            .reset => self.reset(command),
        }
    }

    fn identityManifest(self: *WorkerContext, command: *Command) void {
        const output = IdentityManifest.build(
            allocator,
            self.app,
            self.browser,
        ) catch |err| {
            command.failError(
                if (err == error.OutOfMemory) .out_of_memory else .internal_error,
                err,
            );
            return;
        };
        command.output = .take(output);
    }

    fn createPage(self: *WorkerContext, command: *Command, page: *PageRef) void {
        if (page.state.load(.acquire) != PageRef.state_pending) {
            command.fail(.closed, "page creation was cancelled");
            return;
        }
        const handle = self.session().createPage() catch |err| {
            page.state.store(PageRef.state_closed, .release);
            command.failError(.internal_error, err);
            return;
        };
        page.frame_id = handle.frame_id;
        page.network_observations.bindOwnerThread();
        page.network_root_frame_id.store(handle.frame_id, .release);
        page.state.store(PageRef.state_open, .release);
    }

    fn closePage(self: *WorkerContext, _: *Command, page: *PageRef) void {
        if (page.frame_id != 0) {
            const handle: lp.Session.PageHandle = .{
                .session = self.session(),
                .frame_id = page.frame_id,
            };
            handle.close();
            self.session().processDestroyQueues();
            page.frame_id = 0;
        }
        page.network_root_frame_id.store(0, .release);
        page.state.store(PageRef.state_closed, .release);
    }

    fn reset(self: *WorkerContext, command: *Command) void {
        for (self.runtime.pages.items) |page| {
            if (page.frame_id != 0) {
                const handle: lp.Session.PageHandle = .{
                    .session = self.session(),
                    .frame_id = page.frame_id,
                };
                handle.close();
                page.frame_id = 0;
            }
            page.network_root_frame_id.store(0, .release);
            page.state.store(PageRef.state_closed, .release);
        }
        self.session().processDestroyQueues();

        // A logical Runtime generation is a fresh browser context, not merely
        // a fresh handle table. Recreate the Session so cookies, web storage,
        // IndexedDB and navigation history cannot leak into the next native
        // caller while the process-global V8 isolate remains alive for safe
        // reuse.
        self.browser.clearPermissions();
        const browser_session = self.browser.newSession(self.notification) catch |err| {
            command.failError(.internal_error, err);
            return;
        };
        browser_session.cancel_hook = .{
            .context = self.runtime,
            .check = cancellationRequested,
        };
    }

    fn navigate(
        self: *WorkerContext,
        command: *Command,
        page: *PageRef,
        url: []const u8,
        requested_timeout_ms: u32,
        cancel_epoch: u64,
    ) void {
        if (!page.isOpen()) {
            command.fail(.closed, "page is closed");
            return;
        }
        self.runtime.active_cancel_epoch.store(cancel_epoch, .release);
        self.runtime.active_page.store(@intFromPtr(page), .release);
        defer {
            self.runtime.active_page.store(0, .release);
            self.browser.env.cancelTerminate();
        }
        if (cancellationRequested(self.runtime)) {
            command.fail(.cancelled, "Cancelled");
            return;
        }

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const url_z = arena.dupeZ(u8, url) catch {
            command.fail(.out_of_memory, "OutOfMemory");
            return;
        };
        const handle: lp.Session.PageHandle = .{
            .session = self.session(),
            .frame_id = page.frame_id,
        };
        const frame = handle.frame() orelse {
            command.fail(.closed, "page frame is unavailable");
            return;
        };
        const encoded_url = lp.URL.resolveNavigation(frame.call_arena, url_z, .{}) catch |err| {
            command.failError(.navigation_failed, err);
            return;
        };
        handle.navigate(encoded_url, .{
            .reason = .address_bar,
            .kind = .{ .push = null },
        }) catch |err| {
            if (cancellationRequested(self.runtime))
                command.fail(.cancelled, "Cancelled")
            else
                command.failError(mapOperationStatus(err, .navigation_failed), err);
            return;
        };

        const timeout_ms = if (requested_timeout_ms == 0)
            self.runtime.navigation_timeout_ms
        else
            requested_timeout_ms;
        var runner = self.session().runner(.{});
        runner.waitForFrame(page.frame_id, timeout_ms, .{ .until = .done }) catch |err| {
            if (cancellationRequested(self.runtime))
                command.fail(.cancelled, "Cancelled")
            else
                command.failError(mapOperationStatus(err, .navigation_failed), err);
        };
    }

    fn evaluate(
        self: *WorkerContext,
        command: *Command,
        page: *PageRef,
        script: []const u8,
        requested_promise_timeout_ms: u32,
        cancel_epoch: u64,
    ) void {
        if (!page.isOpen()) {
            command.fail(.closed, "page is closed");
            return;
        }
        self.runtime.active_cancel_epoch.store(cancel_epoch, .release);
        self.runtime.active_page.store(@intFromPtr(page), .release);
        defer {
            self.runtime.active_page.store(0, .release);
            self.browser.env.cancelTerminate();
        }
        if (cancellationRequested(self.runtime)) {
            command.fail(.cancelled, "Cancelled");
            return;
        }

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const script_z = arena.dupeZ(u8, script) catch {
            command.fail(.out_of_memory, "OutOfMemory");
            return;
        };
        const handle: lp.Session.PageHandle = .{
            .session = self.session(),
            .frame_id = page.frame_id,
        };
        const frame = handle.frame() orelse {
            command.fail(.closed, "page frame is unavailable");
            return;
        };
        const result = lp.Evaluate.run(arena, frame, script_z, .{
            .promise_timeout_ms = if (requested_promise_timeout_ms == 0)
                lp.Evaluate.default_promise_timeout_ms
            else
                requested_promise_timeout_ms,
        }) catch |err| {
            if (cancellationRequested(self.runtime))
                command.fail(.cancelled, "Cancelled")
            else
                command.failError(mapOperationStatus(err, .evaluation_failed), err);
            return;
        };
        if (cancellationRequested(self.runtime)) {
            command.fail(.cancelled, "Cancelled");
            return;
        }
        const owned = allocator.dupe(u8, result.text) catch {
            command.fail(.out_of_memory, "OutOfMemory");
            return;
        };
        command.output = .take(owned);
        command.output_is_error = result.is_error;
    }

    fn frames(
        self: *WorkerContext,
        command: *Command,
        page: *PageRef,
        cancel_epoch: u64,
    ) void {
        if (!page.isOpen()) {
            command.fail(.closed, "page is closed");
            return;
        }
        self.runtime.active_cancel_epoch.store(cancel_epoch, .release);
        self.runtime.active_page.store(@intFromPtr(page), .release);
        defer {
            self.runtime.active_page.store(0, .release);
            self.browser.env.cancelTerminate();
        }
        if (cancellationRequested(self.runtime)) {
            command.fail(.cancelled, "Cancelled");
            return;
        }

        const output = PageAbi.framesJson(allocator, self.session(), page.frame_id) catch |err| {
            command.failError(switch (err) {
                error.PageClosed => .closed,
                error.OutOfMemory => .out_of_memory,
            }, err);
            return;
        };
        command.output = .take(output);
    }

    fn networkObservations(
        self: *WorkerContext,
        command: *Command,
        page: *PageRef,
        since_sequence: u64,
        cancel_epoch: u64,
    ) void {
        _ = self;
        if (!page.isOpen()) {
            command.fail(.closed, "page is closed");
            return;
        }
        if (page.cancel_epoch.load(.acquire) != cancel_epoch) {
            command.fail(.cancelled, "Cancelled");
            return;
        }
        const output = page.network_observations.snapshotJson(
            allocator,
            since_sequence,
        ) catch |err| {
            command.failError(
                if (err == error.OutOfMemory) .out_of_memory else .internal_error,
                err,
            );
            return;
        };
        command.output = .take(output);
    }

    fn click(
        self: *WorkerContext,
        command: *Command,
        page: *PageRef,
        selector: []const u8,
        frame_id: u32,
        requested_timeout_ms: u32,
        pierce_shadow: bool,
        move_delay_ms: u32,
        press_delay_ms: u32,
        cancel_epoch: u64,
    ) void {
        if (!page.isOpen()) {
            command.fail(.closed, "page is closed");
            return;
        }
        self.runtime.active_cancel_epoch.store(cancel_epoch, .release);
        self.runtime.active_page.store(@intFromPtr(page), .release);
        defer {
            self.runtime.active_page.store(0, .release);
            self.browser.env.cancelTerminate();
        }
        if (cancellationRequested(self.runtime)) {
            command.fail(.cancelled, "Cancelled");
            return;
        }

        const timeout_ms = if (requested_timeout_ms == 0)
            self.runtime.navigation_timeout_ms
        else
            requested_timeout_ms;
        PageAbi.click(self.session(), page.frame_id, selector, .{
            .frame_id = frame_id,
            .timeout_ms = timeout_ms,
            .pierce_shadow = pierce_shadow,
            .move_delay_ms = if (move_delay_ms == 0) 16 else move_delay_ms,
            .press_delay_ms = if (press_delay_ms == 0) 60 else press_delay_ms,
        }) catch |err| {
            command.failError(mapClickStatus(err), err);
            return;
        };
        if (cancellationRequested(self.runtime)) {
            command.fail(.cancelled, "Cancelled");
        }
    }
};

fn mapOperationStatus(err: anyerror, fallback: abi.Status) abi.Status {
    return switch (err) {
        error.Cancelled => .cancelled,
        error.Timeout => .timeout,
        error.OutOfMemory => .out_of_memory,
        else => fallback,
    };
}

fn mapClickStatus(err: anyerror) abi.Status {
    return switch (err) {
        error.Cancelled => .cancelled,
        error.Timeout => .timeout,
        error.PageClosed => .closed,
        error.OutOfMemory => .out_of_memory,
        error.FrameNotFound,
        error.FrameDetached,
        error.FrameNotVisible,
        error.ElementDetached,
        error.ElementNotVisible,
        error.ElementHasNoLayoutBox,
        error.ElementHasPointerEventsNone,
        error.ElementObscured,
        error.SyntaxError,
        error.InvalidSelector,
        error.InvalidAttributeSelector,
        error.InvalidIDSelector,
        error.InvalidClassSelector,
        error.UnknownPseudoClass,
        error.InvalidTagSelector,
        error.InvalidPseudoClass,
        error.InvalidNthPattern,
        => .invalid_argument,
        else => .internal_error,
    };
}

fn onHttpRequestStart(
    context: *anyopaque,
    event: *const lp.Notification.RequestStart,
) !void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    recordNetworkObservation(runtime, event.transfer, .start, null, null);
}

fn onHttpResponseHeadersDone(
    context: *anyopaque,
    event: *const lp.Notification.ResponseHeaderDone,
) !void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    recordNetworkObservation(runtime, event.transfer, .headers, event.response.status(), null);
}

fn onHttpRequestDone(
    context: *anyopaque,
    event: *const lp.Notification.RequestDone,
) !void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    recordNetworkObservation(runtime, event.transfer, .done, event.transfer.responseStatus(), null);
}

fn onHttpRequestFail(
    context: *anyopaque,
    event: *const lp.Notification.RequestFail,
) !void {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    // Retain only a fixed, backend-independent category. Raw error names and
    // diagnostic strings can encode transport/environment details.
    recordNetworkObservation(
        runtime,
        event.transfer,
        .fail,
        event.transfer.responseStatus(),
        NetworkObservations.classifyFailure(event.err),
    );
}

fn recordNetworkObservation(
    runtime: *Runtime,
    transfer: *lp.HttpClient.Transfer,
    phase: NetworkObservations.Phase,
    status: ?u16,
    failure_kind: ?NetworkObservations.FailureKind,
) void {
    const root_frame_id = transfer.req.root_frame_id;
    if (root_frame_id == 0) return;

    // PageRef storage is process-stable until resetForReuse, and that function
    // destroys refs only after the browser worker has closed/joined all Worker
    // producers. Holding pages_mutex across the fixed-size record operation
    // also makes that lifetime boundary explicit.
    runtime.pages_mutex.lock();
    defer runtime.pages_mutex.unlock();
    for (runtime.pages.items) |page| {
        if (page.network_root_frame_id.load(.acquire) != root_frame_id) continue;
        page.network_observations.record(.{
            .request_id = transfer.id,
            .phase = phase,
            .frame_id = transfer.req.frame_id,
            .root_frame_id = root_frame_id,
            .resource_type = switch (transfer.req.resource_type) {
                .document => .document,
                .xhr => .xhr,
                .image => .image,
                .script => .script,
                .fetch => .fetch,
                .stylesheet => .stylesheet,
            },
            .status = status,
            .failure_kind = failure_kind,
            .url = transfer.req.url,
            .initiator_context = switch (transfer.req.initiator_context) {
                .page => .page,
                .worker => .worker,
            },
        });
        return;
    }
}

fn cancellationRequested(context: *anyopaque) bool {
    const runtime: *Runtime = @ptrCast(@alignCast(context));
    const address = runtime.active_page.load(.acquire);
    if (address == 0) return false;
    const page: *PageRef = @ptrFromInt(address);
    return page.cancel_epoch.load(.acquire) != runtime.active_cancel_epoch.load(.acquire);
}

fn workerMain(runtime: *Runtime) void {
    var context = WorkerContext.init(runtime) catch |err| {
        runtime.startup_mutex.lock();
        runtime.startup_error = err;
        runtime.startup_done = true;
        runtime.startup_condition.broadcast();
        runtime.startup_mutex.unlock();
        return;
    };
    defer context.deinit();

    runtime.startup_mutex.lock();
    runtime.startup_done = true;
    runtime.startup_condition.broadcast();
    runtime.startup_mutex.unlock();

    while (true) {
        runtime.queue_mutex.lock();
        while (runtime.queue.first == null and !runtime.stopping) {
            runtime.queue_condition.wait(&runtime.queue_mutex);
        }
        if (runtime.queue.first == null and runtime.stopping) {
            runtime.queue_mutex.unlock();
            break;
        }
        const node = runtime.queue.first.?;
        runtime.queue.remove(node);
        runtime.queue_mutex.unlock();

        const command: *Command = @fieldParentPtr("node", node);
        context.execute(command);
        command.complete();
    }
}

const RuntimeSlot = struct {
    ptr: ?*Runtime = null,
    generation: u32 = 1,
};

const PageSlot = struct {
    ptr: ?*PageRef = null,
    generation: u32 = 1,
};

var registry_mutex: std.Thread.Mutex = .{};
var runtime_slots: std.ArrayListUnmanaged(RuntimeSlot) = .empty;
var page_slots: std.ArrayListUnmanaged(PageSlot) = .empty;
// The physical V8/App engine is process-global and persistent, while public
// handles are generation-scoped. Permit one live public Runtime at a time and
// reuse the engine after each logical destroy.
var runtime_lifecycle: enum { empty, reserved, live } = .empty;

pub fn reserveRuntime() bool {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    if (runtime_lifecycle != .empty) return false;
    runtime_lifecycle = .reserved;
    return true;
}

pub fn cancelRuntimeReservation() void {
    registry_mutex.lock();
    runtime_lifecycle = .empty;
    registry_mutex.unlock();
}

pub fn discardCachedRuntime(runtime: *Runtime) void {
    std.debug.assert(process_runtime == runtime);
    process_runtime = null;
}

pub fn registerRuntime(runtime: *Runtime) !u64 {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    std.debug.assert(runtime_lifecycle == .reserved);
    const index = try allocateRuntimeSlot(runtime);
    runtime_lifecycle = .live;
    return makeHandle(index, runtime_slots.items[index].generation);
}

pub fn acquireRuntime(handle: u64) ?*Runtime {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const decoded = decodeHandle(handle) orelse return null;
    if (decoded.index >= runtime_slots.items.len) return null;
    const slot = &runtime_slots.items[decoded.index];
    if (slot.generation != decoded.generation) return null;
    const runtime = slot.ptr orelse return null;
    if (runtime.closing) return null;
    runtime.retain();
    return runtime;
}

pub fn unregisterRuntime(handle: u64) ?*Runtime {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const decoded = decodeHandle(handle) orelse return null;
    if (decoded.index >= runtime_slots.items.len) return null;
    const slot = &runtime_slots.items[decoded.index];
    if (slot.generation != decoded.generation) return null;
    const runtime = slot.ptr orelse return null;

    runtime.closing = true;
    slot.ptr = null;
    slot.generation = nextGeneration(slot.generation);
    for (page_slots.items) |*page_slot| {
        const page = page_slot.ptr orelse continue;
        if (page.runtime != runtime) continue;
        _ = page.cancel_epoch.fetchAdd(1, .acq_rel);
        page.state.store(PageRef.state_closing, .release);
        page_slot.ptr = null;
        page_slot.generation = nextGeneration(page_slot.generation);
    }
    runtime.interrupt(null);
    return runtime;
}

pub fn finishRuntime(runtime: *Runtime) void {
    registry_mutex.lock();
    std.debug.assert(runtime_lifecycle == .live);
    std.debug.assert(runtime.closing);
    runtime.closing = false;
    runtime_lifecycle = .empty;
    registry_mutex.unlock();
}

pub fn registerPage(page: *PageRef) !u64 {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    if (page.runtime.closing or !page.isOpen()) return error.Closed;
    const index = try allocatePageSlot(page);
    page.slot_index = index;
    page.slot_generation = page_slots.items[index].generation;
    return makeHandle(index, page.slot_generation);
}

pub fn acquirePage(handle: u64) ?*PageRef {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const page = resolvePageLocked(handle) orelse return null;
    if (page.runtime.closing or !page.isOpen()) return null;
    page.runtime.retain();
    return page;
}

pub const PageOperationRef = struct {
    page: *PageRef,
    cancel_epoch: u64,
};

pub fn acquirePageOperation(handle: u64) ?PageOperationRef {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const page = resolvePageLocked(handle) orelse return null;
    if (page.runtime.closing or !page.isOpen()) return null;
    const cancel_epoch = page.cancel_epoch.load(.acquire);
    page.runtime.retain();
    return .{ .page = page, .cancel_epoch = cancel_epoch };
}

pub fn unregisterPage(handle: u64) ?*PageRef {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const decoded = decodeHandle(handle) orelse return null;
    if (decoded.index >= page_slots.items.len) return null;
    const slot = &page_slots.items[decoded.index];
    if (slot.generation != decoded.generation) return null;
    const page = slot.ptr orelse return null;
    if (page.runtime.closing or !page.isOpen()) return null;

    page.runtime.retain();
    _ = page.cancel_epoch.fetchAdd(1, .acq_rel);
    page.runtime.interrupt(page);
    page.state.store(PageRef.state_closing, .release);
    slot.ptr = null;
    slot.generation = nextGeneration(slot.generation);
    return page;
}

fn resolvePageLocked(handle: u64) ?*PageRef {
    const decoded = decodeHandle(handle) orelse return null;
    if (decoded.index >= page_slots.items.len) return null;
    const slot = &page_slots.items[decoded.index];
    if (slot.generation != decoded.generation) return null;
    return slot.ptr;
}

fn allocateRuntimeSlot(runtime: *Runtime) !u32 {
    for (runtime_slots.items, 0..) |*slot, index| {
        if (slot.ptr == null) {
            slot.ptr = runtime;
            return @intCast(index);
        }
    }
    if (runtime_slots.items.len >= std.math.maxInt(u32)) return error.OutOfMemory;
    try runtime_slots.append(allocator, .{ .ptr = runtime });
    return @intCast(runtime_slots.items.len - 1);
}

fn allocatePageSlot(page: *PageRef) !u32 {
    for (page_slots.items, 0..) |*slot, index| {
        if (slot.ptr == null) {
            slot.ptr = page;
            return @intCast(index);
        }
    }
    if (page_slots.items.len >= std.math.maxInt(u32)) return error.OutOfMemory;
    try page_slots.append(allocator, .{ .ptr = page });
    return @intCast(page_slots.items.len - 1);
}

const DecodedHandle = struct { index: u32, generation: u32 };

fn makeHandle(index: u32, generation: u32) u64 {
    return (@as(u64, generation) << 32) | (@as(u64, index) + 1);
}

fn decodeHandle(handle: u64) ?DecodedHandle {
    const low: u32 = @truncate(handle);
    const generation: u32 = @truncate(handle >> 32);
    if (low == 0 or generation == 0) return null;
    return .{ .index = low - 1, .generation = generation };
}

fn nextGeneration(current: u32) u32 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

test "generation handles reject zero and preserve slot" {
    const value = makeHandle(41, 9);
    const decoded = decodeHandle(value).?;
    try std.testing.expectEqual(@as(u32, 41), decoded.index);
    try std.testing.expectEqual(@as(u32, 9), decoded.generation);
    try std.testing.expect(decodeHandle(0) == null);
}
