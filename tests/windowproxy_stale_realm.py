"""Chrome-149 oracle and native regression for stale Window realm objects.

The fixture keeps one iframe WindowProxy while the iframe navigates from
127.0.0.1 (A1), to localhost (B), and back to 127.0.0.1 (A2).  The host alias
makes B cross-origin without external network access.  Run against either the
Chrome-for-Testing CDP endpoint or the DarkPanda native ABI; no browser build is
performed by this script.
"""

from __future__ import annotations

import argparse
import contextlib
import functools
import http.server
import json
import os
from pathlib import Path
import sys
import threading
import time
from typing import Any, Iterator
import urllib.request


EXPECTED_CHROME = "Chrome/149.0.7827.203"
EXPECTED_V8 = "14.9.207.35"
FIXTURE = "src/browser/tests/window/windowproxy_stale_realm.html"
RESULT_EXPRESSION = """
window.__windowProxyStaleRealmProbe.then(result => {
  let harnessError = null;
  try {
    testing.assertOk();
  } catch (error) {
    harnessError = {name: error.name, message: error.message};
  }
  return JSON.stringify({
    result,
    harnessError,
    failures: testing.failures,
  });
})
"""


class _NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, format: str, *args: object) -> None:
        del format, args


@contextlib.contextmanager
def fixture_server(root: Path) -> Iterator[str]:
    handler = functools.partial(_NoCacheHandler, directory=str(root))
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}/"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


class _CDP:
    def __init__(self, socket: Any) -> None:
        self.socket = socket
        self.next_id = 0

    def call(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        session_id: str | None = None,
    ) -> dict[str, Any]:
        self.next_id += 1
        call_id = self.next_id
        message: dict[str, Any] = {"id": call_id, "method": method}
        if params is not None:
            message["params"] = params
        if session_id is not None:
            message["sessionId"] = session_id
        self.socket.send(json.dumps(message, separators=(",", ":")))

        while True:
            response = json.loads(self.socket.recv())
            if response.get("id") != call_id:
                continue
            if "error" in response:
                raise RuntimeError(f"{method}: {response['error']}")
            return response.get("result", {})


def _open_json(url: str) -> dict[str, Any]:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(url, timeout=10) as response:
        return json.load(response)


def chrome_probe(endpoint: str, url: str) -> tuple[dict[str, Any], dict[str, Any]]:
    try:
        import websocket
    except ImportError as error:  # pragma: no cover - environment diagnostic
        raise RuntimeError("websocket-client is required for the CDP oracle") from error

    endpoint = endpoint.rstrip("/")
    version = _open_json(endpoint + "/json/version")
    if version.get("Browser") != EXPECTED_CHROME:
        raise AssertionError(
            f"wrong CDP browser: expected {EXPECTED_CHROME!r}, "
            f"got {version.get('Browser')!r}"
        )
    if version.get("V8-Version") != EXPECTED_V8:
        raise AssertionError(
            f"wrong CDP V8: expected {EXPECTED_V8!r}, "
            f"got {version.get('V8-Version')!r}"
        )

    os.environ["NO_PROXY"] = "127.0.0.1,localhost"
    os.environ["no_proxy"] = "127.0.0.1,localhost"
    socket = websocket.create_connection(
        version["webSocketDebuggerUrl"],
        timeout=30,
        suppress_origin=True,
        http_no_proxy=["127.0.0.1", "localhost"],
    )
    cdp = _CDP(socket)
    target_id: str | None = None
    try:
        target_id = cdp.call("Target.createTarget", {"url": url})["targetId"]
        session_id = cdp.call(
            "Target.attachToTarget",
            {"targetId": target_id, "flatten": True},
        )["sessionId"]
        cdp.call("Runtime.enable", session_id=session_id)
        cdp.call("Page.enable", session_id=session_id)

        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            ready = cdp.call(
                "Runtime.evaluate",
                {
                    "expression": (
                        "typeof window.__windowProxyStaleRealmProbe === 'object'"
                    ),
                    "returnByValue": True,
                },
                session_id,
            )
            if ready.get("result", {}).get("value") is True:
                break
            time.sleep(0.025)
        else:
            raise TimeoutError("Chrome fixture did not create its probe promise")

        evaluated = cdp.call(
            "Runtime.evaluate",
            {
                "expression": RESULT_EXPRESSION,
                "awaitPromise": True,
                "returnByValue": True,
            },
            session_id,
        )
        if "exceptionDetails" in evaluated:
            raise RuntimeError(evaluated["exceptionDetails"])
        payload = json.loads(evaluated["result"]["value"])
        return version, payload
    finally:
        if target_id is not None:
            cdp.call("Target.closeTarget", {"targetId": target_id})
        socket.close()


def darkpanda_probe(library: Path, wreq: Path, url: str) -> dict[str, Any]:
    binding_root = Path(__file__).resolve().parents[1] / "python"
    if str(binding_root) not in sys.path:
        sys.path.insert(0, str(binding_root))
    from darkpanda import ClientProfile, Runtime

    with Runtime(
        library_path=library,
        wreq_transport_path=wreq,
        navigation_timeout_ms=15_000,
        profile=ClientProfile.CHROME149,
    ) as runtime:
        with runtime.new_page() as page:
            page.navigate(url, timeout_ms=15_000)
            return json.loads(
                page.evaluate(RESULT_EXPRESSION, promise_timeout_ms=15_000)
            )


def assert_harness(engine: str, payload: dict[str, Any]) -> None:
    error = payload.get("harnessError")
    failures = payload.get("failures", [])
    if error is not None or failures:
        first = failures[0] if failures else error
        snapshot = json.dumps(payload.get("result"), ensure_ascii=False, indent=2)
        raise AssertionError(
            f"{engine} stale-realm mismatch: {first}\n"
            f"harness error: {error}\n"
            f"probe snapshot:\n{snapshot}"
        )


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument("--chrome-endpoint")
    parser.add_argument("--library", type=Path)
    parser.add_argument("--wreq", type=Path)
    parser.add_argument("--print-json", action="store_true")
    args = parser.parse_args()

    if args.chrome_endpoint is None and args.library is None:
        parser.error("pass --chrome-endpoint and/or --library with --wreq")
    if (args.library is None) != (args.wreq is None):
        parser.error("--library and --wreq must be supplied together")

    with fixture_server(root) as base_url:
        url = (
            base_url
            + FIXTURE
            + "?__darkpanda_test_runner=1"
        )

        if args.chrome_endpoint is not None:
            version, chrome = chrome_probe(args.chrome_endpoint, url)
            assert_harness("Chrome 149", chrome)
            if args.print_json:
                print(json.dumps(chrome["result"], ensure_ascii=False, indent=2))
            print(
                "PASS Chrome oracle "
                f"{version['Browser']} / V8 {version['V8-Version']}"
            )

        if args.library is not None and args.wreq is not None:
            native = darkpanda_probe(args.library, args.wreq, url)
            assert_harness("DarkPanda", native)
            if args.print_json:
                print(json.dumps(native["result"], ensure_ascii=False, indent=2))
            print("PASS DarkPanda stale WindowProxy/realm regression")


if __name__ == "__main__":
    main()
