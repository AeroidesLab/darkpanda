"""Chrome-149 WindowProxy identity and dynamic-origin security regression.

The parent and both A documents use 127.0.0.1.  The B document uses the
localhost host alias on the same loopback server, making it cross-origin
without relying on any external site.  A single JavaScript WindowProxy is kept
across A1 -> B -> A2 so the test catches implementations that select a static
same-origin or cross-origin wrapper when the property is first accessed.
"""

from __future__ import annotations

import argparse
import contextlib
import http.server
import json
import threading
import urllib.parse
from typing import Iterator

from darkpanda import ClientProfile, Runtime


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        path = urllib.parse.urlsplit(self.path).path
        port = int(self.server.server_address[1])
        if path == "/root":
            body = f"""<!doctype html><meta charset=utf-8>
<title>WindowProxy A-B-A parent</title>
<iframe id=child src="http://127.0.0.1:{port}/child-a1"></iframe>
""".encode()
        elif path == "/child-a1":
            body = (
                "<!doctype html><meta charset=utf-8>"
                "<body data-phase=a1>same-origin A1</body>"
            ).encode()
        elif path == "/child-b":
            body = (
                "<!doctype html><meta charset=utf-8>"
                "<body data-phase=b>cross-origin B</body>"
            ).encode()
        elif path == "/child-a2":
            body = (
                "<!doctype html><meta charset=utf-8>"
                "<body data-phase=a2>same-origin A2</body>"
            ).encode()
        else:
            self.send_error(404)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        del format, args


@contextlib.contextmanager
def fixture_server() -> Iterator[int]:
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield int(server.server_address[1])
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def evaluate_json(page: object, expression: str, timeout_ms: int = 10_000) -> dict:
    return json.loads(
        page.evaluate(expression, promise_timeout_ms=timeout_ms)  # type: ignore[attr-defined]
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq", required=True)
    args = parser.parse_args()

    with fixture_server() as port, Runtime(
        library_path=args.library,
        wreq_library_path=args.wreq,
        navigation_timeout_ms=15_000,
        profile=ClientProfile.CHROME149,
    ) as runtime:
        root = f"http://127.0.0.1:{port}/root"
        b_url = f"http://localhost:{port}/child-b"
        a2_url = f"http://127.0.0.1:{port}/child-a2"

        with runtime.new_page() as page:
            page.navigate(root, timeout_ms=15_000)

            initial = evaluate_json(
                page,
                """JSON.stringify((() => {
                  const iframe = document.getElementById('child');
                  window.__stableWindowProxy = iframe.contentWindow;
                  window.__a1Document = __stableWindowProxy.document;
                  return {
                    identity: __stableWindowProxy === iframe.contentWindow,
                    documentIdentity: __a1Document === iframe.contentDocument,
                    phase: __a1Document.body.dataset.phase,
                    href: __stableWindowProxy.location.href
                  };
                })())""",
            )
            assert initial == {
                "identity": True,
                "documentIdentity": True,
                "phase": "a1",
                "href": f"http://127.0.0.1:{port}/child-a1",
            }, initial

            crossed = evaluate_json(
                page,
                f"""new Promise((resolve, reject) => {{
                  const iframe = document.getElementById('child');
                  const timer = setTimeout(
                    () => reject(new Error('B navigation timeout')),
                    5000
                  );
                  iframe.onload = () => {{
                    clearTimeout(timer);
                    let error = null;
                    try {{ void __stableWindowProxy.document; }}
                    catch (caught) {{
                      error = {{
                        name: caught.name,
                        code: caught.code,
                        message: caught.message,
                        dom: caught instanceof DOMException
                      }};
                    }}
                    resolve(JSON.stringify({{
                      identity: __stableWindowProxy === iframe.contentWindow,
                      nullPrototype: Object.getPrototypeOf(__stableWindowProxy) === null,
                      error
                    }}));
                  }};
                  iframe.src = {json.dumps(b_url)};
                }})""",
            )
            blocked = (
                "Failed to read a named property 'document' from 'Window': "
                f'Blocked a frame with origin "http://127.0.0.1:{port}" '
                "from accessing a cross-origin frame."
            )
            assert crossed == {
                "identity": True,
                "nullPrototype": True,
                "error": {
                    "name": "SecurityError",
                    "code": 18,
                    "message": blocked,
                    "dom": True,
                },
            }, crossed

            returned = evaluate_json(
                page,
                f"""new Promise((resolve, reject) => {{
                  const iframe = document.getElementById('child');
                  const timer = setTimeout(
                    () => reject(new Error('A2 navigation timeout')),
                    5000
                  );
                  iframe.onload = () => {{
                    clearTimeout(timer);
                    let error = null;
                    let result = null;
                    try {{
                      result = {{
                        identity: __stableWindowProxy === iframe.contentWindow,
                        documentIdentity:
                          __stableWindowProxy.document === iframe.contentDocument,
                        replacedDocument:
                          __stableWindowProxy.document !== __a1Document,
                        phase: __stableWindowProxy.document.body.dataset.phase,
                        href: __stableWindowProxy.location.href
                      }};
                    }} catch (caught) {{
                      error = {{
                        name: caught.name,
                        code: caught.code,
                        message: caught.message,
                        dom: caught instanceof DOMException
                      }};
                    }}
                    resolve(JSON.stringify({{result, error}}));
                  }};
                  iframe.src = {json.dumps(a2_url)};
                }})""",
            )
            assert returned == {
                "result": {
                    "identity": True,
                    "documentIdentity": True,
                    "replacedDocument": True,
                    "phase": "a2",
                    "href": a2_url,
                },
                "error": None,
            }, returned

    print("WindowProxy A-B-A navigation security: PASS")


if __name__ == "__main__":
    main()
