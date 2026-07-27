"""Read-only diagnostics for a managed challenge through the native ABI.

The script intentionally reports only public geometry, paths and protocol
event names. Ephemeral frame query strings and challenge payloads are omitted.
"""

from __future__ import annotations

import argparse
import json
import re
import time
from dataclasses import asdict
from urllib.parse import urlparse

from darkpanda import ClientProfile, Runtime


URL = "https://nopecha.com/demo/cloudflare"
CHECKBOX = 'input[type="checkbox"]'


INSTALL_MONITOR = r"""
(() => {
  if (globalThis.__managedDiag) return true;
  const state = globalThis.__managedDiag = {messages: [], clicks: [], errors: []};
  addEventListener('message', event => {
    const data = event.data;
    const record = {
      trusted: event.isTrusted,
      origin: event.origin,
      kind: typeof data,
      source: data && typeof data === 'object' ? String(data.source || '') : '',
      event: data && typeof data === 'object' ? String(data.event || '') : '',
      keys: data && typeof data === 'object'
        ? Object.keys(data).filter(key => !/token|response|payload/i.test(key)).sort()
        : []
    };
    state.messages.push(record);
    if (state.messages.length > 100) state.messages.shift();
  }, true);
  addEventListener('error', event => {
    state.errors.push({
      kind: 'error',
      message: String(event.message || '').slice(0, 240),
      filename: String(event.filename || ''),
      line: Number(event.lineno || 0),
      column: Number(event.colno || 0)
    });
  }, true);
  addEventListener('unhandledrejection', event => {
    state.errors.push({
      kind: 'unhandledrejection',
      message: String(event.reason && (event.reason.stack || event.reason.message) || event.reason || '').slice(0, 240)
    });
  }, true);
  for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
    addEventListener(type, event => {
      state.clicks.push({
        type,
        trusted: event.isTrusted,
        target: event.target && event.target.tagName || '',
        x: event.clientX,
        y: event.clientY
      });
    }, true);
  }
  return true;
})()
"""


SNAPSHOT = r"""
(() => ({
  href: location.href,
  title: document.title,
  readyState: document.readyState,
  text: String(document.body && document.body.innerText || '').slice(0, 500),
  active: document.activeElement && document.activeElement.tagName || '',
  monitorInstalled: !!globalThis.__managedDiag,
  messages: (globalThis.__managedDiag && globalThis.__managedDiag.messages || []).slice(),
  clicks: (globalThis.__managedDiag && globalThis.__managedDiag.clicks || []).slice(),
  errors: (globalThis.__managedDiag && globalThis.__managedDiag.errors || []).slice(),
  resources: performance.getEntriesByType('resource').map(entry => ({
    name: entry.name,
    initiatorType: entry.initiatorType,
    responseStatus: entry.responseStatus,
    nextHopProtocol: entry.nextHopProtocol,
    duration: entry.duration,
    transferSize: entry.transferSize
  })).slice(-100),
  frames: Array.from(document.querySelectorAll('iframe'), (node, index) => {
    const rect = node.getBoundingClientRect();
    return {
      index,
      id: node.id,
      name: node.name,
      src: node.src,
      title: node.title,
      width: rect.width,
      height: rect.height,
      x: rect.x,
      y: rect.y,
      visible: !!(rect.width && rect.height),
      clientLeft: node.clientLeft,
      clientTop: node.clientTop
    };
  })
}))()
"""


def safe_url(value: str) -> str:
    parsed = urlparse(value)
    segments = []
    for segment in parsed.path.split("/"):
        opaque = len(segment) > 32 or (
            len(segment) >= 16 and re.fullmatch(r"[0-9a-fA-F]+", segment) is not None
        )
        segments.append(f"<opaque:{len(segment)}>" if opaque else segment)
    return f"{parsed.scheme}://{parsed.netloc}{'/'.join(segments)}"


def safe_snapshot(value: dict[str, object]) -> dict[str, object]:
    value = dict(value)
    value["href"] = safe_url(str(value.get("href", "")))
    frames = []
    for raw in value.get("frames", []):
        frame = dict(raw)
        frame["src"] = safe_url(str(frame.get("src", "")))
        frames.append(frame)
    value["frames"] = frames
    resources = []
    for raw in value.get("resources", []):
        resource = dict(raw)
        resource["name"] = safe_url(str(resource.get("name", "")))
        resources.append(resource)
    value["resources"] = resources
    errors = []
    for raw in value.get("errors", []):
        error = dict(raw)
        if error.get("filename"):
            error["filename"] = safe_url(str(error["filename"]))
        errors.append(error)
    value["errors"] = errors
    return value


def frame_report(page: object) -> list[dict[str, object]]:
    result = []
    for frame in page.frames():
        value = asdict(frame)
        value["url"] = safe_url(frame.url)
        result.append(value)
    return result


def choose_frame(page: object):
    candidates = [
        frame for frame in page.frames(visible=True, attached=True)
        if not frame.is_root and frame.owner_rect is not None
        and frame.owner_rect.width > 0 and frame.owner_rect.height > 0
    ]
    if not candidates:
        return None
    return min(
        candidates,
        key=lambda frame: (
            abs(frame.owner_rect.width - 300) + abs(frame.owner_rect.height - 65),
            frame.child_count,
            frame.owner_rect.width * frame.owner_rect.height,
            frame.frame_id,
        ),
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq", required=True)
    parser.add_argument("--after-seconds", type=float, default=15.0)
    parser.add_argument("--click-timeout-ms", type=int, default=30_000)
    args = parser.parse_args()

    with Runtime(
        library_path=args.library,
        wreq_library_path=args.wreq,
        navigation_timeout_ms=30_000,
        locale="en-US",
        timezone="UTC",
        profile=ClientProfile.CHROME149,
    ) as runtime, runtime.new_page() as page:
        page.navigate(URL, timeout_ms=30_000)
        page.evaluate(INSTALL_MONITOR)
        deadline = time.monotonic() + 30
        frame = choose_frame(page)
        while frame is None and time.monotonic() < deadline:
            page.evaluate("new Promise(r => setTimeout(r, 100))", promise_timeout_ms=2_000)
            frame = choose_frame(page)

        before = safe_snapshot(json.loads(page.evaluate(SNAPSHOT)))
        print(json.dumps({"phase": "before", "dom": before, "frames": frame_report(page)}, ensure_ascii=False))
        if frame is None:
            raise AssertionError("no visible attached child frame")

        print(json.dumps({"phase": "selected", "frameId": frame.frame_id, "url": safe_url(frame.url), "ownerRect": asdict(frame.owner_rect)}, ensure_ascii=False))
        page.click(
            CHECKBOX,
            frame_id=frame.frame_id,
            pierce=True,
            timeout_ms=args.click_timeout_ms,
            move_delay_ms=16,
            press_delay_ms=60,
        )
        print(json.dumps({"phase": "click-returned"}))
        try:
            immediate = safe_snapshot(json.loads(page.evaluate(SNAPSHOT)))
            print(json.dumps({"phase": "immediate", "dom": immediate, "frames": frame_report(page)}, ensure_ascii=False))
        except Exception as error:
            print(json.dumps({"phase": "immediate-detached", "error": type(error).__name__}))

        end = time.monotonic() + args.after_seconds
        while time.monotonic() < end:
            try:
                page.evaluate("new Promise(r => setTimeout(r, 100))", promise_timeout_ms=2_000)
            except Exception:
                pass

        after = safe_snapshot(json.loads(page.evaluate(SNAPSHOT)))
        print(json.dumps({"phase": "after", "dom": after, "frames": frame_report(page)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
