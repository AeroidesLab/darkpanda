"""Capture tls.peet.ws with an installed Google Chrome Stable browser.

The browser must already be running with a DevTools endpoint.  This script
does not override User-Agent or client hints.  It rejects Chrome for Testing,
Chromium, headless products, version drift, and unverifiable Stable installs.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time
from typing import Any
import urllib.request

from tls_fingerprint_compare import PRE_SHARED_KEY_EXTENSION, extension_type


PEET_URL = "https://tls.peet.ws/api/all"
MACOS_GOOGLE_IDENTIFIER = "com.google.Chrome"
MACOS_GOOGLE_TEAM = "EQHXZ8M8AV"


class CDP:
    """Minimal synchronous CDP client for one oracle target."""

    def __init__(self, socket: Any) -> None:
        self.socket = socket
        self.next_id = 0

    def call(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        session_id: str | None = None,
    ) -> dict[str, Any]:
        """Call one CDP method, ignoring unrelated events."""

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


def sha256(path: Path) -> str:
    """Hash a file without loading it all into memory."""

    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command_output(command: list[str]) -> str:
    """Run a provenance command and return stripped stdout."""

    result = subprocess.run(
        command,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout.strip()


def google_chrome_version(output: str) -> str:
    """Accept only the Stable product name emitted by Google Chrome."""

    match = re.fullmatch(r"Google Chrome ([0-9]+(?:\.[0-9]+){3})\s*", output)
    if match is None:
        raise AssertionError(
            "expected Google Chrome Stable; Chrome for Testing, Chromium, "
            f"and other channels are forbidden: {output!r}"
        )
    return match.group(1)


def windows_version_info(binary: Path) -> dict[str, str]:
    """Read Windows product metadata without launching the GUI executable."""

    environment = dict(os.environ, DARKPANDA_CHROME_BINARY=str(binary))
    script = (
        "$v=(Get-Item -LiteralPath $env:DARKPANDA_CHROME_BINARY).VersionInfo;"
        "@{ProductName=$v.ProductName;ProductVersion=$v.ProductVersion;"
        "FileDescription=$v.FileDescription}|ConvertTo-Json -Compress"
    )
    result = subprocess.run(
        ["powershell", "-NoProfile", "-Command", script],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    evidence = json.loads(result.stdout)
    assert evidence.get("ProductName") == "Google Chrome", evidence
    assert evidence.get("FileDescription") == "Google Chrome", evidence
    version = str(evidence.get("ProductVersion") or "")
    assert re.fullmatch(r"[0-9]+(?:\.[0-9]+){3}", version), evidence
    return {key: str(value) for key, value in evidence.items()}


def parse_codesign(output: str) -> dict[str, str]:
    """Require Google's production macOS application signature."""

    fields = dict(
        line.split("=", 1)
        for line in output.splitlines()
        if "=" in line
    )
    assert fields.get("Identifier") == MACOS_GOOGLE_IDENTIFIER, fields
    assert fields.get("TeamIdentifier") == MACOS_GOOGLE_TEAM, fields
    return {
        "identifier": fields["Identifier"],
        "teamIdentifier": fields["TeamIdentifier"],
    }


def platform_provenance(binary: Path) -> dict[str, Any]:
    """Verify the Stable installation with the host package/signing system."""

    if sys.platform == "darwin":
        result = subprocess.run(
            ["codesign", "-dv", "--verbose=4", str(binary)],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return {"kind": "codesign", **parse_codesign(result.stderr)}

    if os.name == "nt":
        environment = dict(os.environ, DARKPANDA_CHROME_BINARY=str(binary))
        script = (
            "$s=Get-AuthenticodeSignature -LiteralPath "
            "$env:DARKPANDA_CHROME_BINARY;"
            "@{Status=[string]$s.Status;Subject=$s.SignerCertificate.Subject}"
            "|ConvertTo-Json -Compress"
        )
        result = subprocess.run(
            ["powershell", "-NoProfile", "-Command", script],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
        )
        evidence = json.loads(result.stdout)
        assert evidence.get("Status") == "Valid", evidence
        assert "Google LLC" in str(evidence.get("Subject")), evidence
        return {"kind": "authenticode", **evidence}

    for package_tool, command in (
        (
            "dpkg",
            [
                "dpkg-query",
                "-W",
                "-f=${Status} ${Version}",
                "google-chrome-stable",
            ],
        ),
        ("rpm", ["rpm", "-q", "google-chrome-stable"]),
    ):
        try:
            package = command_output(command)
        except (FileNotFoundError, subprocess.CalledProcessError):
            continue
        return {"kind": package_tool, "package": package}
    raise AssertionError("Google Chrome Stable package provenance is unavailable")


def binary_evidence(binary: Path) -> dict[str, Any]:
    """Return verified executable provenance."""

    resolved = binary.expanduser().resolve(strict=True)
    if os.name == "nt":
        version_info = windows_version_info(resolved)
        version = version_info["ProductVersion"]
    else:
        version_info = None
        version = google_chrome_version(command_output([str(resolved), "--version"]))
    return {
        "product": "Google Chrome Stable",
        "version": version,
        "path": str(resolved),
        "sha256": sha256(resolved),
        "versionInfo": version_info,
        "provenance": platform_provenance(resolved),
    }


def open_json(url: str) -> dict[str, Any]:
    """Read local DevTools metadata without environment proxies."""

    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(url, timeout=10) as response:
        return json.load(response)


def capture_peet(endpoint: str) -> tuple[dict[str, Any], dict[str, Any]]:
    """Navigate one fresh target and return DevTools and peet evidence."""

    try:
        import websocket
    except ImportError as error:
        raise RuntimeError(
            "websocket-client is required for the Stable oracle"
        ) from error

    version = open_json(endpoint.rstrip("/") + "/json/version")
    browser = str(version.get("Browser") or "")
    if browser.startswith("HeadlessChrome/"):
        raise AssertionError(f"headless Chrome is forbidden: {browser}")
    if not browser.startswith("Chrome/"):
        raise AssertionError(f"unexpected DevTools product: {browser!r}")

    socket = websocket.create_connection(
        version["webSocketDebuggerUrl"],
        timeout=30,
        suppress_origin=True,
        http_no_proxy=["127.0.0.1", "localhost"],
    )
    cdp = CDP(socket)
    target_id: str | None = None
    try:
        target_id = cdp.call("Target.createTarget", {"url": "about:blank"})[
            "targetId"
        ]
        session_id = cdp.call(
            "Target.attachToTarget",
            {"targetId": target_id, "flatten": True},
        )["sessionId"]
        cdp.call("Runtime.enable", session_id=session_id)
        cdp.call("Page.enable", session_id=session_id)
        cdp.call("Page.navigate", {"url": PEET_URL}, session_id)

        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            evaluated = cdp.call(
                "Runtime.evaluate",
                {
                    "expression": (
                        "document.readyState === 'complete' && "
                        "document.body && document.body.textContent"
                    ),
                    "returnByValue": True,
                },
                session_id,
            )
            body = evaluated.get("result", {}).get("value")
            if isinstance(body, str) and body.lstrip().startswith("{"):
                peet = json.loads(body)
                user_agent = cdp.call(
                    "Runtime.evaluate",
                    {"expression": "navigator.userAgent", "returnByValue": True},
                    session_id,
                )["result"]["value"]
                assert peet.get("user_agent") == user_agent, {
                    "peet": peet.get("user_agent"),
                    "navigator": user_agent,
                }
                return version, peet
            time.sleep(0.05)
        raise TimeoutError("Google Chrome Stable peet capture timed out")
    finally:
        if target_id is not None:
            cdp.call("Target.closeTarget", {"targetId": target_id})
    socket.close()


def flush_socket_pools(endpoint: str) -> None:
    """Force the next Stable request onto a new socket without losing tickets."""

    try:
        import websocket
    except ImportError as error:
        raise RuntimeError(
            "websocket-client is required for the Stable oracle"
        ) from error

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
        target_id = cdp.call(
            "Target.createTarget", {"url": "chrome://net-internals/#sockets"}
        )["targetId"]
        session_id = cdp.call(
            "Target.attachToTarget",
            {"targetId": target_id, "flatten": True},
        )["sessionId"]
        cdp.call("Runtime.enable", session_id=session_id)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            evaluated = cdp.call(
                "Runtime.evaluate",
                {
                    "expression": (
                        "(() => { const button = document.querySelector("
                        "'#sockets-view-flush-button'); if (!button) return false; "
                        "button.click(); return true; })()"
                    ),
                    "returnByValue": True,
                },
                session_id,
            )
            if evaluated.get("result", {}).get("value") is True:
                return
            time.sleep(0.05)
        raise TimeoutError("Google Chrome Stable socket-pool flush timed out")
    finally:
        if target_id is not None:
            cdp.call("Target.closeTarget", {"targetId": target_id})
        socket.close()


def validate_phase(peet: dict[str, Any], phase: str) -> None:
    """Prove that a labeled capture is actually cold or resumed."""

    extension_types = [
        extension_type(extension)
        for extension in (peet.get("tls") or {}).get("extensions") or []
    ]
    resumed = PRE_SHARED_KEY_EXTENSION in extension_types
    assert resumed is (phase == "resumed"), {
        "phase": phase,
        "preSharedKey": resumed,
        "extensionTypes": extension_types,
    }


def main() -> None:
    """Capture and write one provenance-bound oracle observation."""

    parser = argparse.ArgumentParser()
    parser.add_argument("--chrome-binary", required=True, type=Path)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--phase", required=True, choices=("cold", "resumed"))
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    binary = binary_evidence(args.chrome_binary)
    if args.phase == "resumed":
        flush_socket_pools(args.endpoint)
    devtools, peet = capture_peet(args.endpoint)
    devtools_version = str(devtools["Browser"]).removeprefix("Chrome/")
    assert devtools_version == binary["version"], {
        "binary": binary["version"],
        "devtools": devtools_version,
    }
    validate_phase(peet, args.phase)

    evidence = {
        "schema": "darkpanda-google-chrome-stable-capture/v1",
        "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "phase": args.phase,
        "host": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
        },
        "browser": binary,
        "devtools": {
            "browser": devtools["Browser"],
            "protocolVersion": devtools.get("Protocol-Version"),
            "v8Version": devtools.get("V8-Version"),
            "webKitVersion": devtools.get("WebKit-Version"),
        },
        "automation": {
            "transport": "CDP",
            "headless": False,
            "userAgentOverride": False,
        },
        "responseBodyJson": peet,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    print(json.dumps(evidence["browser"], separators=(",", ":")))
    print(f"Google Chrome Stable {args.phase} capture: PASS")


if __name__ == "__main__":
    main()
