"""Compact TLS/HTTP2 fingerprint evidence via native Python ABI and wreq."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

from darkpanda import ClientProfile, Runtime


TRUST_ANCHORS_EXTENSION = 0xCA34


def extension_type(extension: dict[str, object]) -> int | None:
    """Return the numeric TLS extension type reported by tls.peet.ws."""

    name = str(extension.get("name") or "")
    match = re.search(r"\((?:0x([0-9a-fA-F]+)|([0-9]+))\)\s*$", name)
    if match is None:
        unknown = re.fullmatch(r"Unknown extension ([0-9]+)", name)
        return int(unknown.group(1), 10) if unknown is not None else None
    if match.group(1) is not None:
        return int(match.group(1), 16)
    return int(match.group(2), 10)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq", required=True)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    with Runtime(
        library_path=args.library,
        wreq_transport_path=args.wreq,
        navigation_timeout_ms=30_000,
        locale="en-US",
        timezone="UTC",
        profile=ClientProfile.CHROME149,
    ) as runtime:
        with runtime.new_page() as page:
            page.navigate("https://tls.peet.ws/api/all", timeout_ms=30_000)
            data = json.loads(page.evaluate("document.body.textContent"))

    if args.out is not None:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(data, indent=2), encoding="utf-8")

    tls = data.get("tls") or {}
    http2 = data.get("http2") or {}
    extensions = {
        extension_type(extension): extension
        for extension in tls.get("extensions") or []
        if extension_type(extension) is not None
    }
    trust_anchors = extensions.get(TRUST_ANCHORS_EXTENSION)
    evidence = {
        "httpVersion": data.get("http_version"),
        "userAgent": data.get("user_agent"),
        "ja3Hash": tls.get("ja3_hash"),
        "ja4": tls.get("ja4"),
        "akamaiFingerprintHash": http2.get("akamai_fingerprint_hash"),
        "trustAnchorsExtension": trust_anchors,
        "headers": data.get("headers"),
    }
    assert evidence["httpVersion"] == "h2", evidence
    assert "Chrome/149.0.0.0" in str(evidence["userAgent"]), evidence
    assert str(evidence["ja4"]).startswith("t13"), evidence
    assert evidence["ja3Hash"], evidence
    assert evidence["akamaiFingerprintHash"], evidence
    assert trust_anchors is not None, (
        "Chrome149 Windows requires trust_anchors (0xca34/51764); "
        f"observed JA4={evidence['ja4']} extensions={sorted(extensions)}"
    )
    assert str(trust_anchors.get("data") or "").lower() == "0000", trust_anchors
    assert str(evidence["ja4"]).startswith("t13d1517h2_"), evidence
    print(json.dumps(evidence, separators=(",", ":")))
    print("darkpanda native wreq TLS/HTTP2: PASS")


if __name__ == "__main__":
    main()
