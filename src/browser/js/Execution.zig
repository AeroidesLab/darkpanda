// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! Execution context for worker-compatible APIs.
//!
//! This provides a common interface for APIs that work in both Window and Worker
//! contexts. Instead of taking `*Frame` (which is DOM-specific), these APIs take
//! `*Execution` which abstracts the common infrastructure.
//!
//! The bridge constructs an Execution on-the-fly from the current context,
//! whether it's a Page context or a Worker context.

const std = @import("std");
const lp = @import("darkpanda");

const Context = @import("Context.zig");
const Scheduler = @import("Scheduler.zig");
const Page = @import("../Page.zig");
const Session = @import("../Session.zig");
const Factory = @import("../Factory.zig");
const HttpClient = @import("../HttpClient.zig");
const OwnerMailbox = @import("../OwnerMailbox.zig");
const EventManagerBase = @import("../EventManagerBase.zig");

const Event = @import("../webapi/Event.zig");
const EventTarget = @import("../webapi/EventTarget.zig");
const Performance = @import("../webapi/Performance.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

const Execution = @This();

js: *Context,

// Fields named to match Page for generic code (executor._factory works for both)
buf: []u8,
arena: Allocator,
call_arena: Allocator,
local_arena: Allocator,

page: *Page,
session: *Session,
_factory: *Factory,
_scheduler: *Scheduler,

// Pointer to the url field (Page or WorkerGlobalScope) - allows access to current url even after navigation
url: *[:0]const u8,

// Pointer to the charset field of the global (Page or WorkerGlobalScope).
charset: *[]const u8,

// Returns the current base URL of the global scope.
pub fn base(self: *const Execution) [:0]const u8 {
    return self.js.global.base();
}

/// The JavaScript realm can outlive the browsing/worker context which created
/// it. Synchronous ECMAScript (including microtasks) remains valid, while Web
/// APIs which create timers, I/O, or workers must observe the stopped context.
pub fn isShuttingDown(self: *const Execution) bool {
    return switch (self.js.global) {
        .frame => |frame| frame.isRetired(),
        .worker => |worker| worker.isShuttingDown(),
    };
}

pub fn dupeString(self: *const Execution, value: []const u8) ![]const u8 {
    if (String.intern(value)) |v| {
        return v;
    }
    return self.arena.dupe(u8, value);
}

pub fn getArena(self: *const Execution, size_or_bucket: anytype, debug: []const u8) !Allocator {
    return self.page.getArena(size_or_bucket, debug);
}

pub fn releaseArena(self: *const Execution, allocator: Allocator) void {
    self.page.releaseArena(allocator);
}

pub fn headersForRequest(self: *const Execution, headers: *HttpClient.Headers) !void {
    return switch (self.js.global) {
        inline else => |g| g.headersForRequest(headers),
    };
}

pub fn isSameOrigin(self: *const Execution, url: [:0]const u8) bool {
    return switch (self.js.global) {
        inline else => |g| g.isSameOrigin(url),
    };
}

pub fn makeRequest(self: *const Execution, req: HttpClient.Request) !void {
    return switch (self.js.global) {
        inline else => |g| g.makeRequest(req),
    };
}

pub fn getBroadcastChannels(self: *const Execution) *std.DoublyLinkedList {
    return switch (self.js.global) {
        inline else => |g| &g._broadcast_channels,
    };
}

// The global's serialized origin (e.g. "https://example.com"), or null for an
// opaque origin.
pub fn origin(self: *const Execution) ?[]const u8 {
    return switch (self.requestOrigin()) {
        .tuple => |tuple| tuple,
        .legacy_derive_from_initiator_url, .none, .@"opaque" => null,
    };
}

/// Security authority for Fetch/CORS/Fetch Metadata. This must not be derived
/// from `url` because Worker base URLs can be blob: or data: while their
/// SecurityOrigin is respectively inherited or explicitly opaque.
pub fn requestOrigin(self: *const Execution) HttpClient.RequestOrigin {
    return switch (self.js.global) {
        inline else => |g| g.requestOrigin(),
    };
}

/// URL selected by the environment settings object's outgoing-referrer
/// algorithm. It is independent from both the API base URL and SecurityOrigin.
pub fn outgoingReferrerUrl(self: *const Execution) ?[]const u8 {
    return switch (self.js.global) {
        inline else => |g| g.outgoingReferrerUrl(),
    };
}

pub fn siteForCookies(self: *const Execution) HttpClient.SiteForCookies {
    return switch (self.js.global) {
        inline else => |g| g.siteForCookies(),
    };
}

// HttpClient.Owner of the current global (Frame or WGS). Used by code
// that needs to register an in-flight network operation against the
// owning scope without caring whether it's a Frame or a Worker — e.g.
// WebSocket.init appending to `.websockets`.
pub fn httpOwner(self: *const Execution) *HttpClient.Owner {
    return switch (self.js.global) {
        inline else => |g| &g._http_owner,
    };
}

/// Network client owned by this event-loop agent. Window globals use the
/// Browser client on the browser thread; DedicatedWorker globals use the
/// Runtime-local client on the worker thread. APIs shared by both globals must
/// not reach through Session, otherwise Worker completions dispatch from the
/// browser thread into the worker isolate.
pub fn httpClient(self: *const Execution) *HttpClient {
    return switch (self.js.global) {
        .frame => |frame| &frame._session.browser.http_client,
        .worker => |worker| worker._http_client,
    };
}

/// Event-loop mailbox whose owner is this Execution's OS thread. Producers may
/// retain a Sender across Window/Worker boundaries, but only the corresponding
/// Browser or DedicatedWorkerRuntime drains it.
pub fn ownerMailbox(self: *const Execution) *OwnerMailbox.Mailbox {
    return switch (self.js.global) {
        .frame => |frame| &frame._session.browser.owner_mailbox,
        .worker => |worker| worker._owner_mailbox,
    };
}

/// Acquire this realm's retained delivery handle on its owner thread. The
/// Sender itself may then cross threads and safely outlive realm teardown.
pub fn ownerSender(self: *const Execution) OwnerMailbox.TargetError!OwnerMailbox.Sender {
    return self.js.ownerSender();
}

pub fn dispatch(
    self: *const Execution,
    target: *EventTarget,
    event: *Event,
    handler: anytype,
    comptime opts: EventManagerBase.DispatchDirectOptions,
) !void {
    return switch (self.js.global) {
        inline else => |g| g.dispatch(target, event, handler, opts),
    };
}

pub fn hasDirectListeners(self: *const Execution, target: *EventTarget, typ: []const u8, handler: anytype) bool {
    return switch (self.js.global) {
        inline else => |g| g.hasDirectListeners(target, typ, handler),
    };
}

pub fn performance(self: *const Execution) *Performance {
    return switch (self.js.global) {
        inline else => |g| g.performance(),
    };
}

pub fn frameId(self: *const Execution) u32 {
    return switch (self.js.global) {
        inline else => |g| g._frame_id,
    };
}

pub fn loaderId(self: *const Execution) u32 {
    return switch (self.js.global) {
        inline else => |g| g._loader_id,
    };
}
