"""Local authored coverage for privacy-minimized Page network observations.

The fixture exercises the root page, a descendant iframe, an image, page
fetches, a Dedicated Worker entry script and a Worker-owned fetch. It uses only
the direct embedding ABI and a loopback server; there is no CDP dependency.
"""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import threading
from urllib.parse import urlsplit

from darkpanda import ClientProfile, NetworkObservationBatch, Runtime


_IMAGE_TOKEN = "aB9kLm2NpQ7rSt4UvW8xYz6"
_WORKER_UUID = "550e8400-e29b-41d4-a716-446655440000"
_FORBIDDEN = (
    "top-secret-value",
    "child-secret-value",
    "image-secret-value",
    "worker-entry-secret",
    "worker-fetch-secret",
    "after-secret-value",
)


class _Server(ThreadingHTTPServer):
    daemon_threads = True


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = ""
    sys_version = ""

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def _reply(self, body: bytes, content_type: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        path = urlsplit(self.path).path
        if path == "/index.html":
            body = f"""<!doctype html><meta charset=utf-8><body><script>
                globalThis.__networkReady = (async () => {{
                    const childDone = new Promise(resolve => addEventListener(
                        'message', event => {{ if (event.data === 'child-ready') resolve(true); }},
                        {{once: true}}
                    ));
                    const iframe = document.createElement('iframe');
                    iframe.src = '/child/static?child=child-secret-value';
                    document.body.appendChild(iframe);

                    const imageDone = new Promise((resolve, reject) => {{
                        const image = new Image();
                        image.onload = () => resolve(true);
                        image.onerror = reject;
                        image.src = '/assets/{_IMAGE_TOKEN}.png?image=image-secret-value';
                        document.body.appendChild(image);
                    }});

                    const workerDone = new Promise((resolve, reject) => {{
                        const worker = new Worker('/worker.js?entry=worker-entry-secret');
                        worker.onmessage = event => resolve(event.data);
                        worker.onerror = reject;
                    }});
                    const topFetch = fetch('/api/123?top=top-secret-value').then(r => r.text());
                    await Promise.all([childDone, imageDone, workerDone, topFetch]);
                    return true;
                }})();
            </script></body>""".encode("utf-8")
            self._reply(body, "text/html; charset=utf-8")
            return
        if path == "/child/static":
            self._reply(
                b"<!doctype html><script>fetch('/child-fetch/static.json?child=child-secret-value')"
                b".then(r=>r.text()).then(()=>parent.postMessage('child-ready','*'))</script>",
                "text/html; charset=utf-8",
            )
            return
        if path == "/worker.js":
            self._reply(
                f"fetch('/worker-fetch/{_WORKER_UUID}?worker=worker-fetch-secret')"
                ".then(r=>r.text()).then(()=>postMessage('worker-ready'));".encode("ascii"),
                "text/javascript; charset=utf-8",
            )
            return
        if path.endswith(".png"):
            # Fetch completion is what this test observes; the image bytes need
            # only be a valid 1x1 transparent PNG for the DOM load event.
            self._reply(
                bytes.fromhex(
                    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
                    "0000000d49444154789c6360000000020001e221bc330000000049454e44ae426082"
                ),
                "image/png",
            )
            return
        if path.startswith(("/api/", "/child-fetch/", "/worker-fetch/", "/after/")):
            self._reply(b"ok", "text/plain; charset=utf-8")
            return
        self.send_error(404)


def _runtime_kwargs(args: argparse.Namespace) -> dict[str, object]:
    result: dict[str, object] = {
        "library_path": args.library,
        "navigation_timeout_ms": 30_000,
        "locale": "en-US",
        "timezone": "UTC",
        "profile": ClientProfile.CHROME149,
    }
    if os.name == "nt":
        result["wreq_transport_path"] = args.wreq
    return result


def _assert_initial_batch(batch: NetworkObservationBatch, expected_host: str) -> None:
    assert batch.observations, batch
    assert batch.dropped_count == 0, batch
    assert tuple(o.sequence for o in batch.observations) == tuple(
        sorted(o.sequence for o in batch.observations)
    )
    assert batch.latest_sequence >= batch.observations[-1].sequence
    assert {o.host for o in batch.observations} == {expected_host}

    retained_text = json.dumps(
        [
            {
                "host": o.host,
                "path": o.path_category,
            }
            for o in batch.observations
        ],
        separators=(",", ":"),
    )
    for secret in _FORBIDDEN:
        assert secret not in retained_text, retained_text
    assert "?" not in retained_text and "#" not in retained_text

    paths = {o.path_category for o in batch.observations}
    assert "/api/:number" in paths, paths
    assert "/assets/:token" in paths, paths
    assert "/worker-fetch/:uuid" in paths, paths

    roots = {o.root_frame_id for o in batch.observations}
    assert len(roots) == 1, roots
    root = next(iter(roots))
    assert any(o.frame_id != root and o.resource_type == "Document" for o in batch.observations)
    assert any(
        o.initiator_context == "worker" and o.resource_type == "Fetch"
        for o in batch.observations
    )

    phases_by_request: dict[tuple[str, int, int], set[str]] = {}
    for observation in batch.observations:
        if observation.phase == "fail":
            assert observation.failure_kind in {
                "timeout",
                "dns",
                "connect",
                "tls",
                "http2",
                "cancelled",
                "transport",
            }, observation
        else:
            assert observation.failure_kind is None, observation
        key = (
            observation.initiator_context,
            observation.frame_id,
            observation.request_id,
        )
        phases_by_request.setdefault(key, set()).add(observation.phase)
    for phases in phases_by_request.values():
        assert "start" in phases, phases
        assert "done" in phases or "fail" in phases, phases


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq")
    args = parser.parse_args()
    if os.name == "nt" and not args.wreq:
        parser.error("--wreq is required on Windows")
    if os.name != "nt" and args.wreq is not None:
        parser.error("--wreq is Windows-only")

    server = _Server(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, name="ffi-network-observations", daemon=True)
    thread.start()
    host, port = server.server_address
    expected_host = f"{host}:{port}"
    try:
        with Runtime(**_runtime_kwargs(args)) as runtime:
            with runtime.new_page() as page:
                page.navigate(
                    f"http://{expected_host}/index.html?navigation=top-secret-value",
                    timeout_ms=30_000,
                )
                assert json.loads(page.evaluate("globalThis.__networkReady", promise_timeout_ms=20_000)) is True

                first = page.network_observations()
                _assert_initial_batch(first, expected_host)

                acknowledged = page.network_observations(since_sequence=first.latest_sequence)
                assert acknowledged.observations == (), acknowledged
                assert acknowledged.dropped_count == 0, acknowledged

                assert page.evaluate(
                    "fetch('/after/static?after=after-secret-value').then(r=>r.text())",
                    promise_timeout_ms=10_000,
                ) == '"ok"'
                second = page.network_observations(since_sequence=first.latest_sequence)
                assert second.observations, second
                assert all(o.sequence > first.latest_sequence for o in second.observations)
                assert any(o.path_category == "/after/static" for o in second.observations)
                assert second.dropped_count == 0, second
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    print("darkpanda native network observations: PASS")


if __name__ == "__main__":
    main()
