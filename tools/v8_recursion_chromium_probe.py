"""Differential V8 recursion/tiering probe for exact Chrome and DarkPanda.

The recursive code is parser-inserted by the fixture.  Chrome gets a fresh
BrowserContext and Target; DarkPanda uses only the direct native Python ABI.
No result is normalized or patched to resemble Chrome.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

import websocket

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "python"))

from darkpanda import ABI_VERSION, ClientProfile, Runtime

EXPECTED_SOURCE_REVISION = "v8-recursion-shapes-2026-07-15-1"


class CDP:
    def __init__(self, socket: websocket.WebSocket) -> None:
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


def _with_rounds(url: str, rounds: int) -> str:
    split = urllib.parse.urlsplit(url)
    query = dict(urllib.parse.parse_qsl(split.query, keep_blank_values=True))
    query["rounds"] = str(rounds)
    return urllib.parse.urlunsplit(
        (split.scheme, split.netloc, split.path, urllib.parse.urlencode(query), split.fragment)
    )


def _process_snapshot(cdp: CDP) -> dict[int, dict[str, Any]]:
    result: dict[int, dict[str, Any]] = {}
    for process in cdp.call("SystemInfo.getProcessInfo").get("processInfo", []):
        try:
            process_id = int(process["id"])
        except (KeyError, TypeError, ValueError):
            continue
        result[process_id] = process
    return result


def _windows_process_info(process_id: int) -> dict[str, Any] | None:
    if os.name != "nt" or process_id <= 0:
        return None
    script = (
        f"$p=Get-CimInstance Win32_Process -Filter \"ProcessId={process_id}\";"
        "if($null -ne $p){$p|Select-Object ProcessId,ParentProcessId,"
        "ExecutablePath,CommandLine|ConvertTo-Json -Compress}"
    )
    try:
        completed = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    payload = completed.stdout.strip()
    if completed.returncode != 0 or not payload:
        return None
    try:
        parsed = json.loads(payload)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _map_target_renderer(
    cdp: CDP,
    session_id: str,
    before_target: dict[int, dict[str, Any]],
    burn_ms: int,
) -> dict[str, Any]:
    before_burn = _process_snapshot(cdp)
    expression = f"""(() => {{
      const deadline = performance.now() + {burn_ms};
      let value = 1;
      while (performance.now() < deadline) {{
        value = Math.imul(value + 1013904223, 1664525);
      }}
      return value;
    }})()"""
    cdp.call(
        "Runtime.evaluate",
        {"expression": expression, "returnByValue": True},
        session_id,
    )
    after_burn = _process_snapshot(cdp)

    candidates: list[dict[str, Any]] = []
    for process_id, current in after_burn.items():
        if current.get("type") != "renderer":
            continue
        previous_cpu = float(before_burn.get(process_id, {}).get("cpuTime", 0.0))
        current_cpu = float(current.get("cpuTime", 0.0))
        candidates.append(
            {
                "processId": process_id,
                "cpuDeltaSeconds": max(0.0, current_cpu - previous_cpu),
                "isNewSinceTargetCreation": process_id not in before_target,
            }
        )
    candidates.sort(key=lambda item: item["cpuDeltaSeconds"], reverse=True)

    selected = candidates[0] if candidates else None
    top_delta = float(selected["cpuDeltaSeconds"]) if selected else 0.0
    second_delta = float(candidates[1]["cpuDeltaSeconds"]) if len(candidates) > 1 else 0.0
    confidence = "low"
    if selected and top_delta >= max(0.05, burn_ms / 1000 * 0.35):
        confidence = "high" if second_delta < top_delta * 0.5 else "medium"

    inspected: list[dict[str, Any]] = []
    for candidate in candidates[:3]:
        process_info = _windows_process_info(int(candidate["processId"]))
        inspected.append({**candidate, "windowsProcess": process_info})

    return {
        "method": "post-probe target CPU burn",
        "burnMs": burn_ms,
        "confidence": confidence,
        "selectedProcessId": selected["processId"] if selected else None,
        "selectedCpuDeltaSeconds": top_delta if selected else None,
        "newRendererProcessIds": sorted(
            process_id
            for process_id, process in after_burn.items()
            if process.get("type") == "renderer" and process_id not in before_target
        ),
        "candidates": inspected,
    }


def _poll_for_fixture(cdp: CDP, session_id: str, timeout_seconds: float) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        evaluated = cdp.call(
            "Runtime.evaluate",
            {
                "expression": "typeof window.__v8RecursionProbe !== 'undefined'",
                "returnByValue": True,
            },
            session_id,
        )
        if evaluated.get("result", {}).get("value") is True:
            return
        time.sleep(0.05)
    raise TimeoutError("Chrome recursion fixture was not installed")


def _pollution_warnings(
    browser_arguments: list[str] | None,
    renderer_mapping: dict[str, Any],
) -> list[str]:
    warnings: list[str] = []
    for argument in browser_arguments or []:
        if argument.startswith("--js-flags"):
            warnings.append(f"Chrome browser command line contains {argument!r}")

    if renderer_mapping.get("confidence") != "high":
        warnings.append(
            "Chrome target-to-renderer PID mapping is not high confidence; "
            "renderer-specific flags may be attributed incorrectly"
        )
    selected_pid = renderer_mapping.get("selectedProcessId")
    for candidate in renderer_mapping.get("candidates", []):
        if candidate.get("processId") != selected_pid:
            continue
        command_line = (candidate.get("windowsProcess") or {}).get("CommandLine") or ""
        if "--js-flags" in command_line:
            warnings.append(
                "Mapped Chrome target renderer contains --js-flags: " + command_line
            )
        if "--disable-optimizing-compilers" in command_line:
            warnings.append(
                "Mapped Chrome target renderer disables optimizing compilers; "
                "this sample is not a normal Chrome tiering baseline"
            )
    return warnings


def chrome_probe(
    endpoint: str,
    url: str,
    burn_ms: int,
    timeout_seconds: float,
) -> tuple[dict[str, Any], dict[str, Any], list[str]]:
    endpoint_version = _open_json(endpoint.rstrip("/") + "/json/version")
    os.environ["NO_PROXY"] = "127.0.0.1,localhost"
    os.environ["no_proxy"] = "127.0.0.1,localhost"
    socket = websocket.create_connection(
        endpoint_version["webSocketDebuggerUrl"],
        timeout=max(30, timeout_seconds),
        suppress_origin=True,
        http_no_proxy=["127.0.0.1", "localhost"],
    )
    cdp = CDP(socket)
    browser_context_id: str | None = None
    target_id: str | None = None
    try:
        browser_version = cdp.call("Browser.getVersion")
        try:
            browser_arguments = cdp.call("Browser.getBrowserCommandLine").get("arguments", [])
        except RuntimeError:
            browser_arguments = None

        before_target = _process_snapshot(cdp)
        browser_context_id = cdp.call("Target.createBrowserContext")["browserContextId"]
        target_id = cdp.call(
            "Target.createTarget",
            {
                "url": "about:blank",
                "browserContextId": browser_context_id,
                "background": False,
            },
        )["targetId"]
        session_id = cdp.call(
            "Target.attachToTarget",
            {"targetId": target_id, "flatten": True},
        )["sessionId"]
        cdp.call("Runtime.enable", session_id=session_id)
        cdp.call("Page.enable", session_id=session_id)
        cdp.call("Network.enable", session_id=session_id)
        cdp.call(
            "Network.setCacheDisabled",
            {"cacheDisabled": True},
            session_id,
        )
        navigation = cdp.call("Page.navigate", {"url": url}, session_id)
        if navigation.get("errorText"):
            raise RuntimeError(f"Chrome navigation failed: {navigation['errorText']}")

        _poll_for_fixture(cdp, session_id, timeout_seconds)
        evaluated = cdp.call(
            "Runtime.evaluate",
            {
                "expression": "window.__v8RecursionProbe",
                "awaitPromise": True,
                "returnByValue": True,
            },
            session_id,
        )
        if "exceptionDetails" in evaluated:
            raise RuntimeError(f"Chrome fixture failed: {evaluated['exceptionDetails']}")
        probe = evaluated.get("result", {}).get("value")
        if not isinstance(probe, dict):
            raise RuntimeError(f"Chrome fixture returned invalid value: {probe!r}")

        renderer_mapping = _map_target_renderer(
            cdp, session_id, before_target, burn_ms
        )
        metadata = {
            "endpoint": endpoint,
            "endpointVersion": endpoint_version,
            "browserGetVersion": browser_version,
            "browserCommandLine": browser_arguments,
            "browserContextId": browser_context_id,
            "targetId": target_id,
            "networkCacheDisabled": True,
            "rendererMapping": renderer_mapping,
        }
        return metadata, probe, _pollution_warnings(browser_arguments, renderer_mapping)
    finally:
        if target_id is not None:
            try:
                cdp.call("Target.closeTarget", {"targetId": target_id})
            except RuntimeError:
                pass
        if browser_context_id is not None:
            try:
                cdp.call(
                    "Target.disposeBrowserContext",
                    {"browserContextId": browser_context_id},
                )
            except RuntimeError:
                pass
        socket.close()


def darkpanda_probe(
    library: Path,
    wreq: Path,
    url: str,
    locale: str,
    timezone: str | None,
    timeout_ms: int,
) -> tuple[dict[str, Any], dict[str, Any]]:
    with Runtime(
        library_path=library,
        wreq_library_path=wreq,
        locale=locale,
        timezone=timezone,
        profile=ClientProfile.CHROME149,
    ) as runtime:
        with runtime.new_page() as page:
            page.navigate(url, timeout_ms=timeout_ms)
            probe = json.loads(
                page.evaluate(
                    "window.__v8RecursionProbe",
                    promise_timeout_ms=timeout_ms,
                )
            )
    return {
        "transport": "direct native Python ABI",
        "abiVersion": ABI_VERSION,
        "library": str(library.resolve()),
        "wreqTransport": str(wreq.resolve()),
        "locale": locale,
        "timezone": timezone,
    }, probe


def validate_probe(label: str, probe: dict[str, Any]) -> list[str]:
    warnings: list[str] = []
    if probe.get("schemaVersion") != 2:
        raise ValueError(f"{label}: unsupported fixture schema {probe.get('schemaVersion')!r}")
    if probe.get("parserReadyState") != "loading":
        warnings.append(
            f"{label}: Window probe was not captured during parser loading "
            f"({probe.get('parserReadyState')!r})"
        )
    if probe.get("workerError"):
        warnings.append(f"{label}: DedicatedWorker failed: {probe['workerError']!r}")
    for realm in ("window", "worker"):
        payload = probe.get(realm)
        if payload is None:
            continue
        if payload.get("sourceRevision") != EXPECTED_SOURCE_REVISION:
            raise ValueError(
                f"{label}: {realm} recursion source revision is "
                f"{payload.get('sourceRevision')!r}, expected "
                f"{EXPECTED_SOURCE_REVISION!r}; refusing a stale-cache comparison"
            )
        samples = payload.get("samples")
        if not isinstance(samples, list) or not samples:
            raise ValueError(f"{label}: {realm} contains no recursion samples")
        unexpected = [
            sample
            for sample in samples
            if sample.get("errorName") != "RangeError" or int(sample.get("depth", 0)) <= 0
        ]
        if unexpected:
            warnings.append(
                f"{label}: {realm} has {len(unexpected)} non-RangeError/zero-depth samples"
            )
    return warnings


def summarize(probe: dict[str, Any]) -> dict[str, Any]:
    summary: dict[str, Any] = {}
    for realm in ("window", "worker"):
        payload = probe.get(realm)
        if not isinstance(payload, dict):
            continue
        grouped: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
        for sample in payload.get("samples", []):
            grouped[str(sample.get("shape", "unknown"))].append(sample)
        realm_summary: dict[str, Any] = {}
        for shape, samples in sorted(grouped.items()):
            depths = [int(sample["depth"]) for sample in samples]
            durations = [float(sample.get("durationMs", math.nan)) for sample in samples]
            realm_summary[shape] = {
                "count": len(depths),
                "meanDepth": statistics.fmean(depths),
                "minDepth": min(depths),
                "maxDepth": max(depths),
                "populationStdevDepth": statistics.pstdev(depths),
                "meanDurationMs": statistics.fmean(durations),
                "errorNames": dict(Counter(str(sample.get("errorName", "")) for sample in samples)),
            }
        summary[realm] = realm_summary
    return summary


def compare_summaries(
    chrome: dict[str, Any], darkpanda: dict[str, Any]
) -> dict[str, Any]:
    comparison: dict[str, Any] = {}
    for realm in sorted(set(chrome) | set(darkpanda)):
        realm_comparison: dict[str, Any] = {}
        chrome_realm = chrome.get(realm, {})
        dark_realm = darkpanda.get(realm, {})
        for shape in sorted(set(chrome_realm) | set(dark_realm)):
            chrome_shape = chrome_realm.get(shape)
            dark_shape = dark_realm.get(shape)
            if not chrome_shape or not dark_shape:
                realm_comparison[shape] = {"comparable": False}
                continue
            chrome_mean = float(chrome_shape["meanDepth"])
            dark_mean = float(dark_shape["meanDepth"])
            realm_comparison[shape] = {
                "comparable": True,
                "meanDepthDelta": dark_mean - chrome_mean,
                "darkToChromeMeanRatio": dark_mean / chrome_mean if chrome_mean else None,
                "rangesOverlap": not (
                    dark_shape["maxDepth"] < chrome_shape["minDepth"]
                    or chrome_shape["maxDepth"] < dark_shape["minDepth"]
                ),
            }
        comparison[realm] = realm_comparison
    return comparison


def print_summary(report: dict[str, Any]) -> None:
    chrome_metadata = report.get("chrome", {}).get("metadata", {})
    browser_version = chrome_metadata.get("browserGetVersion", {})
    if browser_version:
        print(
            f"Chrome {browser_version.get('product', 'unknown')} / "
            f"V8 {browser_version.get('jsVersion', 'unknown')}"
        )
        mapping = chrome_metadata.get("rendererMapping", {})
        print(
            "Chrome target renderer "
            f"pid={mapping.get('selectedProcessId')} confidence={mapping.get('confidence')}"
        )

    chrome_summary = report.get("chrome", {}).get("summary")
    dark_summary = report.get("darkpanda", {}).get("summary")
    if chrome_summary and dark_summary:
        for realm in ("window", "worker"):
            for shape in sorted(set(chrome_summary.get(realm, {})) | set(dark_summary.get(realm, {}))):
                chrome_shape = chrome_summary.get(realm, {}).get(shape)
                dark_shape = dark_summary.get(realm, {}).get(shape)
                if not chrome_shape or not dark_shape:
                    print(f"MISSING {realm}/{shape}")
                    continue
                ratio = dark_shape["meanDepth"] / chrome_shape["meanDepth"]
                print(
                    f"{realm:6} {shape:14} "
                    f"Chrome {chrome_shape['meanDepth']:.1f} "
                    f"[{chrome_shape['minDepth']},{chrome_shape['maxDepth']}]  "
                    f"Dark {dark_shape['meanDepth']:.1f} "
                    f"[{dark_shape['minDepth']},{dark_shape['maxDepth']}]  "
                    f"ratio={ratio:.3f}"
                )
    elif chrome_summary:
        print(json.dumps(chrome_summary, ensure_ascii=False, indent=2))
    elif dark_summary:
        print(json.dumps(dark_summary, ensure_ascii=False, indent=2))

    for warning in report.get("warnings", []):
        print("WARNING " + warning)


def main() -> None:
    root = REPO_ROOT
    parser = argparse.ArgumentParser()
    parser.add_argument("--chrome-endpoint", default="http://127.0.0.1:9223")
    parser.add_argument(
        "--url",
        default=(
            "http://127.0.0.1:9583/src/browser/tests/window/"
            "v8_recursion_parity_fixture.html"
        ),
    )
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--burn-ms", type=int, default=350)
    parser.add_argument("--timeout-seconds", type=float, default=60.0)
    parser.add_argument("--expected-chrome-major", type=int, default=149)
    parser.add_argument("--expected-v8-prefix", default="14.9.")
    parser.add_argument("--library", type=Path, default=root / "zig-out/bin/darkpanda.dll")
    parser.add_argument("--wreq", type=Path, default=root / "zig-out/bin/wreq.dll")
    parser.add_argument("--locale", default="en-US")
    parser.add_argument("--timezone", default="UTC")
    parser.add_argument("--skip-chrome", action="store_true")
    parser.add_argument("--skip-darkpanda", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--json-only", action="store_true")
    args = parser.parse_args()

    if args.skip_chrome and args.skip_darkpanda:
        parser.error("--skip-chrome and --skip-darkpanda cannot be used together")
    if not 1 <= args.rounds <= 20:
        parser.error("--rounds must be in [1, 20]")
    if not 100 <= args.burn_ms <= 2000:
        parser.error("--burn-ms must be in [100, 2000]")

    url = _with_rounds(args.url, args.rounds)
    report: dict[str, Any] = {
        "schemaVersion": 1,
        "fixtureUrl": url,
        "warnings": [],
    }

    if not args.skip_chrome:
        metadata, probe, warnings = chrome_probe(
            args.chrome_endpoint,
            url,
            args.burn_ms,
            args.timeout_seconds,
        )
        warnings.extend(validate_probe("Chrome", probe))
        product = str(metadata.get("browserGetVersion", {}).get("product", ""))
        js_version = str(metadata.get("browserGetVersion", {}).get("jsVersion", ""))
        expected_product = f"Chrome/{args.expected_chrome_major}."
        if expected_product not in product:
            warnings.append(
                f"expected Chrome major {args.expected_chrome_major}, got {product!r}"
            )
        if args.expected_v8_prefix and not js_version.startswith(args.expected_v8_prefix):
            warnings.append(
                f"expected V8 prefix {args.expected_v8_prefix!r}, got {js_version!r}"
            )
        report["chrome"] = {
            "metadata": metadata,
            "probe": probe,
            "summary": summarize(probe),
        }
        report["warnings"].extend(warnings)

    if not args.skip_darkpanda:
        metadata, probe = darkpanda_probe(
            args.library,
            args.wreq,
            url,
            args.locale,
            args.timezone or None,
            int(args.timeout_seconds * 1000),
        )
        report["warnings"].extend(validate_probe("DarkPanda", probe))
        report["darkpanda"] = {
            "metadata": metadata,
            "probe": probe,
            "summary": summarize(probe),
        }

    if "chrome" in report and "darkpanda" in report:
        report["comparison"] = compare_summaries(
            report["chrome"]["summary"], report["darkpanda"]["summary"]
        )

    serialized = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(serialized + "\n", encoding="utf-8")
    if args.json_only:
        print(serialized)
    else:
        print_summary(report)
        if args.output:
            print(f"JSON {args.output.resolve()}")


if __name__ == "__main__":
    main()
