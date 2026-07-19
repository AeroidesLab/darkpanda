"""Generic Chrome-149 ancestor-navigation security regression.

The fixture uses loopback host aliases as distinct origins. It contains no
production-domain or challenge-specific logic: every assertion is about the
HTML allowed-to-navigate algorithm, user activation, or iframe sandboxing.
"""

from __future__ import annotations

import argparse
import contextlib
import http.server
import json
import threading
import time
import urllib.parse
from typing import Iterator

from darkpanda import ClientProfile, Runtime


PARENT = """<!doctype html><meta charset=utf-8>
<script>
window.reports = [];
addEventListener('message', event => {
  if (event.data && event.data.kind === 'navigation-security') {
    reports.push(event.data);
  }
});
</script>
<iframe id=child {sandbox} src="http://localhost:{port}/child"></iframe>
"""


CHILD = r"""<!doctype html><meta charset=utf-8>
<a id=native target=_top>native activation navigation</a>
<script>
const native = document.getElementById('native');
const report = value => parent.postMessage({kind:'navigation-security', ...value}, '*');
report({phase:'ready'});
addEventListener('message', event => {
  const {id, mechanism, destination} = event.data || {};
  if (!id) return;
  let result = null;
  let error = null;
  try {
    if (mechanism === 'form') {
      const form = document.createElement('form');
      form.action = destination;
      form.target = '_top';
      document.body.append(form);
      form.submit();
    } else if (mechanism === 'anchor') {
      const anchor = document.createElement('a');
      anchor.href = destination;
      anchor.target = '_top';
      document.body.append(anchor);
      anchor.click();
    } else if (mechanism === 'open') {
      result = window.open(destination, '_top') === null ? 'null' : 'window';
    } else if (mechanism === 'location') {
      top.location = destination;
    } else if (mechanism === 'location_href') {
      top.location.href = destination;
    } else if (mechanism === 'domain') {
      document.domain = document.domain;
      result = 'assigned';
    } else if (mechanism === 'arm_native') {
      native.href = destination;
      result = 'armed';
    }
  } catch (caught) {
    error = {
      name: caught.name,
      message: caught.message,
      code: caught.code,
      dom: caught instanceof DOMException
    };
  }
  report({phase:'result', id, mechanism, result, error});
});
</script>
"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlsplit(self.path)
        port = self.server.server_address[1]
        if parsed.path == "/child":
            body = CHILD.encode()
        elif parsed.path.startswith("/root"):
            sandbox = {
                "/root-sandbox": 'sandbox="allow-scripts allow-same-origin"',
                "/root-sandbox-activation": (
                    'sandbox="allow-scripts allow-same-origin '
                    'allow-top-navigation-by-user-activation"'
                ),
            }.get(parsed.path, "")
            body = (
                PARENT.replace("{port}", str(port)).replace("{sandbox}", sandbox)
            ).encode()
        else:
            body = f"<!doctype html><title>{parsed.path}</title>destination".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
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


def wait_ready(page) -> None:
    page.evaluate(
        """new Promise((resolve, reject) => {
          const end = Date.now() + 5000;
          const poll = () => {
            if (reports.some(x => x.phase === 'ready')) return resolve(true);
            if (Date.now() > end) return reject(new Error('child ready timeout'));
            setTimeout(poll, 5);
          };
          poll();
        })""",
        promise_timeout_ms=7_000,
    )


def child_frame_id(page) -> int:
    children = [frame for frame in page.frames(attached=True) if not frame.is_root]
    assert len(children) == 1, children
    return children[0].frame_id


def send_attempt(page, attempt_id: str, mechanism: str, destination: str) -> dict:
    encoded = json.dumps(
        {"id": attempt_id, "mechanism": mechanism, "destination": destination}
    )
    result = page.evaluate(
        f"""new Promise((resolve, reject) => {{
          const payload = {encoded};
          document.getElementById('child').contentWindow.postMessage(payload, '*');
          const end = Date.now() + 5000;
          const poll = () => {{
            const item = reports.find(x => x.phase === 'result' && x.id === payload.id);
            if (item) return resolve(JSON.stringify(item));
            if (Date.now() > end) return reject(new Error('attempt timeout'));
            setTimeout(poll, 5);
          }};
          poll();
        }})""",
        promise_timeout_ms=7_000,
    )
    return json.loads(result)


def href(page) -> str:
    return str(page.evaluate("location.href"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq", required=True)
    args = parser.parse_args()

    with fixture_server() as port, Runtime(
        library_path=args.library,
        wreq_transport_path=args.wreq,
        navigation_timeout_ms=15_000,
        profile=ClientProfile.CHROME149,
    ) as runtime:
        root = f"http://127.0.0.1:{port}/root"
        blocked_destinations = [
            f"http://localhost:{port}/blocked-b",
            f"http://127.0.0.2:{port}/blocked-c",
        ]

        # Programmatic/no-activation child -> top takeover must fail for both
        # child-origin and unrelated destinations. Use a fresh Page per attempt
        # so a regression cannot hide subsequent failures by replacing the test.
        for mechanism in ("form", "anchor", "open", "location", "location_href"):
            for index, destination in enumerate(blocked_destinations):
                with runtime.new_page() as page:
                    page.navigate(root, timeout_ms=15_000)
                    wait_ready(page)
                    before = href(page)
                    report = send_attempt(page, f"{mechanism}-{index}", mechanism, destination)
                    time.sleep(0.15)
                    assert href(page) == before, (mechanism, destination, report, href(page))
                    if mechanism == "open":
                        assert report["result"] == "null", report
                    if mechanism in ("location", "location_href"):
                        error = report["error"]
                        assert error and error["name"] == "SecurityError", report
                        assert error["code"] == 18 and error["dom"], report

        # Destination same-origin with the current top is the Chrome exception
        # that does not require activation.
        with runtime.new_page() as page:
            page.navigate(root, timeout_ms=15_000)
            wait_ready(page)
            allowed = f"http://127.0.0.1:{port}/allowed-a"
            send_attempt(page, "allowed-a", "open", allowed)
            deadline = time.time() + 5
            while time.time() < deadline and href(page) != allowed:
                time.sleep(0.02)
            assert href(page) == allowed

        # A real trusted pointer press gives the source frame sticky activation.
        with runtime.new_page() as page:
            page.navigate(root, timeout_ms=15_000)
            wait_ready(page)
            destination = f"http://localhost:{port}/allowed-activation"
            send_attempt(page, "arm-native", "arm_native", destination)
            page.click("#native", child_frame_id(page), True, 5_000)
            deadline = time.time() + 5
            while time.time() < deadline and href(page) != destination:
                time.sleep(0.02)
            assert href(page) == destination

        # Adding sandbox to an already-loaded iframe updates only the pending
        # frame policy. The current unsandboxed Document keeps its permissions.
        with runtime.new_page() as page:
            page.navigate(root, timeout_ms=15_000)
            wait_ready(page)
            page.evaluate(
                "document.getElementById('child').setAttribute("
                "'sandbox', 'allow-scripts allow-same-origin')"
            )
            destination = f"http://localhost:{port}/sandbox-addition-not-yet-active"
            send_attempt(page, "arm-sandbox-addition", "arm_native", destination)
            page.click("#native", child_frame_id(page), True, 5_000)
            deadline = time.time() + 5
            while time.time() < deadline and href(page) != destination:
                time.sleep(0.02)
            assert href(page) == destination

        # A subsequent cross-document child navigation commits that pending
        # policy; the replacement Document is sandboxed and cannot take top.
        with runtime.new_page() as page:
            page.navigate(root, timeout_ms=15_000)
            wait_ready(page)
            page.evaluate(
                """(() => {
                  reports.length = 0;
                  const child = document.getElementById('child');
                  child.setAttribute('sandbox', 'allow-scripts allow-same-origin');
                  child.src = child.src + '?sandbox-commit=1';
                })()"""
            )
            wait_ready(page)
            destination = f"http://localhost:{port}/sandbox-addition-committed"
            send_attempt(page, "arm-sandbox-committed", "arm_native", destination)
            page.click("#native", child_frame_id(page), True, 5_000)
            time.sleep(0.15)
            assert href(page) == root

        # Sandbox without either top-navigation token remains a stronger denial,
        # even after a trusted click.
        with runtime.new_page() as page:
            sandbox_root = f"http://127.0.0.1:{port}/root-sandbox"
            page.navigate(sandbox_root, timeout_ms=15_000)
            wait_ready(page)
            domain_report = send_attempt(page, "sandbox-domain", "domain", "")
            domain_error = domain_report["error"]
            assert domain_error and domain_error["name"] == "SecurityError", domain_report
            assert domain_error["code"] == 18 and domain_error["dom"], domain_report
            assert domain_error["message"] == (
                "Failed to set the 'domain' property on 'Document': "
                "Assignment is forbidden for sandboxed iframes."
            ), domain_report
            destination = f"http://localhost:{port}/sandbox-blocked"
            send_attempt(page, "arm-sandbox", "arm_native", destination)
            page.click("#native", child_frame_id(page), True, 5_000)
            time.sleep(0.15)
            assert href(page) == sandbox_root

        # The sandboxing flag set belongs to the already-loaded child
        # Document. Removing the owner iframe's attribute affects a future
        # navigation only; it must not unsandbox the current Document.
        with runtime.new_page() as page:
            sandbox_root = f"http://127.0.0.1:{port}/root-sandbox"
            page.navigate(sandbox_root, timeout_ms=15_000)
            wait_ready(page)
            page.evaluate("document.getElementById('child').removeAttribute('sandbox')")
            destination = f"http://localhost:{port}/sandbox-removal-blocked"
            send_attempt(page, "arm-sandbox-removal", "arm_native", destination)
            page.click("#native", child_frame_id(page), True, 5_000)
            time.sleep(0.15)
            assert href(page) == sandbox_root

        # allow-top-navigation-by-user-activation is allowed only on the same
        # trusted path.
        with runtime.new_page() as page:
            activated_root = f"http://127.0.0.1:{port}/root-sandbox-activation"
            page.navigate(activated_root, timeout_ms=15_000)
            wait_ready(page)
            destination = f"http://localhost:{port}/sandbox-activation-allowed"
            send_attempt(page, "arm-sandbox-activation", "arm_native", destination)
            page.click("#native", child_frame_id(page), True, 5_000)
            deadline = time.time() + 5
            while time.time() < deadline and href(page) != destination:
                time.sleep(0.02)
            assert href(page) == destination

    print("navigation security: PASS")


if __name__ == "__main__":
    main()
