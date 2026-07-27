"""Run high-signal browser regression pages through the native Python ABI."""

from __future__ import annotations

import argparse
import contextlib
import functools
import http.server
import json
from pathlib import Path
import threading
from typing import Iterator

from darkpanda import ClientProfile, Runtime


HARNESS_PAGES = (
    "window/cross_origin_security.html",
    "window/cross_origin_function_identity.html",
    "window/location_legacy_unforgeable.html",
    "window/v8_chromium_parity.html",
    "window/chromium_capability_surface.html",
    "window/webidl_descriptors.html",
    "window/window_agent_microtasks.html",
    "window/window_prototype_topology.html",
    "window/opaque_origin_inheritance.html",
    "worker/stack-limit.html",
    "worker/security-boundaries.html",
    "navigator/navigator.html",
    "window/fingerprint_profile_consistency.html",
    "canvas/canvas_rendering_context_2d.html",
    "element/css_style_enumeration.html",
    "event/message.html",
    "csp/code_generation_meta.html",
    "csp/code_generation_meta_dynamic.html",
    "csp/code_generation_meta_head_ancestor.html",
    "csp/code_generation_blob_worker.html",
    "csp/code_generation_local_documents.html",
)


def wait_for_harness(page: object, timeout_ms: int = 15_000) -> None:
    result = page.evaluate(
        f"""new Promise((resolve, reject) => {{
            const deadline = Date.now() + {timeout_ms};
            const poll = () => {{
                try {{
                    if (testing.assertOk()) return resolve(true);
                    if (Date.now() >= deadline) {{
                        testing.printTimeoutState();
                        return reject(new Error('HTML regression timeout'));
                    }}
                    setTimeout(poll, 5);
                }} catch (error) {{
                    reject(error);
                }}
            }};
            poll();
        }})""",
        promise_timeout_ms=timeout_ms + 5_000,
    )
    assert result == "true", result


def runner_url(base_url: str, relative_url: str) -> str:
    """Mark a page as a native test run without changing its Chrome UA."""
    separator = "&" if "?" in relative_url else "?"
    return f"{base_url}{relative_url}{separator}__darkpanda_test_runner=1"


class _CSPFixtureHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self) -> None:
        if self.path.partition("?")[0] == "/csp/code_generation_header.html":
            self.send_header(
                "Content-Security-Policy",
                "script-src 'self' 'unsafe-inline'",
            )
        super().end_headers()

    def log_message(self, format: str, *args: object) -> None:
        del format, args


@contextlib.contextmanager
def csp_fixture_server() -> Iterator[str]:
    test_root = Path(__file__).resolve().parents[1] / "src" / "browser" / "tests"
    handler = functools.partial(_CSPFixtureHandler, directory=str(test_root))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address[:2]
        yield f"http://{host}:{port}/"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq", required=True)
    parser.add_argument(
        "--base-url",
        default="http://127.0.0.1:9583/src/browser/tests/",
    )
    args = parser.parse_args()

    with Runtime(
        library_path=args.library,
        wreq_library_path=args.wreq,
        navigation_timeout_ms=30_000,
        locale="en-US",
        timezone="UTC",
        profile=ClientProfile.CHROME149,
    ) as runtime:
        for relative_url in HARNESS_PAGES:
            with runtime.new_page() as page:
                page.navigate(runner_url(args.base_url, relative_url), timeout_ms=30_000)
                # assertOk() returns false while an async test is pending. The
                # promise keeps the browser task queue pumping until the page
                # either completes or throws a precise assertion diagnostic.
                wait_for_harness(page)
            print(f"PASS {relative_url}")

        # Exercise the response-header delivery path with an actual enforced
        # Content-Security-Policy field. The ordinary static-file server cannot
        # add this header, so use a loopback fixture server rather than treating
        # a meta-policy result as equivalent evidence.
        with csp_fixture_server() as fixture_base:
            with runtime.new_page() as page:
                relative_url = "csp/code_generation_header.html"
                page.navigate(runner_url(fixture_base, relative_url), timeout_ms=30_000)
                wait_for_harness(page)
                print(f"PASS {relative_url} (response header)")

        with runtime.new_page() as page:
            relative_url = "worker/worker_prototype_topology.html"
            page.navigate(runner_url(args.base_url, relative_url), timeout_ms=30_000)
            topology = json.loads(
                page.evaluate(
                    "window.__workerPrototypeTopology",
                    promise_timeout_ms=20_000,
                )
            )
            assert topology["globalPrototypeIsDedicated"] is True, topology
            assert topology["workerPrototypeIsWorker"] is True, topology
            assert topology["eventTargetPrototypeIsNext"] is True, topology
            assert topology["dedicatedTag"] == "[object DedicatedWorkerGlobalScope]", topology
            assert topology["dedicatedKeys"] == [
                "TEMPORARY",
                "PERSISTENT",
                "constructor",
                "Symbol(Symbol.toStringTag)",
            ], topology
            assert topology["temporary"] == 0, topology
            assert topology["persistent"] == 1, topology
            assert topology["constantsOnPrototype"] is True, topology
            assert topology["constantsOnGlobal"] is False, topology
            assert topology["postMessageOnGlobal"] is True, topology
            assert topology["postMessageOnDedicatedPrototype"] is False, topology
            assert topology["importScriptsOnGlobal"] is False, topology
            assert topology["importScriptsOnWorkerPrototype"] is True, topology
            assert topology["addEventListenerOnGlobal"] is False, topology
            assert topology["addEventListenerOnEventTargetPrototype"] is True, topology
            print(f"PASS {relative_url}")

        # Execute the probe as a real parser-inserted page script.  This keeps
        # the script origin and task boundary symmetric with Chrome, unlike a
        # CDP-vs-FFI injected expression comparison.
        with runtime.new_page() as page:
            relative_url = "window/v8_task_stack_fixture.html"
            page.navigate(args.base_url + relative_url, timeout_ms=30_000)
            task_stack = json.loads(
                page.evaluate(
                    "window.__v8TaskStackProbe",
                    promise_timeout_ms=10_000,
                )
            )
            assert task_stack["order"] == [
                "script",
                "queueMicrotask",
                "promise",
                "timeout",
            ], task_stack
            assert task_stack["syntaxError"]["name"] == "SyntaxError", task_stack
            assert "Unexpected token '{'" in task_stack["syntaxError"]["message"], task_stack
            assert relative_url in task_stack["stack"], task_stack
            assert relative_url in task_stack["syntaxError"]["stack"], task_stack
            print(f"PASS {relative_url}")

        # The full performance/secure-context pages contain several module
        # tests. Their upstream test harness deliberately cannot assign module
        # IDs when the coherent Chrome profile is selected, so probe the same
        # high-signal invariants directly on a plain local page.
        with runtime.new_page() as page:
            page.navigate(
                args.base_url + "performance_resource_timing_fixture.html",
                timeout_ms=30_000,
            )
            snapshot = json.loads(
                page.evaluate(
                    """({
                        clockDelta: Date.now() - performance.timeOrigin - performance.now(),
                        timeOrigin: performance.timeOrigin,
                        secure: isSecureContext,
                        userAgent: navigator.userAgent
                    })"""
                )
            )
            assert abs(float(snapshot["clockDelta"])) < 50, snapshot
            assert float(snapshot["timeOrigin"]) > 1_000_000_000_000, snapshot
            assert snapshot["secure"] is True, snapshot
            assert "Chrome/149.0.0.0" in str(snapshot["userAgent"]), snapshot

            microtasks = json.loads(
                page.evaluate(
                    """(async () => {
                        const order = [];
                        queueMicrotask(() => order.push('queueMicrotask'));
                        Promise.resolve().then(() => order.push('promise'));
                        order.push('script');
                        await new Promise(resolve => setTimeout(() => {
                            order.push('timeout');
                            resolve();
                        }, 0));
                        return order;
                    })()""",
                    promise_timeout_ms=10_000,
                )
            )
            assert microtasks == [
                "script",
                "queueMicrotask",
                "promise",
                "timeout",
            ], microtasks

            wasm = json.loads(
                page.evaluate(
                    """(async () => {
                        const bytes = new Uint8Array([
                            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00
                        ]);
                        const response = new Response(bytes, {
                            headers: {'Content-Type': 'application/wasm'}
                        });
                        const module = await WebAssembly.compileStreaming(response);
                        let overLimit;
                        try {
                            new WebAssembly.Module(new Uint8Array((1 << 23) + 1));
                            overLimit = {name: '', message: ''};
                        } catch (error) {
                            overLimit = {name: error.name, message: error.message};
                        }
                        return {
                            compileStreaming: typeof WebAssembly.compileStreaming,
                            module: module instanceof WebAssembly.Module,
                            bodyUsed: response.bodyUsed,
                            overLimit
                        };
                    })()""",
                    promise_timeout_ms=20_000,
                )
            )
            assert wasm["compileStreaming"] == "function", wasm
            assert wasm["module"] is True and wasm["bodyUsed"] is True, wasm
            assert wasm["overLimit"]["name"] == "RangeError", wasm
            assert "larger than 8MB" in wasm["overLimit"]["message"], wasm

            worker = json.loads(
                page.evaluate(
                    """new Promise((resolve, reject) => {
                        const url = URL.createObjectURL(new Blob([
                            `postMessage(JSON.stringify({secure: isSecureContext,
                                origin: location.origin}))`
                        ], {type: 'text/javascript'}));
                        const worker = new Worker(url);
                        worker.onmessage = event => {
                            worker.terminate();
                            URL.revokeObjectURL(url);
                            resolve(event.data);
                        };
                        worker.onerror = event => reject(new Error(event.message));
                    })""",
                    promise_timeout_ms=10_000,
                )
            )
            assert worker["secure"] is True, worker
            print("PASS performance/secure-context direct invariants")

        with runtime.new_page() as page:
            relative_url = "worker/blob-worker-regression.html"
            page.navigate(args.base_url + relative_url, timeout_ms=30_000)
            result = page.evaluate(
                """new Promise((resolve, reject) => {
                    const deadline = Date.now() + 10000;
                    const poll = () => {
                        const node = document.querySelector('#result');
                        const status = node?.dataset.status;
                        if (status === 'pass') return resolve(node.textContent);
                        if (status === 'fail') return reject(new Error(node.textContent));
                        if (Date.now() >= deadline) return reject(new Error('blob worker timeout'));
                        setTimeout(poll, 5);
                    };
                    poll();
                })""",
                promise_timeout_ms=15_000,
            )
            assert result == "blob-worker-pass", result
            print(f"PASS {relative_url}")

        # A root blob: navigation tears down the creating document. The
        # navigation loader must pin the resolved Blob before that teardown;
        # looking it up only in the replacement Page's registry loses the body.
        with runtime.new_page() as page:
            page.navigate(
                args.base_url + "performance_resource_timing_fixture.html",
                timeout_ms=30_000,
            )
            blob_url = page.evaluate(
                """URL.createObjectURL(new Blob([
                    '<!doctype html><title>root blob</title>' +
                    '<body data-root-blob="pass">root-blob-pass</body>'
                ], {type: 'text/html'}))"""
            )
            assert blob_url.startswith("blob:"), blob_url
            page.navigate(blob_url, timeout_ms=30_000)
            root_blob = json.loads(
                page.evaluate(
                    """({
                        href: location.href,
                        status: document.body?.dataset.rootBlob,
                        text: document.body?.textContent
                    })"""
                )
            )
            assert root_blob["href"] == blob_url, root_blob
            assert root_blob["status"] == "pass", root_blob
            assert root_blob["text"] == "root-blob-pass", root_blob
            print("PASS root blob: navigation lifetime")

    print("darkpanda native HTML regressions: PASS")


if __name__ == "__main__":
    main()
