"""Local Chrome 149/DarkPanda oracle for aborting a header-pending fetch.

The authored HTTP fixture deliberately accepts ``/hold`` requests without
sending response headers.  This distinguishes an AbortSignal changing state
from Fetch rejecting and from the transport actually closing the request.

The Chrome path creates one target on an existing CDP endpoint and closes only
that target.  It never closes or launches the browser.  The fixture avoids the
repository's reserved 9222, 9333 and 9583 ports.
"""

from __future__ import annotations

import argparse
import contextlib
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
import pathlib
import socket
import threading
import time
from typing import Any, Iterator
from urllib.parse import parse_qs, quote, urlsplit

import requests
import websocket


RESERVED_PORTS = {9222, 9333, 9583}
CASE_SUFFIXES = (
    "window-timeout",
    "window-controller",
    "worker-timeout",
    "worker-controller",
)


WORKER_JS = r"""
'use strict';
const now = () => performance.now();
const describe = (value, signal, start) => ({
  name: String(value && value.name || ''),
  message: String(value && value.message || ''),
  constructorName: String(value && value.constructor && value.constructor.name || ''),
  tag: Object.prototype.toString.call(value),
  sameAsSignalReason: value === signal.reason,
  elapsedMs: now() - start
});

postMessage({kind: 'ready'});
onmessage = event => {
  const command = event.data;
  if (!command || command.kind !== 'run') return;
  const start = now();
  const record = {
    id: command.id,
    mode: command.mode,
    startMs: start,
    signalAbort: null,
    rejection: null,
    fulfilled: null,
    afterAbortMicrotask: false,
    afterAbortTimer: false
  };
  let controller = null;
  const signal = command.mode === 'timeout'
    ? AbortSignal.timeout(command.delayMs)
    : (controller = new AbortController()).signal;

  signal.addEventListener('abort', event => {
    record.signalAbort = {
      ...describe(signal.reason, signal, start),
      eventType: event.type,
      eventTrusted: event.isTrusted,
      aborted: signal.aborted
    };
    postMessage({kind: 'abort', id: command.id, record});
    queueMicrotask(() => {
      record.afterAbortMicrotask = true;
      postMessage({kind: 'after-abort-microtask', id: command.id, record});
    });
    setTimeout(() => {
      record.afterAbortTimer = true;
      postMessage({kind: 'after-abort-timer', id: command.id, record});
    }, 0);
  }, {once: true});

  fetch(command.url, {signal}).then(
    response => {
      record.fulfilled = {status: response.status, elapsedMs: now() - start};
      postMessage({kind: 'settled', id: command.id, record});
    },
    error => {
      record.rejection = describe(error, signal, start);
      postMessage({kind: 'settled', id: command.id, record});
    }
  );
  if (controller) setTimeout(() => controller.abort(), command.delayMs);
  setTimeout(() => {
    postMessage({kind: 'checkpoint', id: command.id, record: {
      ...record,
      checkpointElapsedMs: now() - start,
      signalAborted: signal.aborted,
      signalReason: signal.aborted ? describe(signal.reason, signal, start) : null
    }});
  }, command.checkpointMs);
};
"""


PAGE_HTML = r"""<!doctype html><meta charset="utf-8">
<title>pending fetch abort oracle</title><body><script>
(() => {
  'use strict';
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const now = () => performance.now();
  const engine = new URL(location.href).searchParams.get('engine') || 'unknown';
  const describe = (value, signal, start) => ({
    name: String(value && value.name || ''),
    message: String(value && value.message || ''),
    constructorName: String(value && value.constructor && value.constructor.name || ''),
    tag: Object.prototype.toString.call(value),
    sameAsSignalReason: value === signal.reason,
    elapsedMs: now() - start
  });

  async function runWindowCase(mode, delayMs, checkpointMs) {
    const id = `${engine}-window-${mode}`;
    const start = now();
    let controller = null;
    const signal = mode === 'timeout'
      ? AbortSignal.timeout(delayMs)
      : (controller = new AbortController()).signal;
    const record = {
      id, mode, startMs: start, signalAbort: null, rejection: null,
      fulfilled: null, afterAbortMicrotask: false, afterAbortTimer: false
    };
    signal.addEventListener('abort', event => {
      record.signalAbort = {
        ...describe(signal.reason, signal, start),
        eventType: event.type,
        eventTrusted: event.isTrusted,
        aborted: signal.aborted
      };
      queueMicrotask(() => { record.afterAbortMicrotask = true; });
      setTimeout(() => { record.afterAbortTimer = true; }, 0);
    }, {once: true});
    fetch(`/hold?id=${encodeURIComponent(id)}`, {signal}).then(
      response => { record.fulfilled = {status: response.status, elapsedMs: now() - start}; },
      error => { record.rejection = describe(error, signal, start); }
    );
    if (controller) setTimeout(() => controller.abort(), delayMs);
    await sleep(checkpointMs);
    // A background Chrome target may coalesce the abort timer and checkpoint
    // into one task.  Give the zero-delay post-abort task a separate turn.
    await sleep(50);
    return {
      ...record,
      checkpointElapsedMs: now() - start,
      signalAborted: signal.aborted,
      signalReason: signal.aborted ? describe(signal.reason, signal, start) : null
    };
  }

  async function runWorkerCases(delayMs, checkpointMs) {
    const worker = new Worker(`/worker.js?engine=${encodeURIComponent(engine)}`);
    // Keep the Worker alive until the host takes its pre-close transport
    // snapshot.  Terminating it here would create a false-positive TCP EOF.
    (globalThis.__pendingFetchAbortWorkers ||= []).push(worker);
    const result = {ready: false, messages: [], cases: {}};
    let readyResolve;
    const ready = new Promise(resolve => { readyResolve = resolve; });
    worker.onmessage = event => {
      const message = event.data;
      result.messages.push({kind: message && message.kind, id: message && message.id});
      if (message && message.kind === 'ready') {
        result.ready = true;
        readyResolve(true);
      }
      if (message && message.id && message.record) {
        result.cases[message.id] = message.record;
      }
    };
    worker.onerror = event => {
      result.workerError = {message: event.message, filename: event.filename,
        lineno: event.lineno, colno: event.colno};
      readyResolve(false);
    };
    await Promise.race([ready, sleep(2000)]);
    if (result.ready) {
      for (const mode of ['timeout', 'controller']) {
        const id = `${engine}-worker-${mode}`;
        worker.postMessage({kind: 'run', id, mode, delayMs, checkpointMs,
          url: `/hold?id=${encodeURIComponent(id)}`});
      }
      await sleep(checkpointMs + 350);
    }
    return result;
  }

  window.__runPendingFetchAbortProbe = async () => {
    const delayMs = 140;
    const checkpointMs = 850;
    const [windowTimeout, windowController, worker] = await Promise.all([
      runWindowCase('timeout', delayMs, checkpointMs),
      runWindowCase('controller', delayMs, checkpointMs),
      runWorkerCases(delayMs, checkpointMs)
    ]);
    return {
      engine,
      capabilities: {
        fetch: typeof fetch,
        Worker: typeof Worker,
        AbortController: typeof AbortController,
        AbortSignalTimeout: typeof AbortSignal && typeof AbortSignal.timeout
      },
      cases: {
        [`${engine}-window-timeout`]: windowTimeout,
        [`${engine}-window-controller`]: windowController,
        ...worker.cases
      },
      worker: {
        ready: worker.ready,
        workerError: worker.workerError || null,
        messages: worker.messages
      }
    };
  };
  // Narrow diagnostic entry points keep native cancellation crashes
  // attributable to one context/signal combination without changing the
  // four-case acceptance matrix above.
  window.__runPendingFetchAbortWindowCase = runWindowCase;
  window.__runPendingFetchAbortWorkerCases = runWorkerCases;
  window.__pendingFetchAbortReady = true;
})();
</script></body>"""


@dataclass
class HoldRecord:
    request_id: str
    accepted_at_ms: float
    client_disconnected_at_ms: float | None = None
    end_reason: str | None = None


@dataclass
class ServerState:
    started: float = field(default_factory=time.monotonic)
    lock: threading.Lock = field(default_factory=threading.Lock)
    stop: threading.Event = field(default_factory=threading.Event)
    holds: dict[str, HoldRecord] = field(default_factory=dict)

    def elapsed_ms(self) -> float:
        return (time.monotonic() - self.started) * 1000

    def accepted(self, request_id: str) -> None:
        with self.lock:
            self.holds[request_id] = HoldRecord(request_id, self.elapsed_ms())

    def ended(self, request_id: str, reason: str) -> None:
        with self.lock:
            record = self.holds.get(request_id)
            if record is not None and record.client_disconnected_at_ms is None:
                record.client_disconnected_at_ms = self.elapsed_ms()
                record.end_reason = reason

    def snapshot(self, prefix: str) -> dict[str, dict[str, Any]]:
        with self.lock:
            return {
                key: {
                    "acceptedAtMs": round(value.accepted_at_ms, 3),
                    "clientDisconnectedAtMs": (
                        None
                        if value.client_disconnected_at_ms is None
                        else round(value.client_disconnected_at_ms, 3)
                    ),
                    "endReason": value.end_reason,
                }
                for key, value in sorted(self.holds.items())
                if key.startswith(prefix + "-")
            }


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, address: tuple[str, int]) -> None:
        self.state = ServerState()
        super().__init__(address, FixtureHandler)


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = ""
    sys_version = ""

    @property
    def fixture(self) -> FixtureServer:
        return self.server  # type: ignore[return-value]

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def reply(self, body: bytes, content_type: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        parsed = urlsplit(self.path)
        if parsed.path == "/":
            self.reply(PAGE_HTML.encode("utf-8"), "text/html; charset=utf-8")
            return
        if parsed.path == "/worker.js":
            self.reply(WORKER_JS.encode("utf-8"), "text/javascript; charset=utf-8")
            return
        if parsed.path != "/hold":
            self.send_error(404)
            return

        request_id = parse_qs(parsed.query).get("id", [""])[0]
        if not request_id:
            self.send_error(400)
            return
        self.fixture.state.accepted(request_id)
        self.connection.settimeout(0.05)
        reason = "server-fixture-release"
        try:
            while not self.fixture.state.stop.is_set():
                try:
                    data = self.connection.recv(1)
                    if data == b"":
                        reason = "client-eof"
                        break
                except socket.timeout:
                    continue
                except (ConnectionResetError, ConnectionAbortedError, OSError) as error:
                    reason = type(error).__name__
                    break
        finally:
            self.fixture.state.ended(request_id, reason)
            with contextlib.suppress(OSError):
                self.connection.shutdown(socket.SHUT_RDWR)
            with contextlib.suppress(OSError):
                self.connection.close()
            self.close_connection = True


@contextlib.contextmanager
def fixture_server() -> Iterator[tuple[FixtureServer, str]]:
    server: FixtureServer | None = None
    for _ in range(16):
        candidate = FixtureServer(("127.0.0.1", 0))
        if int(candidate.server_address[1]) not in RESERVED_PORTS:
            server = candidate
            break
        candidate.server_close()
    if server is None:
        raise RuntimeError("could not allocate a non-reserved fixture port")
    thread = threading.Thread(target=server.serve_forever, name="pending-fetch-abort", daemon=True)
    thread.start()
    try:
        yield server, f"http://127.0.0.1:{server.server_address[1]}/"
    finally:
        server.state.stop.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


class CDP:
    def __init__(self, url: str) -> None:
        self.ws = websocket.create_connection(url, timeout=20)
        self.ident = 0

    def call(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        self.ident += 1
        self.ws.send(json.dumps({"id": self.ident, "method": method, "params": params or {}}))
        while True:
            message = json.loads(self.ws.recv())
            if message.get("id") != self.ident:
                continue
            if message.get("error"):
                raise RuntimeError(message["error"])
            return message.get("result", {})

    def close(self) -> None:
        self.ws.close()


def wait_chrome_ready(cdp: CDP, expected_url: str) -> None:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        result = cdp.call(
            "Runtime.evaluate",
            {
                "expression": "({href:location.href,ready:globalThis.__pendingFetchAbortReady===true})",
                "returnByValue": True,
            },
        )
        value = result.get("result", {}).get("value", {})
        if value.get("href") == expected_url and value.get("ready") is True:
            return
        time.sleep(0.02)
    raise TimeoutError("Chrome fixture document did not initialize")


def run_chrome(port: int, base_url: str, server: FixtureServer) -> dict[str, Any]:
    endpoint = f"http://127.0.0.1:{port}"
    version = requests.get(f"{endpoint}/json/version", timeout=5).json()
    product = str(version.get("Browser", ""))
    if "/149." not in product:
        raise RuntimeError(f"Chrome 149 required at {endpoint}, got {product!r}")
    url = base_url + "?engine=chrome"
    target = requests.put(f"{endpoint}/json/new?{quote(url, safe='')}", timeout=10).json()
    cdp = CDP(str(target["webSocketDebuggerUrl"]))
    payload: dict[str, Any]
    before_close: dict[str, Any]
    try:
        cdp.call("Runtime.enable")
        cdp.call("Page.enable")
        cdp.call("Page.navigate", {"url": url})
        wait_chrome_ready(cdp, url)
        result = cdp.call(
            "Runtime.evaluate",
            {
                "expression": "window.__runPendingFetchAbortProbe()",
                "returnByValue": True,
                "awaitPromise": True,
                "timeout": 20_000,
            },
        )
        if result.get("exceptionDetails"):
            raise RuntimeError(result["exceptionDetails"])
        payload = dict(result["result"]["value"])
        time.sleep(0.25)
        before_close = server.state.snapshot("chrome")
    finally:
        cdp.close()
        with contextlib.suppress(requests.RequestException):
            requests.get(f"{endpoint}/json/close/{target['id']}", timeout=5)
    time.sleep(0.15)
    return {
        "product": product,
        "userAgent": str(version.get("User-Agent", "")),
        "payload": payload,
        "transportBeforeTargetClose": before_close,
        "transportAfterTargetClose": server.state.snapshot("chrome"),
    }


def run_darkpanda(
    library: pathlib.Path,
    wreq: pathlib.Path,
    base_url: str,
    server: FixtureServer,
) -> dict[str, Any]:
    from darkpanda import ClientProfile, Runtime

    runtime = Runtime(
        library_path=library,
        wreq_library_path=wreq,
        navigation_timeout_ms=20_000,
        locale="en-US",
        timezone="UTC",
        profile=ClientProfile.CHROME149,
    )
    page = runtime.new_page()
    try:
        page.navigate(base_url + "?engine=darkpanda", timeout_ms=20_000)
        raw = page.evaluate(
            "window.__runPendingFetchAbortProbe()",
            promise_timeout_ms=20_000,
        )
        payload = json.loads(raw)
        time.sleep(0.25)
        before_close = server.state.snapshot("darkpanda")
    finally:
        page.close()
        runtime.close()
    time.sleep(0.15)
    return {
        "library": str(library),
        "librarySha256": sha256(library),
        "wreq": str(wreq),
        "wreqSha256": sha256(wreq),
        "payload": payload,
        "transportBeforePageClose": before_close,
        "transportAfterPageClose": server.state.snapshot("darkpanda"),
    }


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def assessment(engine: str, result: dict[str, Any], transport_key: str) -> dict[str, Any]:
    cases = result.get("payload", {}).get("cases", {})
    transport = result.get(transport_key, {})
    output: dict[str, Any] = {}
    for suffix in CASE_SUFFIXES:
        request_id = f"{engine}-{suffix}"
        record = cases.get(request_id, {})
        transport_record = transport.get(request_id, {})
        output[suffix] = {
            "requestAccepted": bool(transport_record),
            "signalAborted": bool(record.get("signalAborted") or record.get("signalAbort")),
            "fetchRejected": record.get("rejection") is not None,
            "rejection": record.get("rejection"),
            "transportCancelledBeforeContextClose": (
                transport_record.get("clientDisconnectedAtMs") is not None
            ),
            "transportEndReason": transport_record.get("endReason"),
            "afterAbortMicrotask": bool(record.get("afterAbortMicrotask")),
            "afterAbortTimer": bool(record.get("afterAbortTimer")),
        }
    return output


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chrome-port", type=int, default=9333)
    parser.add_argument("--library", type=pathlib.Path, required=True)
    parser.add_argument("--wreq", type=pathlib.Path, required=True)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.chrome_port != 9333:
        parser.error("this checked-in oracle intentionally targets the existing Chrome 149 CDP 9333")
    for path in (args.library, args.wreq):
        if not path.is_file():
            parser.error(f"missing binary: {path}")
    return args


def main() -> None:
    args = parse_args()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with fixture_server() as (server, base_url):
        chrome = run_chrome(args.chrome_port, base_url, server)
        darkpanda = run_darkpanda(
            args.library.resolve(),
            args.wreq.resolve(),
            base_url,
            server,
        )
        output = {
            "schema": "darkpanda.pending-fetch-abort-oracle.v1",
            "scope": "local-authored-generic-web-platform-only",
            "fixture": {
                "origin": base_url,
                "holdBehavior": "accept request; send no response headers",
                "reservedPortsAvoided": sorted(RESERVED_PORTS),
                "abortDelayMs": 140,
                "checkpointMs": 850,
            },
            "engines": {
                "chrome": chrome,
                "darkpanda": darkpanda,
            },
        }
        output["comparison"] = {
            "chrome": assessment("chrome", chrome, "transportBeforeTargetClose"),
            "darkpanda": assessment("darkpanda", darkpanda, "transportBeforePageClose"),
        }
    args.out.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"out": str(args.out), **output["comparison"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
