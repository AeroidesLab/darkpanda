"""Normalize and compare Chrome149/wreq cold and resumed peet captures.

The input files may be direct ``https://tls.peet.ws/api/all`` JSON responses
or capture wrappers containing that response as JSON/text.  GREASE values and
extension order are deliberately ignored; protocol-significant extension
types and payloads are not.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


TRUST_ANCHORS_EXTENSION = 0xCA34
PRE_SHARED_KEY_EXTENSION = 41


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--chrome-cold", required=True, type=Path)
    parser.add_argument("--chrome-resumed", required=True, type=Path)
    parser.add_argument("--wreq-cold", required=True, type=Path)
    parser.add_argument("--wreq-resumed", required=True, type=Path)
    return parser.parse_args()


def find_peet(value: Any) -> dict[str, Any] | None:
    if isinstance(value, dict):
        if isinstance(value.get("tls"), dict):
            return value
        for key in ("responseBodyJson", "response", "data", "body"):
            found = find_peet(value.get(key))
            if found is not None:
                return found
        for key in ("responseBodyText", "bodyText", "text"):
            text = value.get(key)
            if isinstance(text, str):
                try:
                    found = find_peet(json.loads(text))
                except json.JSONDecodeError:
                    continue
                if found is not None:
                    return found
        for nested in value.values():
            found = find_peet(nested)
            if found is not None:
                return found
    elif isinstance(value, list):
        for nested in value:
            found = find_peet(nested)
            if found is not None:
                return found
    return None


def load_peet(path: Path) -> dict[str, Any]:
    parsed = json.loads(path.read_text(encoding="utf-8"))
    peet = find_peet(parsed)
    if peet is None:
        raise AssertionError(f"{path}: no tls.peet.ws response found")
    return peet


def extension_type(extension: dict[str, Any]) -> int:
    name = str(extension.get("name") or "")
    match = re.search(r"\((?:0x([0-9a-fA-F]+)|([0-9]+))\)\s*$", name)
    if match is None:
        unknown = re.fullmatch(r"Unknown extension ([0-9]+)", name)
        if unknown is not None:
            return int(unknown.group(1), 10)
        raise AssertionError(f"unparseable extension name: {name!r}")
    if match.group(1) is not None:
        return int(match.group(1), 16)
    return int(match.group(2), 10)


def is_grease(value: int) -> bool:
    high, low = divmod(value, 0x100)
    return high == low and low & 0x0F == 0x0A


def normalized_capture(path: Path) -> dict[str, Any]:
    peet = load_peet(path)
    tls = peet["tls"]
    extensions: dict[int, dict[str, Any]] = {}
    for extension in tls.get("extensions") or []:
        number = extension_type(extension)
        if not is_grease(number):
            extensions[number] = extension
    return {
        "path": str(path),
        "ja4": tls.get("ja4"),
        "ja4_r": tls.get("ja4_r"),
        "ja3": tls.get("ja3"),
        "extensionTypes": sorted(extensions),
        "extensions": extensions,
        "httpVersion": peet.get("http_version"),
        "akamaiHash": (peet.get("http2") or {}).get("akamai_fingerprint_hash"),
    }


def require_phase(capture: dict[str, Any], *, resumed: bool) -> None:
    extensions = capture["extensions"]
    trust_anchors = extensions.get(TRUST_ANCHORS_EXTENSION)
    assert trust_anchors is not None, capture
    assert str(trust_anchors.get("data") or "").lower() == "0000", capture
    assert (PRE_SHARED_KEY_EXTENSION in extensions) is resumed, capture
    expected_prefix = "t13d1518h2_" if resumed else "t13d1517h2_"
    assert str(capture["ja4"]).startswith(expected_prefix), capture


def compare_phase(
    chrome: dict[str, Any], wreq: dict[str, Any], *, resumed: bool
) -> dict[str, Any]:
    require_phase(chrome, resumed=resumed)
    require_phase(wreq, resumed=resumed)
    assert chrome["extensionTypes"] == wreq["extensionTypes"], {
        "chrome": chrome,
        "wreq": wreq,
    }
    assert chrome["httpVersion"] == wreq["httpVersion"] == "h2"
    assert chrome["akamaiHash"] == wreq["akamaiHash"]
    return {
        "chromeJa4": chrome["ja4"],
        "wreqJa4": wreq["ja4"],
        "extensionTypes": chrome["extensionTypes"],
        "akamaiHash": chrome["akamaiHash"],
    }


def main() -> None:
    args = parse_args()
    cold = compare_phase(
        normalized_capture(args.chrome_cold),
        normalized_capture(args.wreq_cold),
        resumed=False,
    )
    resumed = compare_phase(
        normalized_capture(args.chrome_resumed),
        normalized_capture(args.wreq_resumed),
        resumed=True,
    )
    print(json.dumps({"cold": cold, "resumed": resumed}, indent=2))
    print("Chrome149/wreq normalized TLS cold+resumption parity: PASS")


if __name__ == "__main__":
    main()
