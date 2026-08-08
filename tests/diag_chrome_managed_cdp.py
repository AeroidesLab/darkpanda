"""Native mouse-input diagnostic for a real Chrome managed challenge.

Creates and closes one dedicated target on an already-running debugging port.
It intentionally keeps the browser's real identity: this is not a fingerprint
oracle and does not override User-Agent or client hints.  Only paths, geometry,
event metadata and DOM labels are printed.
"""

from __future__ import annotations

import argparse
import json
import re
import time
from urllib.parse import quote, urlparse

import requests
import websocket


URL = "https://nopecha.com/demo/cloudflare"
EVENT_PREFIX = "__managed_input__"


def safe_url(value: str) -> str:
    parsed = urlparse(value)
    segments = []
    for segment in parsed.path.split("/"):
        opaque = len(segment) > 32 or (
            len(segment) >= 16 and re.fullmatch(r"[0-9a-fA-F]+", segment) is not None
        )
        segments.append(f"<opaque:{len(segment)}>" if opaque else segment)
    return f"{parsed.scheme}://{parsed.netloc}{'/'.join(segments)}"


class CDP:
    def __init__(self, url: str) -> None:
        self.ws = websocket.create_connection(url, timeout=30)
        self.next_id = 0
        self.events: list[dict[str, object]] = []

    def call(
        self,
        method: str,
        params: dict[str, object] | None = None,
        session_id: str | None = None,
    ):
        self.next_id += 1
        ident = self.next_id
        command: dict[str, object] = {
            "id": ident,
            "method": method,
            "params": params or {},
        }
        if session_id is not None:
            command["sessionId"] = session_id
        self.ws.send(json.dumps(command))
        while True:
            message = json.loads(self.ws.recv())
            if message.get("id") == ident:
                if "error" in message:
                    raise RuntimeError(f"{method}: {message['error']}")
                return message.get("result", {})
            self.events.append(message)

    def drain(self, seconds: float) -> None:
        deadline = time.monotonic() + seconds
        self.ws.settimeout(min(0.2, seconds))
        while time.monotonic() < deadline:
            try:
                self.events.append(json.loads(self.ws.recv()))
            except websocket.WebSocketTimeoutException:
                pass
        self.ws.settimeout(30)

    def close(self) -> None:
        self.ws.close()


def eval_value(
    cdp: CDP,
    expression: str,
    context_id: int | None = None,
    session_id: str | None = None,
):
    params: dict[str, object] = {
        "expression": expression,
        "returnByValue": True,
        "awaitPromise": True,
    }
    if context_id is not None:
        params["contextId"] = context_id
    result = cdp.call("Runtime.evaluate", params, session_id)
    if "exceptionDetails" in result:
        raise RuntimeError(result["exceptionDetails"])
    return result.get("result", {}).get("value")


def flatten_frames(tree: dict[str, object]) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []

    def visit(node: dict[str, object], parent: str | None = None) -> None:
        frame = dict(node["frame"])
        result.append({
            "id": frame["id"],
            "parent": parent,
            "url": safe_url(str(frame.get("url", ""))),
            "name": frame.get("name", ""),
        })
        for child in node.get("childFrames", []) or []:
            visit(child, str(frame["id"]))

    visit(tree)
    return result


def safe_preview(value: object) -> str:
    text = str(value).replace("\r", " ").replace("\n", " ")[:240]
    return re.sub(
        r"(?i)(token|response|payload|ray(?:\s+id)?|widgetId)(\s*[:=]\s*)[^ ,;}]+",
        r"\1\2<redacted>",
        text,
    )


def event_report(events: list[dict[str, object]]) -> dict[str, object]:
    responses: list[dict[str, object]] = []
    failures: list[dict[str, object]] = []
    redirects: list[dict[str, object]] = []
    exceptions: list[dict[str, object]] = []
    console: list[dict[str, object]] = []
    frame_lifecycle: list[dict[str, object]] = []
    request_methods: dict[str, str] = {}
    for sequence, message in enumerate(events):
        method = message.get("method")
        params = message.get("params", {})
        if method == "Network.requestWillBeSent":
            request_methods[str(params.get("requestId", ""))] = str(
                params.get("request", {}).get("method", "")
            )
            if params.get("redirectResponse"):
                response = params["redirectResponse"]
                redirects.append({
                    "from": safe_url(str(response.get("url", ""))),
                    "status": response.get("status"),
                    "to": safe_url(str(params.get("request", {}).get("url", ""))),
                })
        elif method == "Network.responseReceived":
            response = params.get("response", {})
            responses.append({
                "url": safe_url(str(response.get("url", ""))),
                "status": response.get("status"),
                "method": request_methods.get(str(params.get("requestId", "")), ""),
                "type": params.get("type"),
                "mimeType": response.get("mimeType", ""),
                "fromDiskCache": response.get("fromDiskCache", False),
                "fromServiceWorker": response.get("fromServiceWorker", False),
            })
        elif method == "Network.loadingFailed":
            failures.append({
                "type": params.get("type"),
                "error": safe_preview(params.get("errorText", "")),
                "canceled": params.get("canceled", False),
                "blockedReason": params.get("blockedReason"),
            })
        elif method == "Runtime.exceptionThrown":
            details = params.get("exceptionDetails", {})
            exceptions.append({
                "text": safe_preview(details.get("text", "")),
                "url": safe_url(str(details.get("url", ""))),
                "line": details.get("lineNumber"),
                "column": details.get("columnNumber"),
                "description": safe_preview(
                    details.get("exception", {}).get("description", "")
                ),
            })
        elif method == "Runtime.consoleAPICalled":
            console.append({
                "type": params.get("type"),
                "values": [
                    safe_preview(arg.get("value", arg.get("description", "")))
                    for arg in params.get("args", [])[:4]
                ],
            })
        elif method == "Page.frameAttached":
            frame_lifecycle.append({
                "sequence": sequence,
                "event": "attached",
                "frame": params.get("frameId"),
                "parent": params.get("parentFrameId"),
            })
        elif method == "Page.frameNavigated":
            frame = params.get("frame", {})
            frame_lifecycle.append({
                "sequence": sequence,
                "event": "navigated",
                "frame": frame.get("id"),
                "parent": frame.get("parentId"),
                "url": safe_url(str(frame.get("url", ""))),
            })
        elif method == "Page.frameDetached":
            frame_lifecycle.append({
                "sequence": sequence,
                "event": "detached",
                "frame": params.get("frameId"),
                "reason": params.get("reason"),
            })
    return {
        "responses": responses,
        "redirects": redirects,
        "failures": failures,
        "exceptions": exceptions,
        "console": console,
        "frameLifecycle": frame_lifecycle,
    }


def default_contexts(events: list[dict[str, object]]) -> dict[str, int]:
    contexts: dict[str, int] = {}
    destroyed: set[int] = set()
    for message in events:
        method = message.get("method")
        params = message.get("params", {})
        if method == "Runtime.executionContextDestroyed":
            destroyed.add(int(params["executionContextId"]))
        elif method == "Runtime.executionContextsCleared":
            contexts.clear()
            destroyed.clear()
        elif method == "Runtime.executionContextCreated":
            context = params["context"]
            aux = context.get("auxData", {})
            if aux.get("isDefault") and aux.get("frameId"):
                contexts[str(aux["frameId"])] = int(context["id"])
    return {frame: ident for frame, ident in contexts.items() if ident not in destroyed}


CHILD_SNAPSHOT = r"""
(() => {
  const boxes = Array.from(document.querySelectorAll('input[type="checkbox"]'), node => {
    const rect = node.getBoundingClientRect();
    const style = getComputedStyle(node);
    const hit = document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2);
    return {
      rect: {x: rect.x, y: rect.y, width: rect.width, height: rect.height},
      checked: node.checked,
      disabled: node.disabled,
      opacity: style.opacity,
      display: style.display,
      visibility: style.visibility,
      pointerEvents: style.pointerEvents,
      hitTag: hit && hit.tagName || '',
      hitIsSelf: hit === node,
      hitClass: hit && String(hit.className || '') || ''
    };
  });
  return {
    href: location.href,
    title: document.title,
    text: String(document.body && document.body.innerText || '').slice(0, 300),
    active: document.activeElement && document.activeElement.tagName || '',
    boxes
  };
})()
"""


INSTALL_CHILD_MONITOR = rf"""
(() => {{
  if (globalThis.__managedInputMonitor) return true;
  globalThis.__managedInputMonitor = [];
  for (const type of ['pointerover','pointerenter','mouseover','mouseenter',
                      'pointermove','mousemove','pointerdown','mousedown','focus',
                      'focusin','pointerup','mouseup','click']) {{
    addEventListener(type, event => {{
      const first = event.composedPath && event.composedPath()[0];
      const record = {{
        type,
        trusted: event.isTrusted,
        ctor: event.constructor.name,
        target: event.target && event.target.tagName || '',
        first: first && first.tagName || '',
        x: event.clientX,
        y: event.clientY,
        button: event.button,
        buttons: event.buttons,
        detail: event.detail,
        pointerId: event.pointerId,
        pointerType: event.pointerType,
        primary: event.isPrimary
      }};
      globalThis.__managedInputMonitor.push(record);
      console.debug('{EVENT_PREFIX}' + JSON.stringify(record));
    }}, true);
  }}
  return true;
}})()
"""


def oracle(port: int, fresh_context: bool = False) -> None:
    endpoint = f"http://127.0.0.1:{port}"
    browser_cdp = None
    browser_context_id = None
    if fresh_context:
        version = requests.get(f"{endpoint}/json/version", timeout=5).json()
        browser_cdp = CDP(version["webSocketDebuggerUrl"])
        browser_context_id = browser_cdp.call("Target.createBrowserContext")[
            "browserContextId"
        ]
        target_id = browser_cdp.call("Target.createTarget", {
            "url": "about:blank", "browserContextId": browser_context_id
        })["targetId"]
        deadline = time.monotonic() + 5
        target = None
        while target is None and time.monotonic() < deadline:
            target = next(
                (item for item in requests.get(f"{endpoint}/json/list", timeout=5).json()
                 if item.get("id") == target_id),
                None,
            )
            if target is None:
                time.sleep(0.05)
        if target is None:
            raise RuntimeError("fresh context target did not appear in /json/list")
    else:
        target = requests.put(
            f"{endpoint}/json/new?{quote('about:blank', safe='')}", timeout=5
        ).json()
    target_id = target["id"]
    cdp = CDP(target["webSocketDebuggerUrl"])
    try:
        cdp.call("Runtime.enable")
        cdp.call("Page.enable")
        cdp.call("DOM.enable")
        cdp.call("Network.enable")
        cdp.call("Page.navigate", {"url": URL})
        deadline = time.monotonic() + 30
        frame_tree = cdp.call("Page.getFrameTree")["frameTree"]
        frames = flatten_frames(frame_tree)
        while (not any("challenges.cloudflare.com" in frame["url"] for frame in frames)
               and time.monotonic() < deadline):
            cdp.drain(0.05)
            frame_tree = cdp.call("Page.getFrameTree")["frameTree"]
            frames = flatten_frames(frame_tree)
        print(json.dumps({"phase": "frames", "frames": frames}, ensure_ascii=False))
        child = next(
            (frame for frame in frames if "challenges.cloudflare.com" in frame["url"]),
            None,
        )
        if child is None:
            snapshot = eval_value(cdp, "({href:location.href,title:document.title,text:String(document.body&&document.body.innerText||'').slice(0,500)})")
            snapshot["href"] = safe_url(snapshot["href"])
            snapshot["text"] = safe_preview(snapshot["text"])
            print(json.dumps({
                "phase": "root",
                "snapshot": snapshot,
                "events": event_report(cdp.events),
            }, ensure_ascii=False))
            return

        contexts = default_contexts(cdp.events)
        context_id = contexts.get(str(child["id"]))
        if context_id is None:
            context_id = int(cdp.call("Page.createIsolatedWorld", {
                "frameId": child["id"], "worldName": "managed-input-diagnostic"
            })["executionContextId"])

        before = eval_value(cdp, CHILD_SNAPSHOT, context_id)
        before["href"] = safe_url(before["href"])
        print(json.dumps({"phase": "child-before", "frame": child, "snapshot": before}, ensure_ascii=False))
        if not before["boxes"]:
            raise AssertionError("Chrome challenge frame has no checkbox")
        eval_value(cdp, INSTALL_CHILD_MONITOR, context_id)

        owner = cdp.call("DOM.getFrameOwner", {"frameId": child["id"]})
        model_params = ({"nodeId": owner["nodeId"]} if owner.get("nodeId")
                        else {"backendNodeId": owner["backendNodeId"]})
        model = cdp.call("DOM.getBoxModel", model_params)["model"]
        content = model["content"]
        box = before["boxes"][0]["rect"]
        local_x = float(box["x"]) + float(box["width"]) / 2
        local_y = float(box["y"]) + float(box["height"]) / 2
        top_x = float(content[0]) + local_x
        top_y = float(content[1]) + local_y
        print(json.dumps({
            "phase": "point",
            "ownerContentOrigin": [content[0], content[1]],
            "local": [local_x, local_y],
            "top": [top_x, top_y],
        }))

        cdp.call("Input.dispatchMouseEvent", {
            "type": "mouseMoved", "x": top_x, "y": top_y,
            "button": "none", "buttons": 0,
        })
        time.sleep(0.016)
        cdp.call("Input.dispatchMouseEvent", {
            "type": "mousePressed", "x": top_x, "y": top_y,
            "button": "left", "buttons": 1, "clickCount": 1,
        })
        time.sleep(0.060)
        cdp.call("Input.dispatchMouseEvent", {
            "type": "mouseReleased", "x": top_x, "y": top_y,
            "button": "left", "buttons": 0, "clickCount": 1,
        })
        cdp.drain(12)

        event_records = []
        for message in cdp.events:
            if message.get("method") != "Runtime.consoleAPICalled":
                continue
            for arg in message.get("params", {}).get("args", []):
                value = arg.get("value")
                if isinstance(value, str) and value.startswith(EVENT_PREFIX):
                    event_records.append(json.loads(value[len(EVENT_PREFIX):]))
        current_tree = cdp.call("Page.getFrameTree")["frameTree"]
        root = eval_value(cdp, "({href:location.href,title:document.title,text:String(document.body&&document.body.innerText||'').slice(0,500)})")
        root["href"] = safe_url(root["href"])
        print(json.dumps({
            "phase": "after",
            "events": event_records,
            "root": root,
            "frames": flatten_frames(current_tree),
            "runtime": event_report(cdp.events),
        }, ensure_ascii=False))
    finally:
        cdp.close()
        if browser_cdp is not None:
            try:
                browser_cdp.call("Target.closeTarget", {"targetId": target_id})
                browser_cdp.call("Target.disposeBrowserContext", {
                    "browserContextId": browser_context_id
                })
            finally:
                browser_cdp.close()
        else:
            requests.get(f"{endpoint}/json/close/{target_id}", timeout=5)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=9222)
    parser.add_argument("--fresh-context", action="store_true")
    args = parser.parse_args()
    oracle(args.port, args.fresh_context)


if __name__ == "__main__":
    main()
