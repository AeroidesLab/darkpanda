"""Offline wire-level regression for native-ABI Fetch request context.

The test intentionally uses only a loopback ``ThreadingHTTPServer`` and the
in-process Python ABI.  It has no CDP, subprocess, or external-network path.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
from typing import ClassVar

from darkpanda import ClientProfile, Runtime


AUTHOR_ACCEPT = "application/darkpanda-request-context+json"
AUTHOR_CONTENT_TYPE = "application/darkpanda-test"
AUTHOR_X_TEST = "author-header-preserved"
REQUEST_BODY = b"darkpanda-request-body=present"
TRUSTED_COOKIE = "server_cookie=trusted"
FORGED_ORIGIN = "https://forged.invalid"
FORGED_REFERER = "https://forged.invalid/overridden"
FORGED_USER_AGENT = "forged-user-agent/0"
EXPECTED_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/149.0.0.0 Safari/537.36"
)


@dataclass(frozen=True)
class Observation:
    path: str
    headers: tuple[tuple[str, str], ...]
    body: bytes

    def values(self, name: str) -> list[str]:
        return [value for key, value in self.headers if key.lower() == name.lower()]

    def one(self, name: str) -> str:
        values = self.values(name)
        assert len(values) == 1, f"expected one {name!r} header, got {values!r}"
        return values[0]


class CaptureServer(ThreadingHTTPServer):
    daemon_threads = True
    observations: list[Observation]
    observation_ready: threading.Event


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = ""
    sys_version = ""

    PAGE: ClassVar[bytes] = b"<!doctype html><meta charset=utf-8><title>request-context</title>"

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def _reply(
        self,
        status: int,
        body: bytes,
        *,
        content_type: str,
        extra_headers: tuple[tuple[str, str], ...] = (),
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for name, value in extra_headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path == "/page":
            self._reply(
                200,
                self.PAGE,
                content_type="text/html; charset=utf-8",
                extra_headers=(("Set-Cookie", f"{TRUSTED_COOKIE}; Path=/; HttpOnly"),),
            )
            return
        self._reply(404, b"not found", content_type="text/plain; charset=utf-8")

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        observation = Observation(
            path=self.path,
            headers=tuple(self.headers.raw_items()),
            body=body,
        )
        server = self.server
        assert isinstance(server, CaptureServer)
        server.observations.append(observation)
        server.observation_ready.set()

        response = json.dumps(
            {"received": len(body), "path": self.path},
            separators=(",", ":"),
        ).encode("ascii")
        self._reply(200, response, content_type="application/json")


def _assert_wire(observation: Observation, *, origin: str, page_url: str) -> None:
    assert observation.path == "/echo", observation
    assert observation.body == REQUEST_BODY, observation.body

    # wreq must not emit an actual empty Expect field. An absent Expect header
    # is Chrome-like.
    expect_values = observation.values("Expect")
    assert all(value.strip() for value in expect_values), expect_values

    # These fields are browser/network controlled.  Author-supplied values
    # must not replace or duplicate the generated Chrome149 request context.
    assert observation.one("Origin") == origin
    assert observation.one("Referer") == page_url
    assert observation.one("User-Agent") == EXPECTED_USER_AGENT
    assert observation.one("Sec-Fetch-Site") == "same-origin"
    assert observation.one("Sec-Fetch-Mode") == "cors"
    assert observation.one("Sec-Fetch-Dest") == "empty"
    assert observation.one("Cookie") == TRUSTED_COOKIE

    forbidden_values = (
        FORGED_ORIGIN,
        FORGED_REFERER,
        FORGED_USER_AGENT,
        "cross-site",
        "navigate",
        "document",
        "forged_cookie=1",
    )
    flattened = "\n".join(value for _name, value in observation.headers)
    for forbidden in forbidden_values:
        assert forbidden not in flattened, (forbidden, observation.headers)

    # These author-controlled fields remain legal and must replace/default or
    # append normally at the wire boundary.
    assert observation.one("Accept") == AUTHOR_ACCEPT
    assert observation.one("X-Test") == AUTHOR_X_TEST
    assert observation.one("Content-Type") == AUTHOR_CONTENT_TYPE


def _runtime_kwargs(args: argparse.Namespace) -> dict[str, object]:
    kwargs: dict[str, object] = {
        "library_path": args.library,
        "navigation_timeout_ms": 30_000,
        "locale": "en-US",
        "timezone": "UTC",
        "profile": ClientProfile.CHROME149,
    }
    kwargs["wreq_library_path"] = args.wreq
    return kwargs


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq", required=True)
    args = parser.parse_args()

    server = CaptureServer(("127.0.0.1", 0), Handler)
    server.observations = []
    server.observation_ready = threading.Event()
    thread = threading.Thread(target=server.serve_forever, name="ffi-request-context", daemon=True)
    thread.start()

    host, port = server.server_address
    origin = f"http://{host}:{port}"
    page_url = f"{origin}/page"
    try:
        with Runtime(**_runtime_kwargs(args)) as runtime:
            with runtime.new_page() as page:
                page.navigate(page_url, timeout_ms=30_000)
                result = json.loads(
                    page.evaluate(
                        f"""(async () => {{
                            const response = await fetch('/echo', {{
                                method: 'POST',
                                headers: {{
                                    'Origin': {json.dumps(FORGED_ORIGIN)},
                                    'Referer': {json.dumps(FORGED_REFERER)},
                                    'Sec-Fetch-Site': 'cross-site',
                                    'Sec-Fetch-Mode': 'navigate',
                                    'Sec-Fetch-Dest': 'document',
                                    'User-Agent': {json.dumps(FORGED_USER_AGENT)},
                                    'Cookie': 'forged_cookie=1',
                                    'Accept': {json.dumps(AUTHOR_ACCEPT)},
                                    'X-Test': {json.dumps(AUTHOR_X_TEST)},
                                    'Content-Type': {json.dumps(AUTHOR_CONTENT_TYPE)}
                                }},
                                body: {json.dumps(REQUEST_BODY.decode('ascii'))}
                            }});
                            return {{
                                status: response.status,
                                payload: await response.json()
                            }};
                        }})()""",
                        promise_timeout_ms=20_000,
                    )
                )
                assert result == {
                    "status": 200,
                    "payload": {"received": len(REQUEST_BODY), "path": "/echo"},
                }, result

        assert server.observation_ready.wait(2), "server did not observe POST /echo"
        assert len(server.observations) == 1, server.observations
        _assert_wire(server.observations[0], origin=origin, page_url=page_url)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    print("darkpanda native request context: PASS")


if __name__ == "__main__":
    main()
