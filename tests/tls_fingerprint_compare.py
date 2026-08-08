"""Compare real Google Chrome Stable and DarkPanda peet captures.

Chrome inputs must be provenance-bound wrappers from
``chrome_stable_tls_capture.py``.  Wreq inputs may be direct
``https://tls.peet.ws/api/all`` responses or wrappers containing that response
as JSON/text.  GREASE values are normalized without discarding their positions.
Random key material is reduced to its shape; protocol-significant ordering and
values remain strict.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


TRUST_ANCHORS_EXTENSION = 0xCA34
PRE_SHARED_KEY_EXTENSION = 41
KEY_SHARE_EXTENSION = 51
ENCRYPTED_CLIENT_HELLO_EXTENSION = 0xFE0D
ECH_GREASE_PAYLOAD_LENGTHS = {144, 176, 208, 240}
CHROME_CAPTURE_SCHEMA = "darkpanda-google-chrome-stable-capture/v1"
PROFILE_PATH = Path(__file__).parents[1] / "tools" / "ci" / "chromium-profile.json"
TARGET_CHROME_VERSION = json.loads(PROFILE_PATH.read_text(encoding="utf-8"))[
    "google_chrome_stable"
]["version"]
TARGET_CHROME_HOST_SYSTEM = "Windows"


def parse_args() -> argparse.Namespace:
    """Parse capture paths."""

    parser = argparse.ArgumentParser()
    parser.add_argument("--chrome-cold", required=True, type=Path)
    parser.add_argument("--chrome-resumed", type=Path)
    parser.add_argument("--wreq-cold", required=True, type=Path)
    parser.add_argument("--wreq-resumed", type=Path)
    args = parser.parse_args()
    if (args.chrome_resumed is None) != (args.wreq_resumed is None):
        parser.error("resumed Chrome and wreq captures must be supplied together")
    return args


def find_peet(value: Any) -> dict[str, Any] | None:
    """Find a peet response in a capture wrapper."""

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
    """Load one peet response from disk."""

    parsed = json.loads(path.read_text(encoding="utf-8"))
    peet = find_peet(parsed)
    if peet is None:
        raise AssertionError(f"{path}: no tls.peet.ws response found")
    return peet


def load_chrome_peet(path: Path, phase: str) -> dict[str, Any]:
    """Load one official Stable capture for the exact emulated target."""

    capture = json.loads(path.read_text(encoding="utf-8"))
    browser = capture.get("browser") or {}
    host = capture.get("host") or {}
    automation = capture.get("automation") or {}
    devtools = capture.get("devtools") or {}
    provenance = browser.get("provenance") or {}
    version = str(browser.get("version") or "")
    expected = {
        "schema": CHROME_CAPTURE_SCHEMA,
        "phase": phase,
        "product": "Google Chrome Stable",
        "version": TARGET_CHROME_VERSION,
        "hostSystem": TARGET_CHROME_HOST_SYSTEM,
        "devtoolsBrowser": f"Chrome/{version}",
        "provenanceKind": "authenticode",
        "signatureStatus": "Valid",
        "headless": False,
        "userAgentOverride": False,
    }
    actual = {
        "schema": capture.get("schema"),
        "phase": capture.get("phase"),
        "product": browser.get("product"),
        "version": version,
        "hostSystem": host.get("system"),
        "devtoolsBrowser": devtools.get("browser"),
        "provenanceKind": provenance.get("kind"),
        "signatureStatus": provenance.get("Status"),
        "headless": automation.get("headless"),
        "userAgentOverride": automation.get("userAgentOverride"),
    }
    assert actual == expected, {
        "path": str(path),
        "expected": expected,
        "actual": actual,
    }
    assert "Google LLC" in str(provenance.get("Subject")), provenance
    peet = find_peet(capture)
    if peet is None:
        raise AssertionError(f"{path}: no tls.peet.ws response found")
    return peet


def extension_type(extension: dict[str, Any]) -> int:
    """Return the numeric TLS extension type reported by peet."""

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
    """Return whether an integer is an RFC 8701 GREASE value."""

    high, low = divmod(value, 0x100)
    return high == low and low & 0x0F == 0x0A


def grease_label(value: str) -> str:
    """Normalize a labeled GREASE value while preserving its position."""

    match = re.search(r"\((?:0x([0-9a-fA-F]+)|([0-9]+))\)\s*$", value)
    if match is None:
        return value
    number = int(match.group(1), 16) if match.group(1) else int(match.group(2))
    return "GREASE" if is_grease(number) else value


def normalize_grease(value: Any) -> Any:
    """Normalize GREASE labels recursively without sorting sequences."""

    if isinstance(value, str):
        return grease_label(value)
    if isinstance(value, list):
        return [normalize_grease(item) for item in value]
    if isinstance(value, dict):
        return {
            grease_label(str(key)): normalize_grease(item)
            for key, item in value.items()
        }
    return value


def dynamic_shape(value: Any) -> Any:
    """Keep dynamic TLS field structure and byte lengths, not random bytes."""

    if isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F]*", value):
        return f"<hex-bytes:{len(value) // 2}>"
    if isinstance(value, list):
        return [dynamic_shape(item) for item in value]
    if isinstance(value, dict):
        return {
            grease_label(str(key)): dynamic_shape(item)
            for key, item in value.items()
        }
    if isinstance(value, int):
        return "<integer>"
    return normalize_grease(value)


def normalize_ech_grease(payload: dict[str, Any]) -> dict[str, Any]:
    """Validate BoringSSL's randomized ECH GREASE envelope."""

    assert set(payload) == {"data"}, payload
    data = payload["data"]
    assert isinstance(data, str) and re.fullmatch(r"[0-9a-fA-F]+", data), payload
    raw = bytes.fromhex(data)
    assert len(raw) >= 10, payload
    assert raw[0] == 0, payload
    enc_length = int.from_bytes(raw[6:8], "big")
    assert enc_length == 32, payload
    payload_length_offset = 8 + enc_length
    assert len(raw) >= payload_length_offset + 2, payload
    encrypted_payload_length = int.from_bytes(
        raw[payload_length_offset : payload_length_offset + 2], "big"
    )
    assert encrypted_payload_length == len(raw) - payload_length_offset - 2, payload
    assert encrypted_payload_length in ECH_GREASE_PAYLOAD_LENGTHS, payload
    return {
        "clientHelloType": 0,
        "kdfId": int.from_bytes(raw[1:3], "big"),
        "aeadId": int.from_bytes(raw[3:5], "big"),
        "configId": "<random-byte>",
        "enc": "<random-bytes:32>",
        "payload": "<random-boringssl-ech-grease>",
    }


def normalize_extension(extension: dict[str, Any]) -> dict[str, Any]:
    """Normalize one extension while retaining order-relevant semantics."""

    number = extension_type(extension)
    if is_grease(number):
        return {"type": "GREASE"}

    payload = {key: value for key, value in extension.items() if key != "name"}
    if number == KEY_SHARE_EXTENSION:
        payload = {
            key: (
                dynamic_shape(value)
                if key == "shared_keys"
                else normalize_grease(value)
            )
            for key, value in payload.items()
        }
    elif number == ENCRYPTED_CLIENT_HELLO_EXTENSION:
        payload = normalize_ech_grease(payload)
    elif number == PRE_SHARED_KEY_EXTENSION:
        payload = dynamic_shape(payload)
    else:
        payload = normalize_grease(payload)
    return {"type": number, "payload": payload}


def header_name(header: str) -> str:
    """Extract an HTTP/2 header name, including pseudo-header colons."""

    if header.startswith(":"):
        end = header.find(":", 1)
        if end < 0:
            raise AssertionError(f"malformed pseudo-header: {header!r}")
        return header[:end].lower()
    name, separator, _ = header.partition(":")
    if not separator:
        raise AssertionError(f"malformed header: {header!r}")
    return name.lower()


def normalize_http2_frame(frame: dict[str, Any]) -> dict[str, Any]:
    """Remove encoded lengths while keeping HTTP/2 ordering and values."""

    normalized = {
        key: value for key, value in frame.items() if key not in {"length", "headers"}
    }
    if "headers" in frame:
        normalized["headerOrder"] = [
            header_name(str(item)) for item in frame["headers"]
        ]
    return normalized


def normalized_peet(peet: dict[str, Any], path: str = "<memory>") -> dict[str, Any]:
    """Return the strict, stable transport observables from one response."""

    tls = peet.get("tls")
    http2 = peet.get("http2")
    if not isinstance(tls, dict) or not isinstance(http2, dict):
        raise AssertionError(f"{path}: missing tls/http2 evidence")

    extensions = [normalize_extension(item) for item in tls.get("extensions") or []]
    extension_order = [item["type"] for item in extensions]
    return {
        "path": path,
        "userAgent": peet.get("user_agent"),
        "httpVersion": peet.get("http_version"),
        "tlsVersionRecord": tls.get("tls_version_record"),
        "tlsVersionNegotiated": tls.get("tls_version_negotiated"),
        "ciphers": normalize_grease(tls.get("ciphers") or []),
        "ja3": tls.get("ja3"),
        "ja3Normalized": normalize_ja3(str(tls.get("ja3") or "")),
        "ja4": tls.get("ja4"),
        "ja4_r": tls.get("ja4_r"),
        "peetprint": tls.get("peetprint"),
        "extensions": extensions,
        "extensionOrder": extension_order,
        "extensionInventory": sorted(str(item) for item in extension_order),
        "extensionPayloads": sorted(
            json.dumps(item, sort_keys=True, separators=(",", ":"))
            for item in extensions
        ),
        "http2Fingerprint": http2.get("akamai_fingerprint"),
        "akamaiHash": http2.get("akamai_fingerprint_hash"),
        "http2Frames": [
            normalize_http2_frame(frame) for frame in http2.get("sent_frames") or []
        ],
    }


def normalize_ja3(value: str) -> str:
    """Normalize only Chrome's randomized extension-order JA3 component."""

    parts = value.split(",")
    if len(parts) != 5:
        raise AssertionError(f"malformed JA3: {value!r}")
    try:
        extensions = sorted(int(item) for item in parts[2].split("-") if item)
    except ValueError as error:
        raise AssertionError(f"malformed JA3 extensions: {value!r}") from error
    parts[2] = "-".join(str(item) for item in extensions)
    return ",".join(parts)


def normalized_capture(path: Path) -> dict[str, Any]:
    """Load and normalize a capture."""

    return normalized_peet(load_peet(path), str(path))


def normalized_chrome_capture(path: Path, phase: str) -> dict[str, Any]:
    """Load and normalize a provenance-bound official Stable capture."""

    return normalized_peet(load_chrome_peet(path, phase), str(path))


def extension_payload(capture: dict[str, Any], number: int) -> dict[str, Any] | None:
    """Return one normalized extension payload by type."""

    return next(
        (
            item.get("payload")
            for item in capture["extensions"]
            if item["type"] == number
        ),
        None,
    )


def require_phase(capture: dict[str, Any], *, resumed: bool) -> None:
    """Validate cold/resumed invariants before cross-client comparison."""

    assert extension_payload(capture, TRUST_ANCHORS_EXTENSION) is None, capture
    assert (PRE_SHARED_KEY_EXTENSION in capture["extensionOrder"]) is resumed, capture
    order = capture["extensionOrder"]
    assert order and order[0] == "GREASE", capture
    terminal_grease_index = -2 if resumed else -1
    assert order[terminal_grease_index] == "GREASE", capture
    if resumed:
        assert order[-1] == PRE_SHARED_KEY_EXTENSION, capture
    expected_prefix = "t13d1517h2_" if resumed else "t13d1516h2_"
    assert str(capture["ja4"]).startswith(expected_prefix), capture


PARITY_FIELDS = (
    "userAgent",
    "httpVersion",
    "tlsVersionRecord",
    "tlsVersionNegotiated",
    "ciphers",
    "ja3Normalized",
    "ja4",
    "ja4_r",
    "peetprint",
    "extensionInventory",
    "extensionPayloads",
    "http2Fingerprint",
    "akamaiHash",
    "http2Frames",
)


def compare_phase(
    chrome: dict[str, Any], wreq: dict[str, Any], *, resumed: bool
) -> dict[str, Any]:
    """Require strict transport parity for one handshake phase."""

    require_phase(chrome, resumed=resumed)
    require_phase(wreq, resumed=resumed)
    for field in PARITY_FIELDS:
        assert chrome[field] == wreq[field], {
            "field": field,
            "chrome": chrome[field],
            "wreq": wreq[field],
            "chromePath": chrome["path"],
            "wreqPath": wreq["path"],
        }
    return {
        "ja3": chrome["ja3"],
        "ja3Normalized": chrome["ja3Normalized"],
        "ja4": chrome["ja4"],
        "ja4_r": chrome["ja4_r"],
        "chromeExtensionOrder": chrome["extensionOrder"],
        "wreqExtensionOrder": wreq["extensionOrder"],
        "http2Fingerprint": chrome["http2Fingerprint"],
        "headerOrder": next(
            (
                frame["headerOrder"]
                for frame in chrome["http2Frames"]
                if "headerOrder" in frame
            ),
            [],
        ),
    }


def main() -> None:
    """Compare cold and resumed Chrome/wreq captures."""

    args = parse_args()
    cold = compare_phase(
        normalized_chrome_capture(args.chrome_cold, "cold"),
        normalized_capture(args.wreq_cold),
        resumed=False,
    )
    result = {"cold": cold}
    if args.chrome_resumed is not None and args.wreq_resumed is not None:
        result["resumed"] = compare_phase(
            normalized_chrome_capture(args.chrome_resumed, "resumed"),
            normalized_capture(args.wreq_resumed),
            resumed=True,
        )
    print(json.dumps(result, indent=2))
    print("Google Chrome Stable/wreq strict TLS+HTTP2+header parity: PASS")


if __name__ == "__main__":
    main()
