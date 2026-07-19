from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import websocket


HOST = "127.0.0.1"


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind((HOST, 0))
        return int(sock.getsockname()[1])


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        body = (
            b"<!doctype html><meta charset=utf-8>"
            b"<title>darkpanda-cdp-smoke</title>"
            b"<main id=probe>ok</main>"
            b"<script>window.__smoke = 40 + 2;</script>"
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args: object) -> None:
        pass


class CDP:
    def __init__(self, ws: websocket.WebSocket) -> None:
        self.ws = ws
        self.next_id = 0
        self.inbox: list[dict] = []

    def _recv(self, timeout: float) -> dict:
        self.ws.settimeout(max(timeout, 0.05))
        raw = self.ws.recv()
        if not isinstance(raw, str):
            raise RuntimeError(f"unexpected binary CDP frame: {len(raw)} bytes")
        return json.loads(raw)

    def call(
        self,
        method: str,
        params: dict | None = None,
        session_id: str | None = None,
        timeout: float = 15.0,
    ) -> dict:
        self.next_id += 1
        call_id = self.next_id
        message: dict = {"id": call_id, "method": method}
        if params is not None:
            message["params"] = params
        if session_id is not None:
            message["sessionId"] = session_id
        self.ws.send(json.dumps(message, separators=(",", ":")))

        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"CDP timeout: {method}")
            item = self._recv(remaining)
            if item.get("id") != call_id:
                self.inbox.append(item)
                continue
            if "error" in item:
                raise RuntimeError(f"{method}: {item['error']}")
            return item.get("result", {})

    def event(
        self,
        method: str,
        session_id: str | None = None,
        timeout: float = 15.0,
    ) -> dict:
        def matches(item: dict) -> bool:
            return item.get("method") == method and (
                session_id is None or item.get("sessionId") == session_id
            )

        for index, item in enumerate(self.inbox):
            if matches(item):
                return self.inbox.pop(index).get("params", {})

        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"CDP event timeout: {method}")
            item = self._recv(remaining)
            if matches(item):
                return item.get("params", {})
            self.inbox.append(item)


def wait_for_version(
    process: subprocess.Popen,
    port: int,
    logs: deque[str],
    timeout: float = 15.0,
) -> dict:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    url = f"http://{HOST}:{port}/json/version"
    deadline = time.monotonic() + timeout
    last_error: BaseException | None = None

    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(
                f"browser exited early with {process.returncode}\n{''.join(logs)}"
            )
        try:
            with opener.open(url, timeout=0.5) as response:
                return json.load(response)
        except (
            OSError,
            TimeoutError,
            urllib.error.URLError,
            json.JSONDecodeError,
        ) as error:
            last_error = error
            time.sleep(0.1)

    raise TimeoutError(f"CDP endpoint not ready: {last_error}\n{''.join(logs)}")


def stop_process(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    try:
        process.send_signal(signal.CTRL_BREAK_EVENT)
        process.wait(timeout=5)
    except Exception:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def main() -> int:
    default_exe = Path(__file__).resolve().parents[1] / "zig-out/bin/darkpanda.exe"
    exe = Path(sys.argv[1] if len(sys.argv) > 1 else default_exe).resolve(strict=True)
    if exe.suffix.lower() != ".exe":
        raise RuntimeError(f"expected native Windows .exe, got: {exe}")

    fixture = ThreadingHTTPServer((HOST, 0), Fixture)
    fixture_thread = threading.Thread(target=fixture.serve_forever, daemon=True)
    fixture_thread.start()
    fixture_url = f"http://{HOST}:{fixture.server_address[1]}/"

    cdp_port = free_port()
    logs: deque[str] = deque(maxlen=200)
    process = subprocess.Popen(
        [str(exe), "serve", "--host", HOST, "--port", str(cdp_port)],
        cwd=str(exe.parent),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
        creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0),
    )

    def drain_output() -> None:
        assert process.stdout is not None
        for line in process.stdout:
            logs.append(line)

    threading.Thread(target=drain_output, daemon=True).start()
    ws: websocket.WebSocket | None = None
    cdp: CDP | None = None
    target_id: str | None = None
    try:
        version = wait_for_version(process, cdp_port, logs)
        ws_url = version["webSocketDebuggerUrl"]
        os.environ["NO_PROXY"] = "127.0.0.1,localhost"
        os.environ["no_proxy"] = "127.0.0.1,localhost"
        ws = websocket.create_connection(
            ws_url,
            timeout=10,
            http_no_proxy=["127.0.0.1", "localhost"],
        )
        cdp = CDP(ws)

        target_id = cdp.call("Target.createTarget", {"url": "about:blank"})[
            "targetId"
        ]
        session_id = cdp.call(
            "Target.attachToTarget",
            {"targetId": target_id, "flatten": True},
        )["sessionId"]

        cdp.call("Page.enable", session_id=session_id)
        cdp.call("Runtime.enable", session_id=session_id)
        navigation = cdp.call(
            "Page.navigate",
            {"url": fixture_url},
            session_id=session_id,
            timeout=20,
        )
        if navigation.get("errorText"):
            raise RuntimeError(f"navigation failed: {navigation}")
        cdp.event("Page.loadEventFired", session_id=session_id, timeout=20)

        evaluated = cdp.call(
            "Runtime.evaluate",
            {
                "expression": "({url:location.href,readyState:document.readyState,marker:document.querySelector('#probe').textContent,answer:window.__smoke})",
                "awaitPromise": True,
                "returnByValue": True,
            },
            session_id=session_id,
        )
        if "exceptionDetails" in evaluated:
            raise RuntimeError(f"evaluation exception: {evaluated['exceptionDetails']}")

        value = evaluated["result"]["value"]
        expected = {
            "url": fixture_url,
            "readyState": "complete",
            "marker": "ok",
            "answer": 42,
        }
        if value != expected:
            raise AssertionError(f"unexpected evaluate result: {value!r}")

        print(
            json.dumps(
                {
                    "ok": True,
                    "browser": version.get("Browser"),
                    "ws": ws_url,
                    "evaluate": value,
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0
    finally:
        if cdp is not None and target_id is not None:
            try:
                cdp.call("Target.closeTarget", {"targetId": target_id}, timeout=2)
            except Exception:
                pass
        if ws is not None:
            ws.close()
        fixture.shutdown()
        fixture.server_close()
        stop_process(process)


if __name__ == "__main__":
    raise SystemExit(main())
