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

// Synthetic user input driving the DOM: mouse, wheel, keyboard, focus
// navigation and text insertion. These are mostly fed by CDP's Input domain
// (src/cdp/domains/input.zig) and by EventManager's default activation
// behavior. Form submission itself lives on the Frame (it's a navigation
// concern); the activation paths here call into it.

const std = @import("std");
const lp = @import("darkpanda");
const builtin = @import("builtin");

const Frame = @import("../Frame.zig");

const Node = @import("../webapi/Node.zig");
const Event = @import("../webapi/Event.zig");
const EventTarget = @import("../webapi/EventTarget.zig");
const Element = @import("../webapi/Element.zig");
const ShadowRoot = @import("../webapi/ShadowRoot.zig");
const TreeWalker = @import("../webapi/TreeWalker.zig");
const Selector = @import("../webapi/selector/Selector.zig");
const MouseEvent = @import("../webapi/event/MouseEvent.zig");
const PointerEvent = @import("../webapi/event/PointerEvent.zig");
const WheelEvent = @import("../webapi/event/WheelEvent.zig");
const KeyboardEvent = @import("../webapi/event/KeyboardEvent.zig");
const Performance = @import("../webapi/Performance.zig");

const log = lp.log;
const IS_DEBUG = builtin.mode == .Debug;

// DOM MouseEvent.button values.
// https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent/button
pub const mouse_button = struct {
    pub const main: i32 = 0; // left
    pub const auxiliary: i32 = 1; // middle
    pub const secondary: i32 = 2; // right
    pub const fourth: i32 = 3; // back
    pub const fifth: i32 = 4; // forward
};

pub const Point = struct {
    x: f64,
    y: f64,
};

pub const PointerState = struct {
    position: ?Point = null,
    // Nodes live in the Page arena. Navigation clears this state before that
    // arena can be released, so retaining the hover target is Frame-lifetime
    // safe and lets repeated moves avoid fabricating enter transitions.
    hover_target: ?*Element = null,
};

pub const ClickOptions = struct {
    /// If omitted, use the centre of the target's current client rect.
    point: ?Point = null,
};

const max_target_depth = 128;

pub const TargetPath = struct {
    page_identity: usize = 0,
    frame_id: u32 = 0,
    len: u8 = 0,
    addresses: [max_target_depth]usize = [_]usize{0} ** max_target_depth,

    fn capture(frame: *Frame, target: *Node) TargetPath {
        var result: TargetPath = .{
            .page_identity = @intFromPtr(frame._page),
            .frame_id = frame._frame_id,
        };
        var current: ?*Node = target;
        while (current) |node| : (current = shadowIncludingParent(frame, node)) {
            if (result.len == max_target_depth) break;
            result.addresses[result.len] = @intFromPtr(node);
            result.len += 1;
        }
        return result;
    }

    fn nearestCommonTarget(self: *const TargetPath, frame: *Frame, release_target: *Node) ?*Node {
        if (self.page_identity != @intFromPtr(frame._page) or self.frame_id != frame._frame_id) {
            return null;
        }

        var current: ?*Node = release_target;
        while (current) |node| : (current = shadowIncludingParent(frame, node)) {
            const address = @intFromPtr(node);
            for (self.addresses[0..self.len]) |pressed_address| {
                if (address == pressed_address) return node;
            }
        }
        return null;
    }
};

/// State which survives the browser-owned press/release task boundary. It
/// deliberately stores only integer node addresses: event-loop work may detach
/// the original target, while release can still find a live common ancestor
/// without dereferencing a stale press pointer.
pub const ClickSequenceState = struct {
    pointer_down_prevented: bool = false,
    mouse_down_prevented: bool = false,
    press_path: TargetPath = .{},
};

const PointerDispatchOptions = struct {
    bubbles: bool = true,
    cancelable: bool = true,
    composed: bool = true,
    button: i32 = -1,
    buttons: u16 = 0,
    detail: u32 = 0,
    is_primary: bool = true,
    related_target: ?*EventTarget = null,
    movement: Point = .{ .x = 0, .y = 0 },
    // Native routing through an iframe reports offsets in the embedded
    // content viewport even though clientX/Y remain in the parent viewport.
    offset: ?Point = null,
    // Chromium emits click as a PointerEvent but fills its coordinate members
    // through the compatibility-mouse integer path.
    compatibility_coordinates: bool = false,
    // One physical input phase supplies one platform timestamp to every DOM
    // event derived from it (for example pointerup/mouseup/click).
    platform_time_stamp_us: ?u64 = null,
    // The final PointerEvent click is also a compatibility mouse event and
    // carries the realm's non-touch InputDeviceCapabilities object.
    compatibility_source_capabilities: bool = false,
};

const MouseDispatchOptions = struct {
    bubbles: bool = true,
    cancelable: bool = true,
    composed: bool = true,
    button: i32 = 0,
    buttons: u16 = 0,
    detail: u32 = 0,
    related_target: ?*EventTarget = null,
    movement: Point = .{ .x = 0, .y = 0 },
    offset: ?Point = null,
    platform_time_stamp_us: ?u64 = null,
};

const EventCoordinates = struct {
    screen: Point,
    offset: Point,
};

fn eventCoordinates(frame: *Frame, target: *Node, point: Point) EventCoordinates {
    const display = frame._session.browser.getDisplay();
    const viewport = frame._page.getViewport();
    const horizontal_chrome = display.outer_width -| viewport.width;
    const left_inset = horizontal_chrome / 2;
    const vertical_chrome = display.outer_height -| viewport.height;
    const top_inset = vertical_chrome -| left_inset;
    var screen = Point{
        .x = point.x + @as(f64, @floatFromInt(display.screen_x)) + @as(f64, @floatFromInt(left_inset)),
        .y = point.y + @as(f64, @floatFromInt(display.screen_y)) + @as(f64, @floatFromInt(top_inset)),
    };

    // clientX/Y are local to the target Frame, while screenX/Y include every
    // embedding iframe's client-space offset.
    var current = frame;
    while (current.iframe) |iframe| {
        const parent = current.parent orelse break;
        const owner = iframe.asElement();
        const owner_rect = owner.getBoundingClientRect(parent);
        // Child client coordinates start at the iframe content viewport, not
        // its outer border-box origin. Chrome adds clientLeft/clientTop at
        // every nesting level (verified with a 4px bordered iframe).
        screen.x += owner_rect.getX() + owner.getClientLeft(parent);
        screen.y += owner_rect.getY() + owner.getClientTop(parent);
        current = parent;
    }

    var offset = point;
    if (target.is(Element)) |element| {
        const rect = element.getBoundingClientRect(frame);
        offset.x -= rect.getX();
        offset.y -= rect.getY();
    }
    return .{ .screen = screen, .offset = offset };
}

fn dispatchPointerEventOn(
    frame: *Frame,
    target: *Node,
    comptime typ: []const u8,
    point: Point,
    opts: PointerDispatchOptions,
) !bool {
    const coords = eventCoordinates(frame, target, point);
    const client = if (opts.compatibility_coordinates) floorPoint(point) else point;
    const screen = if (opts.compatibility_coordinates) floorPoint(coords.screen) else coords.screen;
    const raw_offset = opts.offset orelse coords.offset;
    const offset = if (opts.compatibility_coordinates) roundPoint(raw_offset) else raw_offset;
    const movement = roundPoint(opts.movement);
    const event: *PointerEvent = try .initTrusted(typ, .{
        .bubbles = opts.bubbles,
        .cancelable = opts.cancelable,
        .composed = opts.composed,
        .clientX = client.x,
        .clientY = client.y,
        .screenX = screen.x,
        .screenY = screen.y,
        .offsetX = offset.x,
        .offsetY = offset.y,
        .movementX = movement.x,
        .movementY = movement.y,
        .button = opts.button,
        .buttons = opts.buttons,
        .detail = opts.detail,
        .pointerId = 1,
        .pointerType = "mouse",
        .pressure = 0,
        .width = 1,
        .height = 1,
        .isPrimary = opts.is_primary,
        .relatedTarget = opts.related_target,
    }, frame);

    // Keep the event alive after EventManager.dispatch so callers can observe
    // preventDefault and decide which compatibility/default actions to run.
    const base = event.asEvent();
    if (opts.platform_time_stamp_us) |timestamp| base._time_stamp = timestamp;
    if (opts.compatibility_source_capabilities) {
        event._proto._proto._source_capabilities = try frame.window.inputDeviceCapabilities(false);
    }
    base.acquireRef();
    defer _ = base.releaseRef(frame._page);
    try frame._event_manager.dispatch(target.asEventTarget(), base);
    return base._prevent_default;
}

fn compatibilityMouseCoordinate(value: f64) f64 {
    // Web-exposed compatibility coordinates follow the CSSOM integer path:
    // floor, including for negative fractional positions.
    return @floor(value);
}

fn floorPoint(point: Point) Point {
    return .{ .x = @floor(point.x), .y = @floor(point.y) };
}

fn jsRound(value: f64) f64 {
    // JavaScript Math.round chooses the integer toward +infinity at an exact
    // half: 7.5 -> 8 and -6.5 -> -6. Zig's @round has different negative-tie
    // behavior, so spell out the browser conversion.
    return @floor(value + 0.5);
}

fn roundPoint(point: Point) Point {
    return .{ .x = jsRound(point.x), .y = jsRound(point.y) };
}

fn dispatchMouseEventOnNode(
    frame: *Frame,
    target: *Node,
    comptime typ: []const u8,
    point: Point,
    opts: MouseDispatchOptions,
) !bool {
    const coords = eventCoordinates(frame, target, point);
    const movement = roundPoint(opts.movement);
    const event: *MouseEvent = try .initTrusted(comptime .wrap(typ), .{
        .bubbles = opts.bubbles,
        .cancelable = opts.cancelable,
        .composed = opts.composed,
        .clientX = compatibilityMouseCoordinate(point.x),
        .clientY = compatibilityMouseCoordinate(point.y),
        .screenX = compatibilityMouseCoordinate(coords.screen.x),
        .screenY = compatibilityMouseCoordinate(coords.screen.y),
        // Chrome's MouseEvent compatibility conversion floors viewport and
        // screen coordinates, but JS-rounds local offsets and movement deltas.
        .offsetX = jsRound((opts.offset orelse coords.offset).x),
        .offsetY = jsRound((opts.offset orelse coords.offset).y),
        .movementX = movement.x,
        .movementY = movement.y,
        .button = opts.button,
        .buttons = opts.buttons,
        .detail = opts.detail,
        .relatedTarget = opts.related_target,
    }, frame);

    const base = event.asEvent();
    if (opts.platform_time_stamp_us) |timestamp| base._time_stamp = timestamp;
    base.acquireRef();
    defer _ = base.releaseRef(frame._page);
    try frame._event_manager.dispatch(target.asEventTarget(), base);
    return base._prevent_default;
}

fn shadowIncludingParent(frame: *Frame, node: *Node) ?*Node {
    if (frame._assigned_slots.get(node)) |slot| return slot.asNode();
    if (node._parent) |parent| return parent;
    if (node.is(ShadowRoot)) |shadow| return shadow._host.asNode();
    return null;
}

fn collectTargetPath(frame: *Frame, target: *Node, path: *[max_target_depth]*Node) usize {
    var len: usize = 0;
    var current: ?*Node = target;
    while (current) |node| : (current = shadowIncludingParent(frame, node)) {
        if (len == path.len) break;
        path[len] = node;
        len += 1;
    }
    return len;
}

fn dispatchEnterNodes(
    frame: *Frame,
    nodes: []const *Node,
    point: Point,
    related_target: ?*EventTarget,
    target_offset: ?Point,
    platform_time_stamp_us: u64,
    comptime pointer: bool,
) !void {
    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        const node = nodes[i];
        if (node.is(Element) == null and node._type != .document) continue;
        if (comptime pointer) {
            _ = try dispatchPointerEventOn(frame, node, "pointerenter", point, .{
                .bubbles = false,
                .cancelable = false,
                .composed = false,
                .related_target = related_target,
                .offset = if (node == nodes[0]) target_offset else null,
                .platform_time_stamp_us = platform_time_stamp_us,
            });
        } else {
            _ = try dispatchMouseEventOnNode(frame, node, "mouseenter", point, .{
                .bubbles = false,
                .cancelable = false,
                .composed = false,
                .related_target = related_target,
                .offset = if (node == nodes[0]) target_offset else null,
                .platform_time_stamp_us = platform_time_stamp_us,
            });
        }
    }
}

fn dispatchLeaveNodes(
    frame: *Frame,
    nodes: []const *Node,
    point: Point,
    related_target: ?*EventTarget,
    platform_time_stamp_us: u64,
    comptime pointer: bool,
) !void {
    for (nodes) |node| {
        if (node.is(Element) == null and node._type != .document) continue;
        if (comptime pointer) {
            _ = try dispatchPointerEventOn(frame, node, "pointerleave", point, .{
                .bubbles = false,
                .cancelable = false,
                .composed = false,
                .related_target = related_target,
                .platform_time_stamp_us = platform_time_stamp_us,
            });
        } else {
            _ = try dispatchMouseEventOnNode(frame, node, "mouseleave", point, .{
                .bubbles = false,
                .cancelable = false,
                .composed = false,
                .related_target = related_target,
                .platform_time_stamp_us = platform_time_stamp_us,
            });
        }
    }
}

/// Move the native pointer state to the physical target for the current input
/// phase. Chromium performs the hover transition for mousePressed/mouseReleased
/// coordinates too, but only an actual mouseMoved phase emits pointermove and
/// mousemove. Keep those two operations separate through `emit_move`.
fn updatePointerPositionInFrame(
    frame: *Frame,
    target: *Element,
    point: Point,
    emit_move: bool,
    target_offset: ?Point,
    movement_override: ?Point,
) !void {
    const platform_time_stamp_us = Performance.monotonicMicroseconds();
    const state = &frame._native_pointer_state;
    const previous_position = state.position;
    const movement: Point = if (previous_position) |previous| .{
        .x = point.x - previous.x,
        .y = point.y - previous.y,
    } else .{ .x = 0, .y = 0 };

    const old_target = if (state.hover_target) |old|
        if (old.asNode().isConnected()) old else null
    else
        null;

    if (old_target != target) {
        var old_path: [max_target_depth]*Node = undefined;
        var new_path: [max_target_depth]*Node = undefined;
        const old_len = if (old_target) |old| collectTargetPath(frame, old.asNode(), &old_path) else 0;
        const new_len = collectTargetPath(frame, target.asNode(), &new_path);

        var old_unique = old_len;
        var new_unique = new_len;
        while (old_unique > 0 and new_unique > 0 and
            old_path[old_unique - 1] == new_path[new_unique - 1])
        {
            old_unique -= 1;
            new_unique -= 1;
        }

        const old_related = if (old_target) |old| old.asEventTarget() else null;
        const new_related = target.asEventTarget();
        // Chrome completes the pointer transition chain first, then performs
        // the corresponding compatibility-mouse transition chain.
        if (old_target) |old| {
            _ = try dispatchPointerEventOn(frame, old.asNode(), "pointerout", point, .{
                .related_target = new_related,
                .platform_time_stamp_us = platform_time_stamp_us,
            });
            try dispatchLeaveNodes(frame, old_path[0..old_unique], point, new_related, platform_time_stamp_us, true);
        }

        _ = try dispatchPointerEventOn(frame, target.asNode(), "pointerover", point, .{
            .related_target = old_related,
            .offset = target_offset,
            .platform_time_stamp_us = platform_time_stamp_us,
        });
        try dispatchEnterNodes(frame, new_path[0..new_unique], point, old_related, target_offset, platform_time_stamp_us, true);

        if (old_target) |old| {
            _ = try dispatchMouseEventOnNode(frame, old.asNode(), "mouseout", point, .{
                .related_target = new_related,
                .platform_time_stamp_us = platform_time_stamp_us,
            });
            try dispatchLeaveNodes(frame, old_path[0..old_unique], point, new_related, platform_time_stamp_us, false);
        }
        _ = try dispatchMouseEventOnNode(frame, target.asNode(), "mouseover", point, .{
            .related_target = old_related,
            .offset = target_offset,
            .platform_time_stamp_us = platform_time_stamp_us,
        });
        try dispatchEnterNodes(frame, new_path[0..new_unique], point, old_related, target_offset, platform_time_stamp_us, false);
    }

    if (emit_move) {
        const physical_movement = movement_override orelse movement;
        _ = try dispatchPointerEventOn(frame, target.asNode(), "pointermove", point, .{
            .movement = physical_movement,
            .offset = target_offset,
            .platform_time_stamp_us = platform_time_stamp_us,
        });
        _ = try dispatchMouseEventOnNode(frame, target.asNode(), "mousemove", point, .{
            .movement = physical_movement,
            .offset = target_offset,
            .platform_time_stamp_us = platform_time_stamp_us,
        });
    }
    state.position = point;
    state.hover_target = target;
}

const PhysicalRouteEntry = struct {
    frame: *Frame,
    target: *Element,
    point: Point,
    target_offset: ?Point = null,
};

/// Construct the physical hit route from the target document back to the top
/// document. Entries are stored inner-to-outer. At each iframe boundary the
/// parent client point includes the owner's content-box origin, while the
/// iframe event's offset remains the child-viewport coordinate.
fn physicalRoute(
    frame: *Frame,
    target: *Element,
    point: Point,
    route: *[max_target_depth]PhysicalRouteEntry,
) usize {
    route[0] = .{ .frame = frame, .target = target, .point = point };
    var len: usize = 1;
    var current_frame = frame;
    var current_point = point;
    while (len < route.len) {
        const iframe = current_frame.iframe orelse break;
        const parent = current_frame.parent orelse break;
        const owner = iframe.asElement();
        const rect = owner.getBoundingClientRect(parent);
        const child_point = current_point;
        current_point = .{
            .x = rect.getX() + owner.getClientLeft(parent) + child_point.x,
            .y = rect.getY() + owner.getClientTop(parent) + child_point.y,
        };
        route[len] = .{
            .frame = parent,
            .target = owner,
            .point = current_point,
            .target_offset = child_point,
        };
        len += 1;
        current_frame = parent;
    }
    return len;
}

fn enteredChildFrame(parent: *Frame, owner: *Element) ?*Frame {
    for (parent.child_frames.items) |child| {
        const iframe = child.iframe orelse continue;
        if (iframe.asElement() == owner) return child;
    }
    return null;
}

/// Recover the old cross-document hover route from the per-frame state. The
/// outer frame's hover target is an iframe owner whenever the pointer is in a
/// descendant browsing context, so no page-global DOM pointer is required.
fn enteredFrameRoute(top: *Frame, frames: *[max_target_depth]*Frame) usize {
    frames[0] = top;
    var len: usize = 1;
    var current = top;
    while (len < frames.len) {
        const owner = current._native_pointer_state.hover_target orelse break;
        const child = enteredChildFrame(current, owner) orelse break;
        frames[len] = child;
        len += 1;
        current = child;
    }
    return len;
}

fn pointFromTop(frame: *Frame, top_point: Point) ?Point {
    var descendants: [max_target_depth]*Frame = undefined;
    var len: usize = 0;
    var current = frame;
    while (current.parent != null) {
        if (len == descendants.len) return null;
        descendants[len] = current;
        len += 1;
        current = current.parent.?;
    }

    var point = top_point;
    var i = len;
    while (i > 0) {
        i -= 1;
        const child = descendants[i];
        const parent = child.parent orelse return null;
        const iframe = child.iframe orelse return null;
        const owner = iframe.asElement();
        const rect = owner.getBoundingClientRect(parent);
        point.x -= rect.getX() + owner.getClientLeft(parent);
        point.y -= rect.getY() + owner.getClientTop(parent);
    }
    return point;
}

fn clearPointerPosition(frame: *Frame, point: Point) !void {
    const state = &frame._native_pointer_state;
    const old = state.hover_target orelse return;
    if (!old.asNode().isConnected()) {
        state.hover_target = null;
        state.position = point;
        return;
    }

    var old_path: [max_target_depth]*Node = undefined;
    const old_len = collectTargetPath(frame, old.asNode(), &old_path);
    const platform_time_stamp_us = Performance.monotonicMicroseconds();
    _ = try dispatchPointerEventOn(frame, old.asNode(), "pointerout", point, .{ .platform_time_stamp_us = platform_time_stamp_us });
    try dispatchLeaveNodes(frame, old_path[0..old_len], point, null, platform_time_stamp_us, true);
    _ = try dispatchMouseEventOnNode(frame, old.asNode(), "mouseout", point, .{ .platform_time_stamp_us = platform_time_stamp_us });
    try dispatchLeaveNodes(frame, old_path[0..old_len], point, null, platform_time_stamp_us, false);
    state.hover_target = null;
    state.position = point;
}

/// Route one physical pointer phase through every embedding iframe. Chrome's
/// top-level Input.dispatchMouseEvent first enters each iframe owner (without
/// move/down/up on the owner), then emits the phase in the innermost document.
/// Movement is page-global and therefore uses the top-viewport delta even when
/// two consecutive moves target different frames.
fn updatePhysicalPointerPosition(
    frame: *Frame,
    target: *Element,
    point: Point,
    emit_move: bool,
) !void {
    var route: [max_target_depth]PhysicalRouteEntry = undefined;
    const route_len = physicalRoute(frame, target, point, &route);
    const top_entry = route[route_len - 1];
    const previous_top = top_entry.frame._native_pointer_state.position;
    const movement: Point = if (previous_top) |previous| .{
        .x = top_entry.point.x - previous.x,
        .y = top_entry.point.y - previous.y,
    } else .{ .x = 0, .y = 0 };

    var old_frames: [max_target_depth]*Frame = undefined;
    const old_len = enteredFrameRoute(top_entry.frame, &old_frames);
    var common: usize = 0;
    while (common < old_len and common < route_len and
        old_frames[common] == route[route_len - 1 - common].frame)
    {
        common += 1;
    }

    // Leave obsolete inner documents before their owner iframe transitions in
    // the common ancestor. Cross-document relatedTarget is null in Blink.
    var old_i = old_len;
    while (old_i > common) {
        old_i -= 1;
        const old_frame = old_frames[old_i];
        const old_point = pointFromTop(old_frame, top_entry.point) orelse continue;
        try clearPointerPosition(old_frame, old_point);
    }

    var i = route_len;
    while (i > 0) {
        i -= 1;
        const entry = route[i];
        const innermost = i == 0;
        try updatePointerPositionInFrame(
            entry.frame,
            entry.target,
            entry.point,
            emit_move and innermost,
            entry.target_offset,
            if (emit_move and innermost) movement else null,
        );
    }
}

fn dispatchPointerMove(frame: *Frame, target: *Element, point: Point) !void {
    try updatePhysicalPointerPosition(frame, target, point, true);
}

fn focusForMouseDown(frame: *Frame, element: *Element) !void {
    const html = element.is(Element.Html) orelse return;
    const focusable = switch (html._type) {
        .input => |input| !input.getDisabled(),
        .button => |button| !button.getDisabled(),
        .select => |select| !select.getDisabled(),
        .textarea => |textarea| !textarea.getDisabled(),
        .anchor => element.hasAttributeSafe(comptime .wrap("href")) or
            element.hasAttributeSafe(comptime .wrap("tabindex")),
        else => element.hasAttributeSafe(comptime .wrap("tabindex")),
    };
    if (!focusable) return;

    // Blink stores the innermost focused element only in its own Document.
    // Ancestor document.activeElement is projected from FocusController's
    // focused frame as the corresponding iframe owner, without dispatching a
    // focus/focusin event at that owner. DarkPanda has no page FocusController,
    // so preserve the same observable projection in the ancestor documents.
    var current = frame;
    while (current.iframe) |iframe| {
        const parent = current.parent orelse break;
        parent.document._active_element = iframe.asElement();
        current = parent;
    }
    try element.focusWithSourceCapabilities(
        try frame.window.inputDeviceCapabilities(false),
        frame,
    );
}

/// A complete primary-mouse click generated by browser automation.  Script
/// dispatch remains untrusted; only this browser-owned path creates trusted
/// events.  The ordering and compatibility suppression mirror Chrome 149.
pub fn clickElement(frame: *Frame, target: *Element, opts: ClickOptions) !void {
    const point = opts.point orelse pointForElement(frame, target);

    try dispatchPointerMove(frame, target, point);

    const state = try pressElement(frame, target, point);
    try releaseElement(frame, target, point, state);
}

pub fn pointForElement(frame: *Frame, target: *Element) Point {
    // The faux layout intentionally gives the document containers a very
    // large box so descendants can be positioned without a rendering engine.
    // That box is not the browsing-context viewport: using its centre for a
    // native click produces coordinates tens of millions of pixels outside a
    // child iframe.  Chrome automation treats a body/html click as an in-view
    // viewport click.  Anchor those two document containers to the current
    // browsing context while leaving ordinary element clicks rect-centred.
    switch (target.getTag()) {
        .html, .body => return frameViewportCenter(frame),
        else => {},
    }
    const rect = target.getBoundingClientRect(frame);
    return .{
        .x = rect.getX() + rect.getWidth() / 2.0,
        .y = rect.getY() + rect.getHeight() / 2.0,
    };
}

fn frameViewportCenter(frame: *Frame) Point {
    const size = frameViewportSize(frame);
    return .{ .x = size.x / 2.0, .y = size.y / 2.0 };
}

fn frameViewportSize(frame: *Frame) Point {
    if (frame.iframe) |iframe| {
        if (frame.parent) |parent| {
            const owner = iframe.asElement();
            const rect = owner.getBoundingClientRect(parent);
            // Child client coordinates begin inside the iframe border.  The
            // faux CSS model currently exposes left/top border widths; iframe
            // borders are symmetric for the authored/default cases, so
            // subtract both sides to recover the content viewport.  Falling
            // back to the outer dimension keeps malformed authored borders
            // finite and inside the owner rather than reviving the huge body
            // centre.
            const horizontal_border = owner.getClientLeft(parent) * 2.0;
            const vertical_border = owner.getClientTop(parent) * 2.0;
            const content_width = rect.getWidth() - horizontal_border;
            const content_height = rect.getHeight() - vertical_border;
            const width = if (std.math.isFinite(content_width) and content_width > 0)
                content_width
            else
                rect.getWidth();
            const height = if (std.math.isFinite(content_height) and content_height > 0)
                content_height
            else
                rect.getHeight();
            if (std.math.isFinite(width) and width > 0 and
                std.math.isFinite(height) and height > 0)
            {
                return .{ .x = width, .y = height };
            }
        }
    }

    const viewport = frame._page.getViewport();
    return .{
        .x = @as(f64, @floatFromInt(viewport.width)),
        .y = @as(f64, @floatFromInt(viewport.height)),
    };
}

/// Dispatch the press task. Each individual dispatch completes its own
/// microtask checkpoint before the next event/default action starts.
pub fn pressElement(frame: *Frame, target: *Element, point: Point) !ClickSequenceState {
    return pressElementWithDetail(frame, target, point, 1);
}

fn pressElementWithDetail(frame: *Frame, target: *Element, point: Point, detail: u32) !ClickSequenceState {
    // Input.dispatchMouseEvent treats the coordinates on every phase as a
    // physical pointer position. A press can therefore change hover target,
    // but must not fabricate pointermove/mousemove.
    try updatePhysicalPointerPosition(frame, target, point, false);
    frame.notifyUserActivation();
    const press_path = TargetPath.capture(frame, target.asNode());
    const platform_time_stamp_us = Performance.monotonicMicroseconds();
    const pointer_down_prevented = try dispatchPointerEventOn(frame, target.asNode(), "pointerdown", point, .{
        .button = mouse_button.main,
        .buttons = 1,
        .platform_time_stamp_us = platform_time_stamp_us,
    });

    var mouse_down_prevented = false;
    if (!pointer_down_prevented) {
        mouse_down_prevented = try dispatchMouseEventOnNode(frame, target.asNode(), "mousedown", point, .{
            .button = mouse_button.main,
            .buttons = 1,
            .detail = detail,
            .platform_time_stamp_us = platform_time_stamp_us,
        });
        if (!mouse_down_prevented) try focusForMouseDown(frame, target);
    }

    return .{
        .pointer_down_prevented = pointer_down_prevented,
        .mouse_down_prevented = mouse_down_prevented,
        .press_path = press_path,
    };
}

/// Dispatch the release task and final PointerEvent click. The target is
/// intentionally supplied again so native callers can re-resolve it after an
/// event-loop turn instead of retaining an unsafe DOM pointer.
pub fn releaseElement(frame: *Frame, target: *Element, point: Point, state: ClickSequenceState) !void {
    _ = try releaseElementWithDetail(frame, target, point, state, 1);
}

fn releaseElementWithDetail(
    frame: *Frame,
    target: *Element,
    point: Point,
    state: ClickSequenceState,
    detail: u32,
) !?*Node {
    // A release at a different physical target first performs the same hover
    // transition Chrome performs for mouseReleased, again without move events.
    try updatePhysicalPointerPosition(frame, target, point, false);

    // UI Events targets click at the nearest common shadow-including ancestor
    // of the press and release targets. The press path contains addresses only;
    // every returned node comes from the live release path.
    const click_target = state.press_path.nearestCommonTarget(frame, target.asNode());
    const platform_time_stamp_us = Performance.monotonicMicroseconds();

    _ = try dispatchPointerEventOn(frame, target.asNode(), "pointerup", point, .{
        .button = mouse_button.main,
        .buttons = 0,
        .platform_time_stamp_us = platform_time_stamp_us,
    });
    if (!state.pointer_down_prevented) {
        _ = try dispatchMouseEventOnNode(frame, target.asNode(), "mouseup", point, .{
            .button = mouse_button.main,
            .buttons = 0,
            .detail = detail,
            .platform_time_stamp_us = platform_time_stamp_us,
        });
    }

    if (click_target) |node| {
        // Chrome exposes a PointerEvent for the final click. It retains the
        // mouse pointer identity but reports isPrimary=false for activation.
        _ = try dispatchPointerEventOn(frame, node, "click", point, .{
            .button = mouse_button.main,
            .buttons = 0,
            .detail = detail,
            .is_primary = false,
            .compatibility_coordinates = true,
            .platform_time_stamp_us = platform_time_stamp_us,
            .compatibility_source_capabilities = true,
        });
    }
    return click_target;
}

pub fn movePointerToElement(frame: *Frame, target: *Element, point_: ?Point) !void {
    const point = point_ orelse pointForElement(frame, target);
    try dispatchPointerMove(frame, target, point);
}

/// Browser-internal selector lookup that can cross both open and closed shadow
/// roots.  It is intentionally not wired to Document/Element JS APIs.
pub fn nativeQuerySelector(frame: *Frame, selector: []const u8, pierce_shadow: bool) !?*Element {
    if (!pierce_shadow) {
        return Selector.querySelector(frame.document.asNode(), selector, frame);
    }
    return nativeQueryDescendants(frame, frame.document.asNode(), selector);
}

fn nativeQueryDescendants(frame: *Frame, root: *Node, selector: []const u8) !?*Element {
    var child = root.firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(Element)) |element| {
            if (try Selector.matches(element, selector, frame)) return element;
            if (frame._element_shadow_roots.get(element)) |shadow| {
                if (try nativeQueryDescendants(frame, shadow.asNode(), selector)) |found| return found;
            }
        }
        if (try nativeQueryDescendants(frame, node, selector)) |found| return found;
    }
    return null;
}

/// Browser-internal hit testing over the shadow-including tree.  Closed roots
/// remain opaque to page JavaScript; this is only used by native input paths.
pub fn nativeElementFromPoint(frame: *Frame, point: Point, pierce_shadow: bool) !?*Element {
    if (!pierce_shadow) {
        return frame.window._document.elementFromPoint(point.x, point.y, frame);
    }

    var topmost: ?*Element = null;
    try hitTestDescendants(frame, frame.document.asNode(), point, &topmost);
    return topmost;
}

/// Whether the physical hit target is the selected element or one of its
/// shadow-including descendants. Automation may select a host/button while the
/// actual pointer lands on a rendered descendant, but an unrelated overlay is
/// never accepted as the selected target.
pub fn nativeHitBelongsTo(frame: *Frame, hit: *Element, selected: *Element) bool {
    var current: ?*Node = hit.asNode();
    while (current) |node| : (current = shadowIncludingParent(frame, node)) {
        if (node == selected.asNode()) return true;
    }
    return false;
}

fn hitTestDescendants(frame: *Frame, root: *Node, point: Point, topmost: *?*Element) !void {
    var child = root.firstChild();
    while (child) |node| : (child = node.nextSibling()) {
        if (node.is(Element)) |element| {
            if (element.checkVisibilityCached(null, frame) and !element.hasPointerEventsNone(null, frame)) {
                const rect = element.getBoundingClientRectForVisible(frame);
                const contains = switch (element.getTag()) {
                    // The exposed faux rect remains intentionally large for
                    // non-rendering layout consumers, but physical hit testing
                    // must use the document viewport. Otherwise a correct
                    // 300x65 child-frame point can hit HTML above the fake body
                    // y-offset and fail body actionability as "obscured".
                    .html, .body => blk: {
                        const viewport = frameViewportSize(frame);
                        break :blk point.x >= 0 and point.x <= viewport.x and
                            point.y >= 0 and point.y <= viewport.y;
                    },
                    else => point.x >= rect.getLeft() and point.x <= rect.getRight() and
                        point.y >= rect.getTop() and point.y <= rect.getBottom(),
                };
                if (contains) {
                    topmost.* = element;
                }
            }
        }

        // Light children are visited first; a rendered shadow subtree then
        // replaces/overlays them and therefore wins overlapping hit tests.
        try hitTestDescendants(frame, node, point, topmost);
        if (node.is(Element)) |element| {
            if (frame._element_shadow_roots.get(element)) |shadow| {
                try hitTestDescendants(frame, shadow.asNode(), point, topmost);
            }
        }
    }
}

pub fn clickAt(frame: *Frame, point: Point, pierce_shadow: bool) !bool {
    const target = (try nativeElementFromPoint(frame, point, pierce_shadow)) orelse return false;
    try clickElement(frame, target, .{ .point = point });
    return true;
}

// Dispatch a single trusted mouse event of the given type on `target`, carrying
// the pressed button and pointer position. `detail` is the click count (used for
// click/dblclick); 0 for events where it does not apply.
fn dispatchMouseEventOn(frame: *Frame, target: *Element, comptime typ: []const u8, x: f64, y: f64, button: i32, detail: u32) !void {
    _ = try dispatchMouseEventOnNode(frame, target.asNode(), typ, .{ .x = x, .y = y }, .{
        .button = button,
        .detail = detail,
    });
}

pub fn triggerMousePress(frame: *Frame, x: f64, y: f64, button: i32, click_count: i32) !void {
    if (button == mouse_button.main) {
        frame._native_primary_press_state = null;
    }
    const point: Point = .{ .x = x, .y = y };
    const target = (try nativeElementFromPoint(frame, point, true)) orelse return;
    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame mouse press", .{
            .url = frame.url,
            .node = target,
            .x = x,
            .y = y,
            .button = button,
            .type = frame._type,
        });
    }
    const detail: u32 = if (click_count > 0) @intCast(click_count) else 1;
    if (button == mouse_button.main) {
        frame._native_primary_press_state = try pressElementWithDetail(frame, target, point, detail);
        return;
    }
    try dispatchMouseEventOn(frame, target, "mousedown", x, y, button, detail);
}

pub fn triggerMouseMove(frame: *Frame, x: f64, y: f64) !void {
    const target = (try nativeElementFromPoint(frame, .{ .x = x, .y = y }, true)) orelse return;
    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame mouse move", .{
            .url = frame.url,
            .node = target,
            .x = x,
            .y = y,
            .type = frame._type,
        });
    }

    try movePointerToElement(frame, target, .{ .x = x, .y = y });
}

pub fn triggerMouseRelease(frame: *Frame, x: f64, y: f64, button: i32, click_count: i32) !void {
    const point: Point = .{ .x = x, .y = y };
    const target = (try nativeElementFromPoint(frame, point, true)) orelse {
        if (button == mouse_button.main) {
            frame._native_primary_press_state = null;
        }
        return;
    };
    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame mouse release", .{
            .url = frame.url,
            .node = target,
            .x = x,
            .y = y,
            .button = button,
            .type = frame._type,
        });
    }

    const detail: u32 = if (click_count > 0) @intCast(click_count) else 1;

    if (button == mouse_button.main) {
        const state = frame._native_primary_press_state orelse ClickSequenceState{};
        frame._native_primary_press_state = null;
        const click_target = try releaseElementWithDetail(frame, target, point, state, detail);
        if (click_count == 2 and click_target != null) {
            _ = try dispatchMouseEventOnNode(frame, click_target.?, "dblclick", .{ .x = x, .y = y }, .{
                .button = button,
                .detail = detail,
            });
        }
        return;
    }

    try dispatchMouseEventOn(frame, target, "mouseup", x, y, button, detail);

    // After mouseup, the activation event depends on the button.
    switch (button) {
        mouse_button.main => unreachable,
        mouse_button.auxiliary => try dispatchMouseEventOn(frame, target, "auxclick", x, y, button, detail),
        mouse_button.secondary => try dispatchMouseEventOn(frame, target, "contextmenu", x, y, button, detail),
        else => {},
    }
}

pub fn triggerMouseWheel(frame: *Frame, x: f64, y: f64, delta_x: f64, delta_y: f64) !void {
    const target = (try frame.window._document.elementFromPoint(x, y, frame)) orelse return;
    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame mouse wheel", .{
            .url = frame.url,
            .node = target,
            .x = x,
            .y = y,
            .delta_x = delta_x,
            .delta_y = delta_y,
            .type = frame._type,
        });
    }

    const wheel_event: *WheelEvent = try .initTrusted("wheel", .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clientX = x,
        .clientY = y,
        .deltaX = delta_x,
        .deltaY = delta_y,
    }, frame);

    // Keep the event alive past dispatch so we can read _prevent_default.
    wheel_event.asEvent().acquireRef();
    defer _ = wheel_event.asEvent().releaseRef(frame._page);
    try frame._event_manager.dispatch(target.asEventTarget(), wheel_event.asEvent());

    if (wheel_event.asEvent()._prevent_default) {
        return;
    }

    // Apply the scroll and fire a trusted scroll event, mirroring WebDriver wheel.
    // CDP deltas are untrusted, so guard NaN and saturate the addition.
    const new_left: i32 = @as(i32, @intCast(target.getScrollLeft(frame))) +| deltaToScroll(delta_x);
    const new_top: i32 = @as(i32, @intCast(target.getScrollTop(frame))) +| deltaToScroll(delta_y);
    try target.setScrollLeft(new_left, frame);
    try target.setScrollTop(new_top, frame);

    const scroll_event = try Event.initTrusted(comptime .wrap("scroll"), .{ .bubbles = true }, frame._page);
    try frame._event_manager.dispatch(target.asEventTarget(), scroll_event);
}

fn deltaToScroll(d: f64) i32 {
    if (std.math.isNan(d)) return 0;
    return @intFromFloat(std.math.clamp(d, std.math.minInt(i32), std.math.maxInt(i32)));
}

// callback when the "click" event reaches the frame.
pub fn handleClick(frame: *Frame, target: *Node) !void {
    // TODO: Also support <area> elements when implement
    const element = target.is(Element) orelse return;
    const html_element = element.is(Element.Html) orelse return;

    switch (html_element._type) {
        .anchor => |anchor| {
            const href = element.getAttributeSafe(comptime .wrap("href")) orelse return;
            if (href.len == 0) {
                return;
            }

            if (std.mem.startsWith(u8, href, "javascript:")) {
                return;
            }

            if (try element.hasAttribute(comptime .wrap("download"), frame)) {
                log.warn(.browser, "a.download", .{ .type = frame._type, .url = frame.url });
                return;
            }

            const target_frame = blk: {
                const target_name = anchor.getTarget();
                if (target_name.len == 0) {
                    break :blk target.ownerFrame(frame);
                }
                break :blk frame.resolveTargetFrame(target_name) orelse {
                    log.warn(.not_implemented, "target", .{ .type = frame._type, .url = frame.url, .target = target_name });
                    return;
                };
            };

            frame.scheduleNavigation(href, .{
                .reason = .script,
                .kind = .{ .push = null },
            }, .{ .anchor = target_frame }) catch |err| switch (err) {
                // Anchor default action reports an unsafe attempt to the
                // console but does not throw into the click() caller.
                error.SecurityError => return,
                else => return err,
            };
        },
        .input => |input| {
            // Per HTML §4.10.18.6.4 "Image Button state (type=image)", clicking an
            // image button submits its form. The form-data set already gets the
            // submitter's coordinate fields appended via FormData.collectForm
            // (see src/browser/webapi/net/FormData.zig).
            if (input._input_type == .submit or input._input_type == .image) {
                return frame.submitForm(element, input.getForm(frame), .{});
            }
        },
        .button => |button| {
            if (std.mem.eql(u8, button.getType(), "submit")) {
                return frame.submitForm(element, button.getForm(frame), .{});
            }
        },
        .select, .textarea => {},
        .label => |label| {
            // Per HTML §4.10.4 "The label element", a label's activation
            // behavior is to run the synthetic click activation steps on the
            // labeled control. Mirrors Chrome's HTMLLabelElement::DefaultEventHandler.
            const control = label.getControl(frame) orelse return;
            const control_html = control.is(Element.Html) orelse return;
            try control_html.click(frame);
        },
        .generic => |generic| {
            switch (generic._tag) {
                .summary => {
                    const parent_el = target.parentElement() orelse return;
                    const details = parent_el.is(Element.Html.Details) orelse return;
                    var maybe_prev = element.previousElementSibling();
                    while (maybe_prev) |prev| {
                        if (prev.getTag() == .summary) {
                            // we found a summary element before the clicked one
                            return;
                        }
                        maybe_prev = prev.previousElementSibling();
                    }
                    try details.setOpen(!details.getOpen(), frame);
                },
                else => {},
            }
        },
        else => {},
    }
}

pub fn triggerKeyboard(frame: *Frame, keyboard_event: *KeyboardEvent) !void {
    const event = keyboard_event.asEvent();
    // Dispatch to the effective active element. When nothing is explicitly
    // focused this resolves to <body> (matching `document.activeElement`), so
    // the keydown still fires and its default action — e.g. sequential focus
    // navigation on Tab — can run.
    const element = frame.window._document.getActiveElement() orelse {
        event.deinit(frame._page);
        return;
    };

    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame keydown", .{
            .url = frame.url,
            .node = element,
            .key = keyboard_event._key,
            .type = frame._type,
        });
    }
    try frame._event_manager.dispatch(element.asEventTarget(), event);
}

pub fn handleKeydown(frame: *Frame, target: *Node, event: *Event) !void {
    const keyboard_event = event.is(KeyboardEvent) orelse return;
    const key = keyboard_event.getKey();

    if (key == .Dead) {
        return;
    }

    if (key == .Tab) {
        // tab -> forward, shift+tab -> backwards
        return moveFocus(frame, keyboard_event.getShiftKey() == false);
    }

    if (target.is(Element.Html.Input)) |input| {
        if (key == .Enter) {
            return frame.submitForm(input.asElement(), input.getForm(frame), .{});
        }

        // Don't handle text input for radio/checkbox
        const input_type = input._input_type;
        if (input_type == .radio or input_type == .checkbox) {
            return;
        }

        // Handle printable characters
        if (key.isPrintable()) {
            try input.innerInsert(key.asString(), frame);
        }
        return;
    }

    if (target.is(Element.Html.TextArea)) |textarea| {
        // zig fmt: off
        const append =
            if (key == .Enter) "\n"
            else if (key.isPrintable()) key.asString()
            else return
        ;
        // zig fmt: on
        return textarea.innerInsert(append, frame);
    }
}

// Sequential focus navigation: move `document.activeElement` to the next (Tab)
// or previous (Shift+Tab) focusable element, firing the usual blur/focus events
// via `Element.focus`. The order is fully determined by tabindex + document
// position, so no layout is needed:
//   1. elements with a positive tabindex, in ascending tabindex order;
//   2. then elements with tabindex 0 (or a natively-focusable default), in
//      document order.
// Ties within a group break on document order, and Tab wraps around at the ends.
// https://html.spec.whatwg.org/multipage/interaction.html#sequential-focus-navigation
fn moveFocus(frame: *Frame, forward: bool) !void {
    const document = frame.document;
    const current = document._active_element;

    const current_tab_index = blk: {
        const cur = current orelse break :blk 0;
        const current_html = cur.is(Element.Html) orelse break :blk 0;
        break :blk current_html.getTabIndex();
    };

    // Single document-order pass tracking two candidates:
    //   edge   — the global first (forward) / last (backward) focusable element,
    //            used to wrap around when `current` is at an end, or as the
    //            landing spot when nothing is focused yet.
    //   chosen — the closest focusable element strictly past `current` in the
    //            travel direction.
    var edge: ?*Element = null;
    var edge_tab_index: i32 = 0;

    var chosen: ?*Element = null;
    var chosen_tab_index: i32 = 0;

    var tw = TreeWalker.Full.Elements.init(document.asNode(), .{});
    while (tw.next()) |candidate| {
        if (candidate.isDisabled()) {
            continue;
        }
        if (candidate.is(Element.Html) == null) {
            continue;
        }

        const candidate_tab_index = blk: {
            if (candidate.getAttributeSafe(comptime .wrap("tabindex"))) |attr| {
                if (Element.Html.parseInteger(attr)) |tab_index| {
                    if (tab_index < 0) {
                        continue;
                    }
                    break :blk tab_index;
                }
                break :blk 0;
            }

            // no tab index, maybe this item isn't focusable..
            const focusable = switch (candidate.getTag()) {
                .button, .select, .textarea, .iframe => true,
                .input => candidate.as(Element.Html.Input)._input_type != .hidden,
                .anchor, .area => candidate.getAttributeSafe(comptime .wrap("href")) != null,
                else => false,
            };
            if (focusable == false) {
                continue;
            }

            break :blk 0;
        };

        if (edge == null or focusOrderBefore(candidate, candidate_tab_index, edge.?, edge_tab_index) == forward) {
            edge = candidate;
            edge_tab_index = candidate_tab_index;
        }

        const cur = current orelse continue;

        if (candidate == cur) {
            continue;
        }

        const past = if (forward) focusOrderBefore(cur, current_tab_index, candidate, candidate_tab_index) else focusOrderBefore(candidate, candidate_tab_index, cur, current_tab_index);
        if (!past) {
            continue;
        }
        if (chosen == null or focusOrderBefore(candidate, candidate_tab_index, chosen.?, chosen_tab_index) == forward) {
            chosen = candidate;
            chosen_tab_index = candidate_tab_index;
        }
    }

    const next = chosen orelse edge orelse return;
    try next.focus(frame);
}

// Orders two focusable elements by sequential focus navigation order: positive
// tabindex first (ascending), then tabindex 0, ties broken by document order.
fn focusOrderBefore(a: *Element, a_tab_index: i32, b: *Element, b_tab_index: i32) bool {
    if (a_tab_index == b_tab_index) {
        // Equal tabindex → document order: `a` precedes `b` when `b` follows `a`.
        const FOLLOWING: u16 = 0x04;
        return (a.asNode().compareDocumentPosition(b.asNode()) & FOLLOWING) != 0;
    }

    const group_a: u8 = if (a_tab_index > 0) 0 else 1;
    const group_b: u8 = if (b_tab_index > 0) 0 else 1;
    if (group_a != group_b) {
        return group_a < group_b;
    }

    return a_tab_index < b_tab_index;
}

// insertText is a shortcut to insert text into the active element.
pub fn insertText(frame: *Frame, v: []const u8) !void {
    const html_element = frame.document._active_element orelse return;

    if (html_element.is(Element.Html.Input)) |input| {
        const input_type = input._input_type;
        if (input_type == .radio or input_type == .checkbox) {
            return;
        }

        return input.innerInsert(v, frame);
    }

    if (html_element.is(Element.Html.TextArea)) |textarea| {
        return textarea.innerInsert(v, frame);
    }
}

test "native mouse coordinate quantization matches Chromium negative halves" {
    try std.testing.expectEqual(@as(f64, 20), compatibilityMouseCoordinate(20.75));
    try std.testing.expectEqual(@as(f64, -1), compatibilityMouseCoordinate(-0.75));
    try std.testing.expectEqual(@as(f64, 8), jsRound(7.5));
    try std.testing.expectEqual(@as(f64, -6), jsRound(-6.5));

    const negative = roundPoint(.{ .x = -0.75, .y = -6.5 });
    try std.testing.expectEqual(@as(f64, -1), negative.x);
    try std.testing.expectEqual(@as(f64, -6), negative.y);
}
