"""Local-only Page.frames/Page.click acceptance through the Python ABI.

The fixture intentionally contains both a hidden retry frame and a visible
300x65 frame with a closed-shadow checkbox. Selection is based only on generic
frame metadata; the runtime and test contain no production-site identifiers.
"""

from __future__ import annotations

import argparse
import contextlib
import http.server
import json
import math
import threading
from typing import Iterator

from darkpanda import ClientProfile, DarkPandaError, Runtime, Status


ROOT_HTML = b"""<!doctype html><meta charset=utf-8>
<script>
window.clickReport = null;
addEventListener('message', event => {
  if (event.data && event.data.kind === 'trusted-click-report') {
    clickReport = event.data;
  }
});
</script>
<iframe id=hidden style="display:none;width:0;height:0" src="/child?hidden"></iframe>
<iframe id=visible width=300 height=65 style="border:4px solid transparent;box-sizing:border-box" src="/child?visible"></iframe>
<button id=phase-target style="width:120px;height:40px">phase target</button>
<script>
const phaseTarget = document.getElementById('phase-target');
window.phaseTargetClicks = 0;
window.phaseOverlayUps = 0;
window.phaseOverlayClicks = 0;
phaseTarget.addEventListener('click', () => phaseTargetClicks++);
phaseTarget.addEventListener('pointerdown', () => {
  setTimeout(() => {
    const overlay = document.createElement('button');
    overlay.id = 'phase-overlay';
    overlay.textContent = 'overlay';
    overlay.style.cssText = `width:${phaseTarget.offsetWidth}px;height:${phaseTarget.offsetHeight}px`;
    overlay.addEventListener('pointerup', () => phaseOverlayUps++);
    overlay.addEventListener('click', () => phaseOverlayClicks++);
    const container = phaseTarget.parentNode;
    container.insertBefore(overlay, phaseTarget);
    container.appendChild(phaseTarget);
  }, 5);
});
</script>
"""


VIEWPORT_ROOT_HTML = b"""<!doctype html><meta charset=utf-8>
<script>
window.viewportClickReports = [];
addEventListener('message', event => {
  if (event.data && event.data.kind === 'viewport-click-report') {
    viewportClickReports.push(event.data);
  }
});
</script>
<iframe id=viewport width=300 height=65 style="border:0;display:block" src="/viewport-child"></iframe>
"""


VIEWPORT_CHILD_HTML = b"""<!doctype html><meta charset=utf-8>
<style>html,body { margin:0; width:100%; height:100%; display:block }</style>
<body tabindex=0><script>
const events = [];
let clickIndex = 0;
for (const type of ['pointerover','pointerenter','mouseover','mouseenter',
                    'pointermove','mousemove','pointerdown','mousedown','focus',
                    'focusin','pointerup','mouseup','click']) {
  addEventListener(type, event => {
    const first = event.composedPath && event.composedPath()[0];
    events.push({
      type,
      trusted: event.isTrusted,
      first: first && first.tagName || '',
      clientX: event.clientX === undefined ? null : event.clientX,
      clientY: event.clientY === undefined ? null : event.clientY,
      button: event.button === undefined ? null : event.button,
      buttons: event.buttons === undefined ? null : event.buttons
    });
  }, true);
}
addEventListener('click', () => {
  const report = {
    kind: 'viewport-click-report',
    click: ++clickIndex,
    events: events.splice(0)
  };
  queueMicrotask(() => parent.postMessage(report, '*'));
});
</script>
"""


CHILD_HTML = b"""<!doctype html><meta charset=utf-8>
<div id=host style="width:300px;height:65px"></div>
<script>
const root = host.attachShadow({mode: 'closed'});
root.innerHTML = '<input id="secret" type="checkbox">';
const secret = root.querySelector('#secret');
const chain = [];
const taskOrder = [];
const times = {};
for (const type of ['pointerover','pointerenter','mouseover','mouseenter',
                    'pointermove','mousemove','pointerdown','mousedown','focus',
                    'focusin','pointerup','mouseup','click']) {
  secret.addEventListener(type, event => {
    chain.push({
      type, trusted: event.isTrusted, ctor: event.constructor.name,
      clientX: event.clientX, clientY: event.clientY,
      pageX: event.pageX, pageY: event.pageY,
      screenX: event.screenX, screenY: event.screenY,
      offsetX: event.offsetX, offsetY: event.offsetY,
      movementX: event.movementX, movementY: event.movementY
    });
    if (type === 'pointermove' || type === 'pointerdown' || type === 'pointerup') {
      times[type] = performance.now();
    }
    if (type === 'pointermove') {
      setTimeout(() => taskOrder.push('hover:timer'), 5);
    }
  });
}
for (const type of ['pointerdown','mousedown','focus','focusin','pointerup','mouseup']) {
  secret.addEventListener(type, () => {
    taskOrder.push(type);
    queueMicrotask(() => taskOrder.push(type + ':micro'));
    if (type === 'pointerdown') {
      setTimeout(() => taskOrder.push('down:timer'), 5);
    }
  });
}
secret.addEventListener('click', event => {
  taskOrder.push('click:' + secret.checked);
  queueMicrotask(() => taskOrder.push('click:micro:' + secret.checked));
});
secret.addEventListener('input', event => {
  taskOrder.push('input:' + event.isTrusted);
  queueMicrotask(() => taskOrder.push('input:micro'));
});
secret.addEventListener('change', event => {
  taskOrder.push('change:' + event.isTrusted);
  queueMicrotask(() => {
    taskOrder.push('change:micro');
    parent.postMessage({
      kind: 'trusted-click-report',
      chain,
      taskOrder,
      checked: secret.checked,
      active: root.activeElement === secret && document.activeElement === host,
      hoverToDown: times.pointerdown - times.pointermove,
      downToUp: times.pointerup - times.pointerdown
    }, '*');
  });
});
</script>
"""


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path.startswith("/viewport-child"):
            body = VIEWPORT_CHILD_HTML
        elif self.path.startswith("/viewport-root"):
            body = VIEWPORT_ROOT_HTML
        elif self.path.startswith("/child"):
            body = CHILD_HTML
        else:
            body = ROOT_HTML
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        del format, args


@contextlib.contextmanager
def fixture_server() -> Iterator[str]:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address[:2]
        yield f"http://{host}:{port}/"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq", required=True)
    args = parser.parse_args()

    with fixture_server() as url, Runtime(
        library_path=args.library,
        wreq_library_path=args.wreq,
        navigation_timeout_ms=15_000,
        profile=ClientProfile.CHROME149,
    ) as runtime:
        with runtime.new_page() as page:
            page.navigate(url, timeout_ms=15_000)

            frames = page.frames(attached=True)
            roots = [frame for frame in frames if frame.is_root]
            assert len(roots) == 1 and roots[0].parent_frame_id is None
            children = [frame for frame in frames if not frame.is_root]
            assert len(children) == 2, children
            visible_children = [
                frame for frame in page.frames(visible=True, attached=True)
                if not frame.is_root
            ]
            assert len(visible_children) == 1, visible_children
            visible = visible_children[0]
            assert visible.owner_rect is not None
            assert visible.owner_rect.width == 300 and visible.owner_rect.height == 65
            hidden = next(frame for frame in children if not frame.visible)
            window_metrics = json.loads(
                page.evaluate(
                    """JSON.stringify((() => {
                      const iframe = document.getElementById('visible');
                      const rect = iframe.getBoundingClientRect();
                      return {
                        screenX, screenY, outerWidth, outerHeight, innerWidth, innerHeight,
                        iframeX: rect.x, iframeY: rect.y,
                        iframeClientLeft: iframe.clientLeft,
                        iframeClientTop: iframe.clientTop
                      };
                    })())"""
                )
            )
            assert window_metrics["iframeClientLeft"] == 4
            assert window_metrics["iframeClientTop"] == 4

            try:
                page.click("#secret", hidden.frame_id, True, 1_000)
            except DarkPandaError as error:
                assert error.status == Status.INVALID_ARGUMENT
                assert "FrameNotVisible" in str(error)
            else:
                raise AssertionError("clicking a hidden/zero-rect owner frame succeeded")

            page.click("#secret", visible.frame_id, True, 5_000, 16, 60)
            report = json.loads(
                page.evaluate(
                    """new Promise((resolve, reject) => {
                      const deadline = Date.now() + 5000;
                      const poll = () => {
                        if (clickReport) return resolve(clickReport);
                        if (Date.now() >= deadline) return reject(new Error('click report timeout'));
                        setTimeout(poll, 5);
                      };
                      poll();
                    })""",
                    promise_timeout_ms=7_000,
                )
            )

            expected_chain = [
                "pointerover", "pointerenter", "mouseover", "mouseenter",
                "pointermove", "mousemove", "pointerdown", "mousedown",
                "focus", "focusin", "pointerup", "mouseup", "click",
            ]
            assert [event["type"] for event in report["chain"]] == expected_chain
            assert all(event["trusted"] for event in report["chain"])
            assert report["chain"][-1]["ctor"] == "PointerEvent"
            assert report["checked"] is True and report["active"] is True
            assert report["taskOrder"] == [
                "hover:timer",
                "pointerdown", "pointerdown:micro", "mousedown", "mousedown:micro",
                "focus", "focus:micro", "focusin", "focusin:micro",
                "down:timer",
                "pointerup", "pointerup:micro", "mouseup", "mouseup:micro",
                "click:true", "click:micro:true", "input:true", "input:micro",
                "change:true", "change:micro",
            ]
            assert report["hoverToDown"] >= 12, report
            assert report["downToUp"] >= 50, report

            event_by_type = {event["type"]: event for event in report["chain"]}
            pointer_move = event_by_type["pointermove"]
            mouse_move = event_by_type["mousemove"]
            pointer_up = event_by_type["pointerup"]
            click = event_by_type["click"]
            left_inset = max(0, window_metrics["outerWidth"] - window_metrics["innerWidth"]) // 2
            top_inset = max(
                0,
                max(0, window_metrics["outerHeight"] - window_metrics["innerHeight"])
                - left_inset,
            )
            expected_screen_x = (
                window_metrics["screenX"] + left_inset + window_metrics["iframeX"]
                + window_metrics["iframeClientLeft"] + pointer_move["clientX"]
            )
            expected_screen_y = (
                window_metrics["screenY"] + top_inset + window_metrics["iframeY"]
                + window_metrics["iframeClientTop"] + pointer_move["clientY"]
            )
            assert pointer_move["screenX"] == expected_screen_x
            assert pointer_move["screenY"] == expected_screen_y
            assert pointer_move["movementX"] == 0 and pointer_move["movementY"] == 0
            assert mouse_move["clientX"] == math.floor(pointer_move["clientX"])
            assert mouse_move["clientY"] == math.floor(pointer_move["clientY"])
            assert mouse_move["screenX"] == math.floor(pointer_move["screenX"])
            assert mouse_move["screenY"] == math.floor(pointer_move["screenY"])
            assert mouse_move["offsetX"] == math.floor(pointer_move["offsetX"] + 0.5)
            assert mouse_move["offsetY"] == math.floor(pointer_move["offsetY"] + 0.5)
            assert click["clientX"] == math.floor(pointer_up["clientX"])
            assert click["clientY"] == math.floor(pointer_up["clientY"])
            assert click["screenX"] == math.floor(pointer_up["screenX"])
            assert click["screenY"] == math.floor(pointer_up["screenY"])
            assert click["offsetX"] == math.floor(pointer_up["offsetX"] + 0.5)
            assert click["offsetY"] == math.floor(pointer_up["offsetY"] + 0.5)
            assert click["movementX"] == 0 and click["movementY"] == 0

            # The fixed coordinate is re-hit-tested after the press delay. A
            # generic overlay inserted by a timer receives the release, the
            # original target is not activated, and the API reports obscuring.
            try:
                page.click(
                    "#phase-target",
                    timeout_ms=1_000,
                    move_delay_ms=10,
                    press_delay_ms=30,
                )
            except DarkPandaError as error:
                assert error.status == Status.INVALID_ARGUMENT
                assert "ElementObscured" in str(error)
            else:
                raise AssertionError("click succeeded after a timed overlay obscured the target")

            overlay_report = json.loads(
                page.evaluate(
                    "JSON.stringify({targetClicks: phaseTargetClicks, overlayUps: phaseOverlayUps, overlayClicks: phaseOverlayClicks})"
                )
            )
            assert overlay_report == {
                "targetClicks": 0,
                "overlayUps": 1,
                "overlayClicks": 0,
            }

            # A body/html selector is a viewport action, not a request to use
            # the faux 1920x100,000,000 document-container box.  Repeat the
            # click in one stable 300x65 child frame and require Chrome's
            # frame-local centre coordinates on both physical sequences.
            page.navigate(f"{url}viewport-root", timeout_ms=15_000)
            viewport_children = [
                frame for frame in page.frames(visible=True, attached=True)
                if not frame.is_root
            ]
            assert len(viewport_children) == 1, viewport_children
            viewport_child = viewport_children[0]
            assert viewport_child.owner_rect is not None
            assert viewport_child.owner_rect.width == 300
            assert viewport_child.owner_rect.height == 65

            for expected_count in (1, 2):
                page.click(
                    "body",
                    frame_id=viewport_child.frame_id,
                    pierce_shadow=True,
                    timeout_ms=5_000,
                    move_delay_ms=16,
                    press_delay_ms=60,
                )
                reports = json.loads(
                    page.evaluate(
                        f"""new Promise((resolve, reject) => {{
                          const deadline = Date.now() + 5000;
                          const poll = () => {{
                            if (viewportClickReports.length >= {expected_count}) {{
                              return resolve(viewportClickReports);
                            }}
                            if (Date.now() >= deadline) {{
                              return reject(new Error('viewport click report timeout'));
                            }}
                            setTimeout(poll, 5);
                          }};
                          poll();
                        }})""",
                        promise_timeout_ms=7_000,
                    )
                )

            assert len(reports) == 2, reports
            for index, viewport_report in enumerate(reports, start=1):
                assert viewport_report["click"] == index
                assert all(event["trusted"] for event in viewport_report["events"])
                coordinates = [
                    event for event in viewport_report["events"]
                    if event["type"] in {
                        "pointermove", "mousemove", "pointerdown", "mousedown",
                        "pointerup", "mouseup", "click",
                    }
                ]
                assert coordinates, viewport_report
                for event in coordinates:
                    assert event["clientX"] == 150, event
                    expected_y = 32.5 if event["type"].startswith("pointer") else 32
                    assert event["clientY"] == expected_y, event

            first_types = [event["type"] for event in reports[0]["events"]]
            second_types = [event["type"] for event in reports[1]["events"]]
            assert "pointerover" in first_types and "mouseover" in first_types
            assert second_types == [
                "pointermove", "mousemove", "pointerdown", "mousedown",
                "pointerup", "mouseup", "click",
            ], second_types

    print("ffi trusted click: PASS")


if __name__ == "__main__":
    main()
