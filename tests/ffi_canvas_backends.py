"""Exercise the selectable Canvas backends through real HTML/V8 calls."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from darkpanda import CanvasDriver, ClientProfile, Runtime


def wait_for_harness(page: object, timeout_ms: int = 15_000) -> None:
    result = page.evaluate(
        f"""new Promise((resolve, reject) => {{
            const deadline = Date.now() + {timeout_ms};
            const poll = () => {{
                try {{
                    if (testing.assertOk()) return resolve(true);
                    if (Date.now() >= deadline) {{
                        testing.printTimeoutState();
                        return reject(new Error('Canvas backend regression timeout'));
                    }}
                    setTimeout(poll, 5);
                }} catch (error) {{ reject(error); }}
            }};
            poll();
        }})""",
        promise_timeout_ms=timeout_ms + 5_000,
    )
    assert result == "true", result


PROFILE_SEED = "0102030405060708"
CANVAS_SEED = "1112131415161718"


def capture_sequence(page: object) -> list[list[int]]:
    value = page.evaluate(
        """JSON.stringify((() => {
            const read = () => {
                const canvas = document.createElement('canvas');
                canvas.width = 2;
                canvas.height = 1;
                return Array.from(canvas.getContext('2d').getImageData(0, 0, 2, 1).data);
            };
            return [read(), read()];
        })())"""
    )
    return json.loads(value)


def run_backend(args: argparse.Namespace) -> None:
    profile = json.loads(Path(args.profile_json).read_text(encoding="utf-8"))
    profile["graphics"]["canvasBackend"] = args.backend
    profile["graphics"]["profileSeed"] = PROFILE_SEED
    profile["graphics"]["canvasSeed"] = CANVAS_SEED

    environment = {
        # Deprecated identity variables are deliberately contradictory and
        # invalid. Provider must ignore them; only the resolved profile above
        # may choose observable kind/seeds.
        "DARKPANDA_CANVAS_BACKEND": "fake" if args.backend == "skia" else "skia",
        "DARKPANDA_CANVAS_PROFILE_SEED": "not-a-seed",
        "DARKPANDA_CANVAS_SEED": "also-not-a-seed",
    }
    old_values = {name: os.environ.get(name) for name in environment}
    os.environ.update(environment)
    try:
        with Runtime(
            library_path=args.library,
            wreq_transport_path=args.wreq,
            canvas_library_path=args.canvas_library,
            canvas_driver=CanvasDriver.DYNAMIC,
            navigation_timeout_ms=30_000,
            profile=ClientProfile.CHROME149,
            fingerprint_profile_json=profile,
        ) as runtime:
            manifest = runtime.identity_manifest()
            canvas_manifest = manifest["canvas"]
            assert canvas_manifest["configuredBackend"] == args.backend, canvas_manifest
            assert canvas_manifest["configuredProfileSeed"] == PROFILE_SEED, canvas_manifest
            assert canvas_manifest["configuredCanvasSeed"] == CANVAS_SEED, canvas_manifest
            assert canvas_manifest["actualDriverQueried"] is False, canvas_manifest
            assert canvas_manifest["runtimeBackendAttested"] is False, canvas_manifest
            assert canvas_manifest["gpuAttested"] is False, canvas_manifest
            assert "Chromium M149 Skia CPU backend through ABI v5" in canvas_manifest[
                "implementationBoundary"
            ], canvas_manifest

            captures: list[list[list[int]]] = []
            for _ in range(2):
                with runtime.new_page() as page:
                    fixture = f"canvas_backend_{args.backend}.html"
                    page.navigate(
                        f"{args.base_url}{fixture}?__darkpanda_test_runner=1",
                        timeout_ms=30_000,
                    )
                    wait_for_harness(page)
                    captures.append(capture_sequence(page))

            assert captures[0] == captures[1], captures
            first, second = captures[0]
            if args.backend == "fake":
                assert any(first), first
                assert first != second, captures[0]
            else:
                assert first == [0] * 8, first
                assert second == [0] * 8, second
            print(f"PASS profile-driven {args.backend} Canvas backend ({fixture})")
    finally:
        for name, old_value in old_values.items():
            if old_value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = old_value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq", required=True)
    parser.add_argument("--canvas-library", required=True)
    parser.add_argument("--backend", choices=("skia", "fake"))
    parser.add_argument(
        "--profile-json",
        default=str(Path(__file__).with_name("fixtures") / "chrome149_profile_fr.json"),
    )
    parser.add_argument(
        "--base-url",
        default="http://127.0.0.1:9583/src/browser/tests/canvas/",
    )
    args = parser.parse_args()

    if args.backend is not None:
        run_backend(args)
        return

    # V8/App are intentionally immutable and process-global. Exercise the two
    # different observable profiles in fresh child processes; each child still
    # uses only the direct Python ABI for browser operations.
    for backend in ("skia", "fake"):
        command = [
            sys.executable,
            str(Path(__file__).resolve()),
            "--library",
            args.library,
            "--wreq",
            args.wreq,
            "--canvas-library",
            args.canvas_library,
            "--backend",
            backend,
            "--profile-json",
            args.profile_json,
            "--base-url",
            args.base_url,
        ]
        subprocess.run(command, check=True)


if __name__ == "__main__":
    main()
