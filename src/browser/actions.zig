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

const std = @import("std");
const lp = @import("../darkpanda.zig");
const DOMNode = @import("webapi/Node.zig");
const Element = @import("webapi/Element.zig");
const Event = @import("webapi/Event.zig");
const KeyboardEvent = @import("webapi/event/KeyboardEvent.zig");
const Frame = @import("Frame.zig");
const Session = @import("Session.zig");

fn dispatchInputAndChangeEvents(el: *Element, frame: *Frame) !void {
    const input_evt: *Event = try .initTrusted(comptime .wrap("input"), .{ .bubbles = true }, frame._page);
    frame._event_manager.dispatch(el.asEventTarget(), input_evt) catch |err| {
        lp.log.err(.app, "dispatch input event failed", .{ .err = err });
    };

    const change_evt: *Event = try .initTrusted(comptime .wrap("change"), .{ .bubbles = true }, frame._page);
    frame._event_manager.dispatch(el.asEventTarget(), change_evt) catch |err| {
        lp.log.err(.app, "dispatch change event failed", .{ .err = err });
    };
}

pub fn click(node: *DOMNode, frame: *Frame) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;
    Frame.user_input.clickElement(frame, el, .{}) catch |err| {
        lp.log.err(.app, "click failed", .{ .err = err });
        return error.ActionFailed;
    };
}

pub fn clickAt(node: *DOMNode, point: Frame.user_input.Point, frame: *Frame) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;
    Frame.user_input.clickElement(frame, el, .{ .point = point }) catch |err| {
        lp.log.err(.app, "click at point failed", .{ .err = err });
        return error.ActionFailed;
    };
}

/// Native automation lookup. Unlike Document.querySelector this may pierce a
/// closed shadow tree, but no reference is ever exposed to page JavaScript.
pub fn querySelectorNative(selector: []const u8, pierce_shadow: bool, frame: *Frame) !?*Element {
    return Frame.user_input.nativeQuerySelector(frame, selector, pierce_shadow);
}

pub fn hover(node: *DOMNode, frame: *Frame) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;
    Frame.user_input.movePointerToElement(frame, el, null) catch |err| {
        lp.log.err(.app, "hover failed", .{ .err = err });
        return error.ActionFailed;
    };
}

pub fn press(node: ?*DOMNode, key: []const u8, frame: *Frame) !void {
    const target_el: ?*Element = if (node) |n|
        (n.is(Element) orelse return error.InvalidNodeType)
    else
        null;
    const target = if (target_el) |el| el.asEventTarget() else frame.document.asNode().asEventTarget();
    const canonical = canonicalKey(key);

    const keydown_event: *KeyboardEvent = try .initTrusted(comptime .wrap("keydown"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .key = canonical,
    }, frame);

    frame._event_manager.dispatch(target, keydown_event.asEvent()) catch |err| {
        lp.log.err(.app, "press keydown failed", .{ .err = err });
        return error.ActionFailed;
    };

    if (std.mem.eql(u8, canonical, "Enter") and !keydown_event.asEvent().getDefaultPrevented()) {
        if (target_el) |el| implicitFormSubmit(el, frame) catch |err| {
            // Don't skip keyup on a submit-listener throw — UIs that gate
            // state on keyup (e.g. clearing a "submitting" flag) would hang.
            lp.log.warn(.app, "implicit form submit failed", .{ .err = err });
        };
    }

    const keyup_event: *KeyboardEvent = try .initTrusted(comptime .wrap("keyup"), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .key = canonical,
    }, frame);

    frame._event_manager.dispatch(target, keyup_event.asEvent()) catch |err| {
        lp.log.err(.app, "press keyup failed", .{ .err = err });
        return error.ActionFailed;
    };
}

/// Map common shorthand to the canonical KeyboardEvent.key string so users
/// can type "enter" instead of "Enter" without surprises.
fn canonicalKey(key: []const u8) []const u8 {
    const aliases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "enter", .out = "Enter" },
        .{ .in = "return", .out = "Enter" },
        .{ .in = "\n", .out = "Enter" },
        .{ .in = "\\n", .out = "Enter" },
        .{ .in = "esc", .out = "Escape" },
        .{ .in = "escape", .out = "Escape" },
        .{ .in = "tab", .out = "Tab" },
        .{ .in = "\t", .out = "Tab" },
        .{ .in = "space", .out = " " },
        .{ .in = "backspace", .out = "Backspace" },
        .{ .in = "delete", .out = "Delete" },
        .{ .in = "del", .out = "Delete" },
        .{ .in = "up", .out = "ArrowUp" },
        .{ .in = "down", .out = "ArrowDown" },
        .{ .in = "left", .out = "ArrowLeft" },
        .{ .in = "right", .out = "ArrowRight" },
    };
    for (aliases) |a| {
        if (std.ascii.eqlIgnoreCase(key, a.in)) return a.out;
    }
    return key;
}

fn implicitFormSubmit(el: *Element, frame: *Frame) !void {
    const Input = Element.Html.Input;
    const Button = Element.Html.Button;

    if (el.is(Input)) |input| {
        const form = input.getForm(frame) orelse return;
        const submitter: ?*Element = switch (input._input_type) {
            .submit, .image => el,
            // Non-text controls (checkbox, radio, file, ...) don't trigger
            // implicit submission; only the text-like family does.
            .text, .password, .email, .url, .tel, .search, .number, .date, .time, .@"datetime-local", .month, .week => null,
            else => return,
        };
        return form.requestSubmit(submitter, frame);
    }
    if (el.is(Button)) |button| {
        if (!std.ascii.eqlIgnoreCase(button.getType(), "submit")) return;
        const form = button.getForm(frame) orelse return;
        return form.requestSubmit(el, frame);
    }
}

pub fn selectOption(node: *DOMNode, value: []const u8, frame: *Frame) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;
    const select = el.is(Element.Html.Select) orelse return error.InvalidNodeType;

    select.setValue(value, frame) catch |err| {
        lp.log.err(.app, "select setValue failed", .{ .err = err });
        return error.ActionFailed;
    };

    try dispatchInputAndChangeEvents(el, frame);
}

pub fn setChecked(node: *DOMNode, checked: bool, frame: *Frame) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;
    const input = el.is(Element.Html.Input) orelse return error.InvalidNodeType;

    if (input._input_type != .checkbox and input._input_type != .radio) {
        return error.InvalidNodeType;
    }

    if (input.getChecked() == checked) {
        return;
    }
    if (input._input_type == .radio and !checked) {
        // A click can never uncheck a radio.
        return error.InvalidNodeType;
    }

    // The click's activation behavior (EventManager.ActivationState) toggles
    // the state and fires input and change; setting the state up front would
    // make the click undo it, and dispatching input/change here would double
    // them up.
    try click(node, frame);

    if (input.getChecked() != checked) {
        lp.log.err(.app, "setChecked click prevented", .{});
        return error.ActionFailed;
    }
}

pub fn fill(node: *DOMNode, text: []const u8, frame: *Frame) !void {
    const el = node.is(Element) orelse return error.InvalidNodeType;

    el.focus(frame) catch |err| {
        lp.log.err(.app, "fill focus failed", .{ .err = err });
    };

    if (el.is(Element.Html.Input)) |input| {
        input.setValue(text, frame) catch |err| {
            lp.log.err(.app, "fill input failed", .{ .err = err });
            return error.ActionFailed;
        };
    } else if (el.is(Element.Html.TextArea)) |textarea| {
        textarea.setValue(text, frame) catch |err| {
            lp.log.err(.app, "fill textarea failed", .{ .err = err });
            return error.ActionFailed;
        };
    } else if (el.is(Element.Html.Select)) |select| {
        select.setValue(text, frame) catch |err| {
            lp.log.err(.app, "fill select failed", .{ .err = err });
            return error.ActionFailed;
        };
    } else {
        return error.InvalidNodeType;
    }

    try dispatchInputAndChangeEvents(el, frame);
}

pub fn scroll(node: ?*DOMNode, x: ?i32, y: ?i32, frame: *Frame) !void {
    if (node) |n| {
        const el = n.is(Element) orelse return error.InvalidNodeType;

        if (x) |val| {
            el.setScrollLeft(val, frame) catch |err| {
                lp.log.err(.app, "setScrollLeft failed", .{ .err = err });
                return error.ActionFailed;
            };
        }
        if (y) |val| {
            el.setScrollTop(val, frame) catch |err| {
                lp.log.err(.app, "setScrollTop failed", .{ .err = err });
                return error.ActionFailed;
            };
        }

        const scroll_evt: *Event = try .initTrusted(comptime .wrap("scroll"), .{ .bubbles = true }, frame._page);
        frame._event_manager.dispatch(el.asEventTarget(), scroll_evt) catch |err| {
            lp.log.err(.app, "dispatch scroll event failed", .{ .err = err });
        };
    } else {
        frame.window.scrollTo(.{ .x = x orelse 0 }, y, frame) catch |err| {
            lp.log.err(.app, "scroll failed", .{ .err = err });
            return error.ActionFailed;
        };
    }
}

// Floored to 1 so timeout_ms=0 still gets one check instead of failing outright.
fn remainingMs(timeout_ms: u32, timer: *std.time.Timer) u32 {
    const elapsed: u32 = @intCast(timer.read() / std.time.ns_per_ms);
    return @max(1, timeout_ms -| elapsed);
}

pub fn waitForSelector(selector: [:0]const u8, timeout_ms: u32, frame_id: u32, session: *Session) !*DOMNode {
    var timer = try std.time.Timer.start();
    var runner = session.runner(.{});
    try runner.waitForFrame(frame_id, timeout_ms, .{ .until = .load });

    const el = try runner.waitForSelector(frame_id, selector, remainingMs(timeout_ms, &timer));
    return el.asNode();
}

pub fn waitForScript(script: [:0]const u8, timeout_ms: u32, frame_id: u32, session: *Session) !void {
    var timer = try std.time.Timer.start();
    var runner = session.runner(.{});
    try runner.waitForFrame(frame_id, timeout_ms, .{ .until = .load });

    return runner.waitForScript(frame_id, script, remainingMs(timeout_ms, &timer));
}

pub fn waitForState(state: lp.Config.WaitUntil, timeout_ms: u32, frame_id: u32, session: *Session) !void {
    var runner = session.runner(.{});
    try runner.waitForFrame(frame_id, timeout_ms, .{ .until = state });
}

const testing = @import("../testing.zig");

fn testFrame() !*Frame {
    const frame = try testing.createFrame();
    try frame.navigate("about:blank", .{});
    try testing.waitForFrame();
    return frame;
}

fn testRun(frame: *Frame, source: []const u8) !void {
    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.compileAndRun(source, null);
}

fn testExpectScript(frame: *Frame, source: []const u8) !void {
    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const result = try ls.local.compileAndRun(source, null);
    try testing.expect(result.isTrue());
}

test "browser.actions: native click matches Chrome pointer/mouse chain" {
    defer testing.reset();
    const frame = try testFrame();
    defer testing.test_session.closeAllPages();

    try testRun(frame,
        \\document.body.innerHTML = '<div id="parent"><input id="box" type="checkbox"></div><form id="form"><button id="submit">go</button></form>';
        \\const box = document.getElementById('box');
        \\const parent = document.getElementById('parent');
        \\const form = document.getElementById('form');
        \\const submit = document.getElementById('submit');
        \\window.nativeEvents = [];
        \\window.phases = [];
        \\window.inputTrusted = false;
        \\window.changeTrusted = false;
        \\window.inputCtor = '';
        \\window.changeCtor = '';
        \\window.checkedDuringClick = false;
        \\window.nativeTaskOrder = [];
        \\const eventTypes = ['pointerover','pointerenter','mouseover','mouseenter','pointermove','mousemove','pointerdown','mousedown','focus','focusin','pointerup','mouseup','click'];
        \\for (const type of eventTypes) box.addEventListener(type, function(e) {
        \\  nativeEvents.push({type:e.type, ctor:e.constructor.name, trusted:e.isTrusted, bubbles:e.bubbles, cancelable:e.cancelable, composed:e.composed, button:e.button, buttons:e.buttons, which:e.which, detail:e.detail, x:e.clientX, y:e.clientY, pageX:e.pageX, pageY:e.pageY, screenX:e.screenX, screenY:e.screenY, offsetX:e.offsetX, offsetY:e.offsetY, movementX:e.movementX, movementY:e.movementY, pointerId:e.pointerId, pointerType:e.pointerType, isPrimary:e.isPrimary, pressure:e.pressure});
        \\});
        \\parent.addEventListener('pointerdown', e => phases.push('capture:' + e.eventPhase), true);
        \\box.addEventListener('pointerdown', e => phases.push('target:' + e.eventPhase));
        \\parent.addEventListener('pointerdown', e => phases.push('bubble:' + e.eventPhase));
        \\box.addEventListener('click', () => checkedDuringClick = box.checked);
        \\for (const type of ['pointerdown','mousedown','focus','focusin','pointerup','mouseup']) {
        \\  box.addEventListener(type, () => { nativeTaskOrder.push(type); queueMicrotask(() => nativeTaskOrder.push(type + ':micro')); });
        \\}
        \\box.addEventListener('click', () => { nativeTaskOrder.push('click:' + box.checked); queueMicrotask(() => nativeTaskOrder.push('click:micro:' + box.checked)); });
        \\box.addEventListener('input', e => { inputTrusted = e.isTrusted; inputCtor = e.constructor.name; nativeTaskOrder.push('input'); queueMicrotask(() => nativeTaskOrder.push('input:micro')); });
        \\box.addEventListener('change', e => { changeTrusted = e.isTrusted; changeCtor = e.constructor.name; nativeTaskOrder.push('change'); queueMicrotask(() => nativeTaskOrder.push('change:micro')); });
        \\window.submitSeen = false;
        \\window.submitTrusted = false;
        \\form.addEventListener('submit', e => { submitSeen = true; submitTrusted = e.isTrusted; e.preventDefault(); });
        \\const submitRect = submit.getBoundingClientRect();
        \\window.boxRect = box.getBoundingClientRect();
        \\window.viewportLeftInset = Math.floor(Math.max(0, outerWidth - innerWidth) / 2);
        \\window.viewportTopInset = Math.max(0, Math.max(0, outerHeight - innerHeight) - viewportLeftInset);
        \\window.submitCenter = [submitRect.x + submitRect.width / 2, submitRect.y + submitRect.height / 2];
        \\submit.addEventListener('click', e => window.submitClickPoint = [e.clientX, e.clientY]);
    );

    const box = frame.document.getElementById("box", frame).?;
    try clickAt(box.asNode(), .{ .x = 120, .y = 92.5 }, frame);

    try testExpectScript(frame,
        \\nativeEvents.map(e => e.type).join(',') === 'pointerover,pointerenter,mouseover,mouseenter,pointermove,mousemove,pointerdown,mousedown,focus,focusin,pointerup,mouseup,click' &&
        \\nativeEvents.every(e => e.trusted === true) &&
        \\phases.join(',') === 'capture:1,target:2,bubble:3' &&
        \\nativeEvents[0].ctor === 'PointerEvent' && nativeEvents[0].button === -1 && nativeEvents[0].buttons === 0 && nativeEvents[0].which === 0 && nativeEvents[0].detail === 0 && nativeEvents[0].x === 120 && nativeEvents[0].y === 92.5 &&
        \\nativeEvents[1].bubbles === false && nativeEvents[1].cancelable === false && nativeEvents[1].composed === false &&
        \\nativeEvents[2].ctor === 'MouseEvent' && nativeEvents[2].button === 0 && nativeEvents[2].which === 0 && nativeEvents[2].y === 92 &&
        \\nativeEvents[4].button === -1 && nativeEvents[4].which === 0 && nativeEvents[4].pointerId === 1 && nativeEvents[4].pointerType === 'mouse' && nativeEvents[4].isPrimary === true && nativeEvents[4].pressure === 0 &&
        \\nativeEvents[6].detail === 0 && nativeEvents[6].button === 0 && nativeEvents[6].buttons === 1 && nativeEvents[6].which === 1 && nativeEvents[6].isPrimary === true &&
        \\nativeEvents[7].detail === 1 && nativeEvents[7].buttons === 1 && nativeEvents[7].which === 1 &&
        \\nativeEvents[10].detail === 0 && nativeEvents[10].buttons === 0 && nativeEvents[10].which === 1 && nativeEvents[10].isPrimary === true &&
        \\nativeEvents[11].detail === 1 && nativeEvents[11].buttons === 0 && nativeEvents[11].which === 1 &&
        \\nativeEvents[10].y === 92.5 && nativeEvents[10].offsetY === 92.5 - boxRect.y &&
        \\nativeEvents[12].ctor === 'PointerEvent' && nativeEvents[12].detail === 1 && nativeEvents[12].buttons === 0 && nativeEvents[12].which === 1 && nativeEvents[12].pointerId === 1 && nativeEvents[12].pointerType === 'mouse' && nativeEvents[12].isPrimary === false &&
        \\nativeEvents[12].x === 120 && nativeEvents[12].y === 92 && nativeEvents[12].pageX === 120 + scrollX && nativeEvents[12].pageY === 92 + scrollY &&
        \\nativeEvents[12].screenX === Math.floor(screenX + viewportLeftInset + 120) && nativeEvents[12].screenY === Math.floor(screenY + viewportTopInset + 92.5) &&
        \\nativeEvents[12].offsetX === Math.round(120 - boxRect.x) && nativeEvents[12].offsetY === Math.round(92.5 - boxRect.y) && nativeEvents[12].movementX === 0 && nativeEvents[12].movementY === 0 &&
        \\nativeTaskOrder.join(',') === 'pointerdown,pointerdown:micro,mousedown,mousedown:micro,focus,focus:micro,focusin,focusin:micro,pointerup,pointerup:micro,mouseup,mouseup:micro,click:true,click:micro:true,input,input:micro,change,change:micro' &&
        \\document.activeElement === box && box.checked && checkedDuringClick && inputTrusted && changeTrusted && inputCtor === 'Event' && changeCtor === 'Event'
    );

    const submit = frame.document.getElementById("submit", frame).?;
    try click(submit.asNode(), frame);
    try testExpectScript(frame,
        \\submitSeen && submitTrusted && submitClickPoint[0] === Math.floor(submitCenter[0]) && submitClickPoint[1] === Math.floor(submitCenter[1])
    );
}

test "browser.actions: native mouse focus carries Chrome UIEvent context" {
    defer testing.reset();
    const frame = try testFrame();
    defer testing.test_session.closeAllPages();

    try testRun(frame,
        \\document.body.innerHTML = '<button id="a">alpha</button><button id="b">beta</button>';
        \\const a = document.getElementById('a');
        \\const b = document.getElementById('b');
        \\window.contextEvents = [];
        \\const contextTypes = ['pointerdown','mousedown','focus','focusin','blur','focusout','pointerup','mouseup','click'];
        \\for (const target of [a,b]) for (const type of contextTypes) target.addEventListener(type, event => contextEvents.push({
        \\  type, target:event.target.id, ctor:event.constructor.name,
        \\  related:event.relatedTarget && event.relatedTarget.id,
        \\  cap:event.sourceCapabilities, view:event.view,
        \\  detail:event.detail, timeStamp:event.timeStamp,
        \\}));
        \\a.focus();
        \\a.blur();
        \\window.scriptFocusEvents = contextEvents.slice();
        \\contextEvents.length = 0;
    );

    // HTMLElement.focus()/blur() produce trusted FocusEvents but have no input
    // device initiator. They still expose the target realm as UIEvent.view.
    try testExpectScript(frame,
        \\scriptFocusEvents.map(event => event.type).join(',') === 'focus,focusin,blur,focusout' &&
        \\scriptFocusEvents.every(event => event.ctor === 'FocusEvent' && event.cap === null && event.view === window && event.detail === 0)
    );

    try click(frame.document.getElementById("a", frame).?.asNode(), frame);
    try click(frame.document.getElementById("b", frame).?.asNode(), frame);

    try testExpectScript(frame,
        \\contextEvents.map(event => event.type).join(',') === 'pointerdown,mousedown,focus,focusin,pointerup,mouseup,click,pointerdown,mousedown,blur,focusout,focus,focusin,pointerup,mouseup,click' &&
        \\contextEvents.every(event => event.view === window) &&
        \\contextEvents[0].cap === null && contextEvents[4].cap === null && contextEvents[7].cap === null && contextEvents[13].cap === null &&
        \\contextEvents.filter((_, index) => ![0,4,7,13].includes(index)).every(event => event.cap instanceof InputDeviceCapabilities && event.cap.firesTouchEvents === false && event.cap === contextEvents[1].cap) &&
        \\contextEvents[9].target === 'a' && contextEvents[9].related === 'b' &&
        \\contextEvents[10].target === 'a' && contextEvents[10].related === 'b' &&
        \\contextEvents[11].target === 'b' && contextEvents[11].related === 'a' &&
        \\contextEvents[12].target === 'b' && contextEvents[12].related === 'a' &&
        \\contextEvents[0].timeStamp === contextEvents[1].timeStamp &&
        \\contextEvents[4].timeStamp === contextEvents[5].timeStamp && contextEvents[5].timeStamp === contextEvents[6].timeStamp &&
        \\contextEvents[7].timeStamp === contextEvents[8].timeStamp &&
        \\contextEvents[13].timeStamp === contextEvents[14].timeStamp && contextEvents[14].timeStamp === contextEvents[15].timeStamp &&
        \\contextEvents[0].detail === 0 && contextEvents[1].detail === 1 &&
        \\contextEvents[2].detail === 0 && contextEvents[4].detail === 0 &&
        \\contextEvents[5].detail === 1 && contextEvents[6].detail === 1 &&
        \\contextEvents[6].ctor === 'PointerEvent'
    );
}

test "browser.actions: cancellation and script clicks preserve trust boundary" {
    defer testing.reset();
    const frame = try testFrame();
    defer testing.test_session.closeAllPages();

    try testRun(frame,
        \\document.body.innerHTML = '<button id="mouseCancel">mouse</button><button id="pointerCancel">pointer</button><input id="rollback" type="checkbox"><button id="scripted">script</button>';
        \\const mouseCancel = document.getElementById('mouseCancel');
        \\const pointerCancel = document.getElementById('pointerCancel');
        \\const rollback = document.getElementById('rollback');
        \\const scripted = document.getElementById('scripted');
        \\window.mouseCancelEvents = [];
        \\window.pointerCancelEvents = [];
        \\for (const t of ['pointerdown','mousedown','focus','focusin','pointerup','mouseup','click']) {
        \\  mouseCancel.addEventListener(t, e => mouseCancelEvents.push(t));
        \\  pointerCancel.addEventListener(t, e => pointerCancelEvents.push(t));
        \\}
        \\mouseCancel.addEventListener('mousedown', e => e.preventDefault(), {capture:true});
        \\pointerCancel.addEventListener('pointerdown', e => e.preventDefault(), {capture:true});
        \\window.rollbackInput = 0;
        \\window.rollbackChange = 0;
        \\window.rollbackDuringClick = false;
        \\window.rollbackDuringClickMicro = false;
        \\rollback.addEventListener('click', e => { rollbackDuringClick = rollback.checked; e.preventDefault(); queueMicrotask(() => rollbackDuringClickMicro = rollback.checked); });
        \\rollback.addEventListener('input', () => rollbackInput++);
        \\rollback.addEventListener('change', () => rollbackChange++);
        \\window.scriptClicks = [];
        \\scripted.addEventListener('click', e => scriptClicks.push({trusted:e.isTrusted, ctor:e.constructor.name, pointerId:e.pointerId, detail:e.detail}));
    );

    try click(frame.document.getElementById("mouseCancel", frame).?.asNode(), frame);
    try click(frame.document.getElementById("pointerCancel", frame).?.asNode(), frame);
    try click(frame.document.getElementById("rollback", frame).?.asNode(), frame);

    try testRun(frame,
        \\rollback.blur();
        \\scripted.click();
        \\scripted.dispatchEvent(new PointerEvent('click', {bubbles:true, cancelable:true, composed:true}));
    );
    try testExpectScript(frame,
        \\mouseCancelEvents.join(',') === 'pointerdown,mousedown,pointerup,mouseup,click' &&
        \\pointerCancelEvents.join(',') === 'pointerdown,pointerup,click' &&
        \\rollbackDuringClick === true && rollbackDuringClickMicro === true && rollback.checked === false && rollbackInput === 0 && rollbackChange === 0 &&
        \\scriptClicks.length === 2 && scriptClicks.every(e => e.trusted === false) &&
        \\scriptClicks[0].ctor === 'PointerEvent' && scriptClicks[0].pointerId === -1 && scriptClicks[0].detail === 0 &&
        \\document.activeElement === document.body
    );
}

test "browser.actions: native selector and hit test pierce closed shadow roots" {
    defer testing.reset();
    const frame = try testFrame();
    defer testing.test_session.closeAllPages();

    try testRun(frame,
        \\document.body.innerHTML = '<div id="host"></div>';
        \\const host = document.getElementById('host');
        \\const root = host.attachShadow({mode:'closed'});
        \\root.innerHTML = '<input id="secret" type="checkbox">';
        \\const secret = root.querySelector('#secret');
        \\window.shadowInternal = null;
        \\window.shadowOuter = null;
        \\window.hostEnterTargets = [];
        \\secret.addEventListener('click', e => shadowInternal = {trusted:e.isTrusted, target:e.target === secret, first:e.composedPath()[0] === secret});
        \\host.addEventListener('click', e => shadowOuter = {trusted:e.isTrusted, target:e.target === host, first:e.composedPath()[0] === host});
        \\host.addEventListener('pointerenter', e => hostEnterTargets.push(e.target === host));
    );

    try testExpectScript(frame, "document.querySelector('#secret') === null && host.shadowRoot === null");
    const secret = (try querySelectorNative("#secret", true, frame)).?;
    try testing.expect((try querySelectorNative("#secret", false, frame)) == null);

    const rect = secret.getBoundingClientRect(frame);
    const point: Frame.user_input.Point = .{
        .x = rect.getX() + rect.getWidth() / 2,
        .y = rect.getY() + rect.getHeight() / 2,
    };
    try testing.expect((try Frame.user_input.nativeElementFromPoint(frame, point, true)) == secret);
    try click(secret.asNode(), frame);

    try testExpectScript(frame,
        \\shadowInternal && shadowInternal.trusted && shadowInternal.target && shadowInternal.first &&
        \\shadowOuter && shadowOuter.trusted && shadowOuter.target && shadowOuter.first &&
        \\hostEnterTargets.length === 1 && hostEnterTargets[0] === true && secret.checked === true &&
        \\root.activeElement === secret && document.activeElement === host &&
        \\document.querySelector('#secret') === null && host.shadowRoot === null
    );
}

test "browser.actions: pointer state and mouse coordinate fields persist across moves" {
    defer testing.reset();
    const frame = try testFrame();
    defer testing.test_session.closeAllPages();

    try testRun(frame,
        \\document.body.innerHTML = '<button id="move" style="width:160px;height:100px">move</button><div style="width:2000px;height:2000px"></div>';
        \\const move = document.getElementById('move');
        \\window.transitions = [];
        \\window.moves = [];
        \\for (const type of ['pointerover','pointerenter','mouseover','mouseenter']) {
        \\  move.addEventListener(type, event => transitions.push(type));
        \\}
        \\for (const type of ['pointermove','mousemove']) {
        \\  move.addEventListener(type, event => moves.push({
        \\    type, ctor:event.constructor.name, clientX:event.clientX, clientY:event.clientY,
        \\    pageX:event.pageX, pageY:event.pageY, screenX:event.screenX, screenY:event.screenY,
        \\    offsetX:event.offsetX, offsetY:event.offsetY,
        \\    movementX:event.movementX, movementY:event.movementY
        \\  }));
        \\}
    );
    try scroll(null, 11, 13, frame);

    const target = frame.document.getElementById("move", frame).?;
    const rect = target.getBoundingClientRect(frame);
    const first: Frame.user_input.Point = .{
        .x = rect.getX() + 20.75,
        .y = rect.getY() + 15.5,
    };
    const second: Frame.user_input.Point = .{
        .x = first.x + 7.5,
        .y = first.y + 4.5,
    };
    try Frame.user_input.movePointerToElement(frame, target, first);
    try Frame.user_input.movePointerToElement(frame, target, second);

    try testExpectScript(frame,
        \\transitions.join(',') === 'pointerover,pointerenter,mouseover,mouseenter' &&
        \\moves.length === 4 && moves[0].type === 'pointermove' && moves[1].type === 'mousemove' &&
        \\moves[2].type === 'pointermove' && moves[3].type === 'mousemove' &&
        \\moves[0].movementX === 0 && moves[0].movementY === 0 &&
        \\moves[2].movementX === 8 && moves[2].movementY === 5 &&
        \\moves[3].movementX === 8 && moves[3].movementY === 5 &&
        \\moves[0].pageX === moves[0].clientX + window.scrollX && moves[0].pageY === moves[0].clientY + window.scrollY &&
        \\moves[0].screenX === moves[0].clientX + window.screenX + Math.floor(Math.max(0, outerWidth - innerWidth) / 2) &&
        \\moves[0].screenY === moves[0].clientY + window.screenY + Math.max(0, Math.max(0, outerHeight - innerHeight) - Math.floor(Math.max(0, outerWidth - innerWidth) / 2)) &&
        \\moves[0].offsetX === 20.75 && moves[0].offsetY === 15.5 &&
        \\moves[1].offsetX === 21 && moves[1].offsetY === 16
    );
}

test "browser.actions: release targets the nearest common live ancestor" {
    defer testing.reset();
    const frame = try testFrame();
    defer testing.test_session.closeAllPages();

    try testRun(frame,
        \\document.body.innerHTML = '<div id="common"><button id="pressed">pressed</button><button id="released">released</button></div>';
        \\const common = document.getElementById('common');
        \\const pressed = document.getElementById('pressed');
        \\const released = document.getElementById('released');
        \\window.pressClicks = 0;
        \\window.releaseClicks = 0;
        \\window.commonClickTarget = null;
        \\window.releaseEvents = [];
        \\for (const type of ['pointerout','pointerleave','pointerover','pointerenter','mouseout','mouseleave','mouseover','mouseenter','pointermove','mousemove','pointerup','mouseup','click']) {
        \\  document.addEventListener(type, event => releaseEvents.push(type + ':' + (event.target.id || event.target.nodeName)), true);
        \\}
        \\pressed.addEventListener('click', () => pressClicks++);
        \\released.addEventListener('click', () => releaseClicks++);
        \\common.addEventListener('click', event => commonClickTarget = event.target);
    );

    const pressed = frame.document.getElementById("pressed", frame).?;
    const released = frame.document.getElementById("released", frame).?;
    const state = try Frame.user_input.pressElement(
        frame,
        pressed,
        Frame.user_input.pointForElement(frame, pressed),
    );
    try testRun(frame, "releaseEvents.length = 0");
    try Frame.user_input.releaseElement(
        frame,
        released,
        Frame.user_input.pointForElement(frame, released),
        state,
    );

    try testExpectScript(frame,
        \\pressClicks === 0 && releaseClicks === 0 && commonClickTarget === common &&
        \\releaseEvents.join(',') === 'pointerout:pressed,pointerleave:pressed,pointerover:released,pointerenter:released,mouseout:pressed,mouseleave:pressed,mouseover:released,mouseenter:released,pointerup:released,mouseup:released,click:common'
    );
}

test "browser.actions: child-frame click follows the top-level physical pointer route" {
    defer testing.reset();
    const parent = try testFrame();
    defer testing.test_session.closeAllPages();

    try testRun(parent,
        \\document.body.textContent = '';
        \\const owner = document.createElement('iframe');
        \\owner.id = 'owner'; owner.width = '300'; owner.height = '65';
        \\owner.style.cssText = 'border:4px solid transparent;box-sizing:border-box';
        \\document.body.appendChild(owner);
        \\window.parentEvents = [];
        \\window.parentActivationBefore = [navigator.userActivation.isActive, navigator.userActivation.hasBeenActive];
        \\for (const type of ['pointerover','pointerenter','mouseover','mouseenter','pointermove','mousemove','pointerdown','mousedown','focus','focusin','pointerup','mouseup','click']) {
        \\  owner.addEventListener(type, event => parentEvents.push({
        \\    type, ctor:event.constructor.name, trusted:event.isTrusted,
        \\    bubbles:event.bubbles, cancelable:event.cancelable, composed:event.composed,
        \\    clientX:event.clientX, clientY:event.clientY,
        \\    screenX:event.screenX, screenY:event.screenY,
        \\    offsetX:event.offsetX, offsetY:event.offsetY,
        \\    movementX:event.movementX, movementY:event.movementY,
        \\    button:event.button, buttons:event.buttons, detail:event.detail,
        \\    pointerId:event.pointerId, pointerType:event.pointerType,
        \\    isPrimary:event.isPrimary, pressure:event.pressure,
        \\    active:navigator.userActivation.isActive,
        \\    sticky:navigator.userActivation.hasBeenActive,
        \\  }));
        \\}
    );

    try testing.expectEqual(@as(usize, 1), parent.child_frames.items.len);
    const child = parent.child_frames.items[0];
    try testRun(child,
        \\document.body.innerHTML = '<input id="box" type="checkbox" style="margin:11px;width:13px;height:13px">';
        \\const box = document.getElementById('box');
        \\window.childEvents = [];
        \\window.childActivationBefore = [navigator.userActivation.isActive, navigator.userActivation.hasBeenActive];
        \\for (const type of ['pointerover','pointerenter','mouseover','mouseenter','pointermove','mousemove','pointerdown','mousedown','focus','focusin','pointerup','mouseup','click']) {
        \\  box.addEventListener(type, event => childEvents.push({
        \\    type, ctor:event.constructor.name, trusted:event.isTrusted,
        \\    clientX:event.clientX, clientY:event.clientY,
        \\    screenX:event.screenX, screenY:event.screenY,
        \\    offsetX:event.offsetX, offsetY:event.offsetY,
        \\    movementX:event.movementX, movementY:event.movementY,
        \\    button:event.button, buttons:event.buttons, detail:event.detail,
        \\    pointerId:event.pointerId, pointerType:event.pointerType,
        \\    isPrimary:event.isPrimary, pressure:event.pressure,
        \\    active:navigator.userActivation.isActive,
        \\    sticky:navigator.userActivation.hasBeenActive,
        \\  }));
        \\}
    );

    const box = child.document.getElementById("box", child).?;
    const child_point = Frame.user_input.pointForElement(child, box);
    try clickAt(box.asNode(), child_point, child);

    try testExpectScript(parent,
        \\parentActivationBefore[0] === false && parentActivationBefore[1] === false &&
        \\navigator.userActivation.isActive === true && navigator.userActivation.hasBeenActive === true &&
        \\document.activeElement === owner &&
        \\parentEvents.map(event => event.type).join(',') === 'pointerover,pointerenter,mouseover,mouseenter' &&
        \\parentEvents.every(event => event.trusted === true && event.active === false && event.sticky === false) &&
        \\parentEvents[0].ctor === 'PointerEvent' && parentEvents[0].button === -1 && parentEvents[0].buttons === 0 && parentEvents[0].detail === 0 &&
        \\parentEvents[0].pointerId === 1 && parentEvents[0].pointerType === 'mouse' && parentEvents[0].isPrimary === true && parentEvents[0].pressure === 0 &&
        \\parentEvents[0].bubbles === true && parentEvents[0].cancelable === true && parentEvents[0].composed === true &&
        \\parentEvents[1].bubbles === false && parentEvents[1].cancelable === false && parentEvents[1].composed === false &&
        \\parentEvents[2].ctor === 'MouseEvent' && parentEvents[2].button === 0 && parentEvents[2].buttons === 0 && parentEvents[2].detail === 0 &&
        \\parentEvents[3].bubbles === false && parentEvents[3].cancelable === false && parentEvents[3].composed === false &&
        \\parentEvents.every(event => event.movementX === 0 && event.movementY === 0)
    );

    try testExpectScript(child,
        \\childActivationBefore[0] === false && childActivationBefore[1] === false &&
        \\navigator.userActivation.isActive === true && navigator.userActivation.hasBeenActive === true &&
        \\document.activeElement === box && box.checked === true &&
        \\childEvents.map(event => event.type).join(',') === 'pointerover,pointerenter,mouseover,mouseenter,pointermove,mousemove,pointerdown,mousedown,focus,focusin,pointerup,mouseup,click' &&
        \\childEvents.every(event => event.trusted === true) &&
        \\childEvents.slice(0, 6).every(event => event.active === false && event.sticky === false) &&
        \\childEvents.slice(6).every(event => event.active === true && event.sticky === true) &&
        \\childEvents[4].ctor === 'PointerEvent' && childEvents[4].button === -1 && childEvents[4].buttons === 0 && childEvents[4].detail === 0 &&
        \\childEvents[4].pointerId === 1 && childEvents[4].pointerType === 'mouse' && childEvents[4].isPrimary === true && childEvents[4].pressure === 0 &&
        \\childEvents[4].movementX === 0 && childEvents[4].movementY === 0 &&
        \\childEvents[6].buttons === 1 && childEvents[6].detail === 0 && childEvents[6].isPrimary === true &&
        \\childEvents[7].buttons === 1 && childEvents[7].detail === 1 &&
        \\childEvents[10].buttons === 0 && childEvents[10].detail === 0 && childEvents[10].isPrimary === true &&
        \\childEvents[11].buttons === 0 && childEvents[11].detail === 1 &&
        \\childEvents[12].ctor === 'PointerEvent' && childEvents[12].buttons === 0 && childEvents[12].detail === 1 &&
        \\childEvents[12].pointerId === 1 && childEvents[12].pointerType === 'mouse' && childEvents[12].isPrimary === false
    );

    // Parent iframe events use top-viewport client coordinates but the child
    // viewport for offsetX/Y. Both realms share the same physical screen point.
    try testExpectScript(parent,
        \\(() => {
        \\  const rect = owner.getBoundingClientRect();
        \\  const pointer = parentEvents[0];
        \\  const mouse = parentEvents[2];
        \\  return pointer.clientX === rect.x + owner.clientLeft + pointer.offsetX &&
        \\    pointer.clientY === rect.y + owner.clientTop + pointer.offsetY &&
        \\    mouse.clientX === Math.floor(pointer.clientX) && mouse.clientY === Math.floor(pointer.clientY) &&
        \\    mouse.offsetX === Math.round(pointer.offsetX) && mouse.offsetY === Math.round(pointer.offsetY);
        \\})()
    );
    try testExpectScript(child,
        \\childEvents[4].screenX === childEvents[0].screenX && childEvents[4].screenY === childEvents[0].screenY &&
        \\childEvents[5].screenX === Math.floor(childEvents[4].screenX) && childEvents[5].screenY === Math.floor(childEvents[4].screenY)
    );
}

test "browser.actions: cross-origin sibling keeps its own UserActivation state" {
    defer testing.reset();
    const parent = try testFrame();
    defer testing.test_session.closeAllPages();

    try testRun(parent,
        \\document.body.textContent = '';
        \\const targetOwner = document.createElement('iframe');
        \\targetOwner.id = 'activation-target-owner';
        \\const siblingOwner = document.createElement('iframe');
        \\siblingOwner.id = 'activation-sibling-owner';
        \\document.body.append(targetOwner, siblingOwner);
        \\window.rootActivationRef = navigator.userActivation;
        \\window.siblingActivationReport = null;
        \\addEventListener('message', event => {
        \\  if (event.data?.kind !== 'sibling-activation') return;
        \\  siblingActivationReport = {
        \\    live: event.data.live,
        \\    stableIdentity: event.data.stableIdentity,
        \\    snapshot: event.userActivation ? {
        \\      active: event.userActivation.isActive,
        \\      sticky: event.userActivation.hasBeenActive,
        \\    } : null,
        \\    snapshotDistinctFromRoot:
        \\      event.userActivation !== navigator.userActivation,
        \\  };
        \\});
    );

    try testing.expectEqual(@as(usize, 2), parent.child_frames.items.len);
    const target = parent.child_frames.items[0];
    const sibling = parent.child_frames.items[1];

    // Materialize each Navigator/UserActivation wrapper in its owning realm
    // before comparing them from the initially same-origin parent.
    try testRun(target,
        \\document.body.innerHTML = '<button id="activation-target">go</button>';
        \\window.targetActivationRef = navigator.userActivation;
    );
    try testRun(sibling,
        \\window.siblingActivationRef = navigator.userActivation;
    );
    try testExpectScript(parent,
        \\(() => {
        \\  const targetWindow = document.getElementById('activation-target-owner').contentWindow;
        \\  const siblingWindow = document.getElementById('activation-sibling-owner').contentWindow;
        \\  const targetActivation = targetWindow.navigator.userActivation;
        \\  const siblingActivation = siblingWindow.navigator.userActivation;
        \\  return targetWindow.navigator !== navigator &&
        \\    siblingWindow.navigator !== navigator &&
        \\    targetWindow.navigator !== siblingWindow.navigator &&
        \\    targetActivation !== rootActivationRef &&
        \\    siblingActivation !== rootActivationRef &&
        \\    targetActivation !== siblingActivation &&
        \\    targetActivation === targetWindow.navigator.userActivation &&
        \\    siblingActivation === siblingWindow.navigator.userActivation;
        \\})()
    );

    // The tuples are deliberately distinct.  Chromium's second propagation
    // pass may activate a same-origin peer, but never this unrelated sibling.
    try parent.js.setOriginKey("https://parent.activation.test");
    try target.js.setOriginKey("https://target.activation.test");
    try sibling.js.setOriginKey("https://sibling.activation.test");

    const button = target.document.getElementById("activation-target", target).?;
    const point = Frame.user_input.pointForElement(target, button);
    try clickAt(button.asNode(), point, target);

    try testExpectScript(parent,
        \\navigator.userActivation.isActive === true &&
        \\navigator.userActivation.hasBeenActive === true &&
        \\navigator.userActivation === rootActivationRef
    );
    try testExpectScript(target,
        \\navigator.userActivation.isActive === true &&
        \\navigator.userActivation.hasBeenActive === true &&
        \\navigator.userActivation === targetActivationRef
    );
    try testExpectScript(sibling,
        \\navigator.userActivation.isActive === false &&
        \\navigator.userActivation.hasBeenActive === false &&
        \\navigator.userActivation === siblingActivationRef
    );

    // The data payload exercises the live Navigator-owned object.  The event
    // snapshot is captured independently from source_window._frame at call
    // time; both must agree that the sibling remained inactive.
    try testRun(sibling,
        \\parent.postMessage({
        \\  kind: 'sibling-activation',
        \\  stableIdentity: navigator.userActivation === siblingActivationRef,
        \\  live: {
        \\    active: navigator.userActivation.isActive,
        \\    sticky: navigator.userActivation.hasBeenActive,
        \\  },
        \\}, {targetOrigin: '*', includeUserActivation: true});
    );
    {
        var hs: lp.js.HandleScope = undefined;
        const entered = parent.js.enter(&hs);
        defer entered.exit();
        try parent.js.scheduler.run();
    }
    try testExpectScript(parent,
        \\siblingActivationReport !== null &&
        \\siblingActivationReport.stableIdentity === true &&
        \\siblingActivationReport.live.active === false &&
        \\siblingActivationReport.live.sticky === false &&
        \\siblingActivationReport.snapshot.active === false &&
        \\siblingActivationReport.snapshot.sticky === false &&
        \\siblingActivationReport.snapshotDistinctFromRoot === true
    );
}
