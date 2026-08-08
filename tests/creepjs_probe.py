"""Probe the official CreepJS page in Chrome and DarkPanda, then compare."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import time
from typing import Any, Callable


CREEPJS_URL = "https://abrahamjuliot.github.io/creepjs/"
MINIMUM_SECTIONS = {
    "canvas2d",
    "capturedErrors",
    "clientRects",
    "consoleErrors",
    "css",
    "cssMedia",
    "features",
    "headless",
    "htmlElementVersion",
    "intl",
    "lies",
    "maths",
    "navigator",
    "screen",
    "svg",
    "timezone",
    "windowFeatures",
    "workerScope",
}
ENGINE_HASH_SECTIONS = (
    "consoleErrors",
    "features",
    "htmlElementVersion",
    "maths",
    "windowFeatures",
)


SNAPSHOT_EXPRESSION = r"""
(() => {
  const fp = globalThis.Fingerprint;
  const stable = globalThis.Creep;
  if (!fp || !stable) {
    return JSON.stringify({
      schema: 'darkpanda-creepjs-probe/v1',
      ready: false,
      href: location.href,
      title: document.title,
      bodyText: String(document.body && document.body.innerText || '').slice(0, 500),
      fingerprintType: typeof fp,
      stableType: typeof stable,
    });
  }
  const trueKeys = value => Object.entries(value || {})
    .filter(([, enabled]) => enabled === true)
    .map(([key]) => key)
    .sort();
  const sections = Object.keys(fp).sort();
  const stableSections = Object.keys(stable).sort();
  const liedSections = sections.filter(key => fp[key] && fp[key].lied).sort();
  const liedFlags = Object.fromEntries(sections.map(key => [
    key,
    Object.fromEntries(Object.entries(fp[key] || {}).filter(
      ([name, value]) => /lie/i.test(name) && typeof value == 'boolean' && value
    )),
  ]).filter(([, flags]) => Object.keys(flags).length));
  const hashes = Object.fromEntries(sections.map(key => [key, fp[key]?.$hash || null]));
  const headless = fp.headless || {};
  return JSON.stringify({
    schema: 'darkpanda-creepjs-probe/v1',
    ready: true,
    href: location.href,
    title: document.title,
    sections,
    stableSections,
    liedSections,
    liedFlags,
    liesTotal: Number(fp.lies?.totalLies || 0),
    liesData: fp.lies?.data || {},
    headless: {
      chromium: headless.chromium,
      likeHeadlessRating: headless.likeHeadlessRating,
      headlessRating: headless.headlessRating,
      stealthRating: headless.stealthRating,
      likeHeadless: trueKeys(headless.likeHeadless),
      headless: trueKeys(headless.headless),
      stealth: trueKeys(headless.stealth),
    },
    navigator: {
      userAgent: fp.navigator?.userAgent,
      appVersion: fp.navigator?.appVersion,
      platform: fp.navigator?.platform,
      vendor: fp.navigator?.vendor,
      system: fp.navigator?.system,
      device: fp.navigator?.device,
      webdriver: fp.navigator?.webdriver,
    },
    features: {
      version: fp.features?.version,
      versionRange: fp.features?.versionRange,
      cssVersion: fp.features?.cssVersion,
      windowVersion: fp.features?.windowVersion,
      jsVersion: fp.features?.jsVersion,
      cssFeatures: fp.features?.cssFeatures,
      windowFeatures: fp.features?.windowFeatures,
      jsFeatures: fp.features?.jsFeatures,
    },
    capturedErrors: fp.capturedErrors,
    hashes,
  });
})()
"""


def wait_for_probe(evaluate: Callable[[str], str], timeout: float) -> dict[str, Any]:
    """Wait for CreepJS globals and preserve a timeout snapshot."""

    deadline = time.monotonic() + timeout
    snapshot: dict[str, Any] = {}
    while time.monotonic() < deadline:
        snapshot = json.loads(evaluate(SNAPSHOT_EXPRESSION))
        if snapshot.get("ready") is True:
            return snapshot
        time.sleep(0.1)
    return snapshot


def chrome_probe(endpoint: str, timeout: float) -> dict[str, Any]:
    """Probe CreepJS through an existing official Chrome CDP endpoint."""

    try:
        import websocket
    except ImportError as error:
        raise RuntimeError("websocket-client is required for Chrome") from error
    from chrome_stable_tls_capture import CDP, open_json

    version = open_json(endpoint.rstrip("/") + "/json/version")
    socket = websocket.create_connection(
        version["webSocketDebuggerUrl"],
        timeout=30,
        suppress_origin=True,
        http_no_proxy=["127.0.0.1", "localhost"],
    )
    cdp = CDP(socket)
    target_id: str | None = None
    try:
        target_id = cdp.call("Target.createTarget", {"url": CREEPJS_URL})[
            "targetId"
        ]
        session_id = cdp.call(
            "Target.attachToTarget",
            {"targetId": target_id, "flatten": True},
        )["sessionId"]
        cdp.call("Runtime.enable", session_id=session_id)
        cdp.call("Page.enable", session_id=session_id)

        def evaluate(expression: str) -> str:
            result = cdp.call(
                "Runtime.evaluate",
                {"expression": expression, "returnByValue": True},
                session_id,
            )
            if "exceptionDetails" in result:
                raise RuntimeError(str(result["exceptionDetails"]))
            return str(result["result"]["value"])

        report = wait_for_probe(evaluate, timeout)
        report["browser"] = version.get("Browser")
        return report
    finally:
        if target_id is not None:
            cdp.call("Target.closeTarget", {"targetId": target_id})
        socket.close()


def darkpanda_probe(library: str, wreq: str, timeout: float) -> dict[str, Any]:
    """Probe CreepJS through DarkPanda's in-process API."""

    from darkpanda import ClientProfile, Runtime

    with Runtime(
        library_path=library,
        wreq_library_path=wreq,
        navigation_timeout_ms=int(timeout * 1000),
        locale="en-US",
        timezone="UTC",
        profile=ClientProfile.CHROME149,
    ) as runtime:
        with runtime.new_page() as page:
            page.navigate(CREEPJS_URL, timeout_ms=int(timeout * 1000))
            return wait_for_probe(
                lambda expression: str(page.evaluate(expression)), timeout
            )


def compare_reports(chrome: dict[str, Any], darkpanda: dict[str, Any]) -> None:
    """Require CreepJS coverage and bot-signal parity with Stable Chrome."""

    assert chrome.get("ready") is True, chrome
    assert darkpanda.get("ready") is True, darkpanda
    chrome_sections = set(chrome.get("sections") or [])
    darkpanda_sections = set(darkpanda.get("sections") or [])
    assert MINIMUM_SECTIONS <= chrome_sections, chrome
    assert chrome_sections == darkpanda_sections, {
        "missing": sorted(chrome_sections - darkpanda_sections),
        "extra": sorted(darkpanda_sections - chrome_sections),
    }
    assert chrome.get("stableSections") == darkpanda.get("stableSections"), {
        "chrome": chrome.get("stableSections"),
        "darkpanda": darkpanda.get("stableSections"),
    }
    assert darkpanda.get("liesTotal") == chrome.get("liesTotal") == 0, {
        "chrome": chrome.get("liesTotal"),
        "darkpanda": darkpanda.get("liesTotal"),
    }
    assert darkpanda.get("liedSections") == chrome.get("liedSections") == [], {
        "chrome": chrome.get("liedSections"),
        "darkpanda": darkpanda.get("liedSections"),
    }
    for rating in ("headlessRating", "stealthRating"):
        assert darkpanda["headless"][rating] == chrome["headless"][rating] == 0, {
            "rating": rating,
            "chrome": chrome["headless"],
            "darkpanda": darkpanda["headless"],
        }
    for signal in ("likeHeadless", "headless", "stealth"):
        assert set(darkpanda["headless"][signal]) <= set(
            chrome["headless"][signal]
        ), {
            "signal": signal,
            "chrome": chrome["headless"][signal],
            "darkpanda": darkpanda["headless"][signal],
        }
    for section in ENGINE_HASH_SECTIONS:
        assert darkpanda["hashes"][section] == chrome["hashes"][section], {
            "section": section,
            "chrome": chrome["hashes"][section],
            "darkpanda": darkpanda["hashes"][section],
        }


def main() -> None:
    """Run one probe or compare two saved reports."""

    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    chrome = subparsers.add_parser("chrome")
    chrome.add_argument("--endpoint", required=True)
    chrome.add_argument("--out", required=True, type=Path)
    chrome.add_argument("--timeout", type=float, default=120)
    darkpanda = subparsers.add_parser("darkpanda")
    darkpanda.add_argument("--library", required=True)
    darkpanda.add_argument("--wreq", required=True)
    darkpanda.add_argument("--out", required=True, type=Path)
    darkpanda.add_argument("--timeout", type=float, default=120)
    compare = subparsers.add_parser("compare")
    compare.add_argument("--chrome", required=True, type=Path)
    compare.add_argument("--darkpanda", required=True, type=Path)
    args = parser.parse_args()

    if args.command == "chrome":
        report = chrome_probe(args.endpoint, args.timeout)
    elif args.command == "darkpanda":
        report = darkpanda_probe(args.library, args.wreq, args.timeout)
    else:
        chrome_report = json.loads(args.chrome.read_text(encoding="utf-8"))
        darkpanda_report = json.loads(args.darkpanda.read_text(encoding="utf-8"))
        compare_reports(chrome_report, darkpanda_report)
        print("CreepJS Google Chrome Stable/DarkPanda parity: PASS")
        return
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, separators=(",", ":")))


if __name__ == "__main__":
    main()
