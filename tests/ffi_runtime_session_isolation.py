"""Regression for logical Runtime isolation on the persistent native worker.

The test is intentionally local-only and uses the direct ctypes API.  It
creates two logical Runtime generations in one process so the second one must
reuse the physical worker while receiving a fresh browser Session.
"""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from threading import Lock, Thread
from typing import cast

from darkpanda import ClientProfile, Page, Runtime


_COOKIE_NAME = "dp_runtime_isolation"
_LOCAL_KEY = "dp-runtime-local"
_SESSION_KEY = "dp-runtime-session"


class _FixtureServer(ThreadingHTTPServer):
    daemon_threads = True

    requests: list[tuple[str, str | None]]
    requests_lock: Lock


class _FixtureHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        server = cast(_FixtureServer, self.server)
        with server.requests_lock:
            server.requests.append((self.path, self.headers.get("Cookie")))

        body = b"<!doctype html><meta charset=utf-8><title>session isolation</title>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        del format, args


def _snapshot(page: Page) -> dict[str, object]:
    return json.loads(
        page.evaluate(
            f"""({{
                cookie: document.cookie,
                localValue: localStorage.getItem({_LOCAL_KEY!r}),
                localLength: localStorage.length,
                sessionValue: sessionStorage.getItem({_SESSION_KEY!r}),
                sessionLength: sessionStorage.length,
                historyLength: history.length,
                historyState: history.state,
                hash: location.hash
            }})"""
        )
    )


def _expected_initial_state() -> dict[str, object]:
    return {
        "cookie": "",
        "localValue": None,
        "localLength": 0,
        "sessionValue": None,
        "sessionLength": 0,
        "historyLength": 1,
        "historyState": None,
        "hash": "",
    }


def _runtime_kwargs(args: argparse.Namespace) -> dict[str, object]:
    return {
        "library_path": args.library,
        "wreq_library_path": args.wreq,
        "navigation_timeout_ms": 10_000,
        "locale": "en-US",
        "timezone": "UTC",
        "profile": ClientProfile.CHROME149,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq", required=True)
    args = parser.parse_args()

    if os.name != "nt":
        parser.error("this regression targets the native Windows wreq build")

    server = _FixtureServer(("127.0.0.1", 0), _FixtureHandler)
    server.requests = []
    server.requests_lock = Lock()
    server_thread = Thread(
        target=server.serve_forever,
        name="darkpanda-session-isolation-http",
        daemon=True,
    )
    server_thread.start()

    port = int(server.server_address[1])
    first_url = f"http://127.0.0.1:{port}/runtime-one"
    second_url = f"http://127.0.0.1:{port}/runtime-two"
    runtime_kwargs = _runtime_kwargs(args)

    try:
        with Runtime(**runtime_kwargs) as runtime:
            with runtime.new_page() as page:
                page.navigate(first_url, timeout_ms=10_000)
                initial = _snapshot(page)
                assert initial == _expected_initial_state(), initial

                mutated = json.loads(
                    page.evaluate(
                        f"""(() => {{
                            document.cookie =
                                {_COOKIE_NAME + '=runtime-one; Path=/; SameSite=Lax'!r};
                            localStorage.setItem({_LOCAL_KEY!r}, 'runtime-one');
                            sessionStorage.setItem({_SESSION_KEY!r}, 'runtime-one');
                            history.pushState({{owner: 'runtime-one'}}, '', '#runtime-one');
                            return {{
                                cookie: document.cookie,
                                localValue: localStorage.getItem({_LOCAL_KEY!r}),
                                sessionValue: sessionStorage.getItem({_SESSION_KEY!r}),
                                historyLength: history.length,
                                historyState: history.state,
                                hash: location.hash
                            }};
                        }})()"""
                    )
                )
                assert f"{_COOKIE_NAME}=runtime-one" in str(mutated["cookie"]), mutated
                assert mutated["localValue"] == "runtime-one", mutated
                assert mutated["sessionValue"] == "runtime-one", mutated
                assert mutated["historyLength"] == 2, mutated
                assert mutated["historyState"] == {"owner": "runtime-one"}, mutated
                assert mutated["hash"] == "#runtime-one", mutated

        # Runtime.close() above releases the logical generation.  Runtime two
        # must reuse the native worker but observe a newly constructed Session.
        with Runtime(**runtime_kwargs) as runtime:
            with runtime.new_page() as page:
                page.navigate(second_url, timeout_ms=10_000)
                isolated = _snapshot(page)
                assert isolated == _expected_initial_state(), isolated

        with server.requests_lock:
            first_requests = [cookie for path, cookie in server.requests if path == "/runtime-one"]
            second_requests = [cookie for path, cookie in server.requests if path == "/runtime-two"]
        assert len(first_requests) == 1, server.requests
        assert len(second_requests) == 1, server.requests
        assert not first_requests[0], first_requests
        assert not second_requests[0], (
            "the second logical Runtime leaked the first Runtime cookie onto the wire",
            second_requests,
        )
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=5)

    assert not server_thread.is_alive(), "local HTTP fixture did not stop"
    print("darkpanda native logical Runtime session isolation: PASS")


if __name__ == "__main__":
    main()
