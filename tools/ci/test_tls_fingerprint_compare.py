"""Unit tests for the strict Chrome/wreq transport comparator."""

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
from typing import Any


MODULE_PATH = (
    Path(__file__).resolve().parents[2] / "tests" / "tls_fingerprint_compare.py"
)
SPEC = importlib.util.spec_from_file_location("tls_fingerprint_compare", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {MODULE_PATH}")
compare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compare)
sys.modules["tls_fingerprint_compare"] = compare

CAPTURE_MODULE_PATH = (
    Path(__file__).resolve().parents[2] / "tests" / "chrome_stable_tls_capture.py"
)
CAPTURE_SPEC = importlib.util.spec_from_file_location(
    "chrome_stable_tls_capture", CAPTURE_MODULE_PATH
)
if CAPTURE_SPEC is None or CAPTURE_SPEC.loader is None:
    raise RuntimeError(f"cannot load {CAPTURE_MODULE_PATH}")
capture_tool = importlib.util.module_from_spec(CAPTURE_SPEC)
CAPTURE_SPEC.loader.exec_module(capture_tool)


def capture(*, grease: int = 0x0A0A, resumed: bool = False) -> dict[str, Any]:
    """Build one compact peet-shaped Chrome 149 capture."""

    extensions: list[dict[str, Any]] = [
        {"name": f"GREASE (0x{grease:04x})", "data": "abcd"},
        {
            "name": "supported_groups (10)",
            "supported_groups": [
                f"GREASE ({grease})",
                "X25519MLKEM768 (4588)",
                "X25519 (29)",
            ],
        },
        {
            "name": "application_layer_protocol_negotiation (16)",
            "protocols": ["h2", "http/1.1"],
        },
        {
            "name": "key_share (51)",
            "shared_keys": [
                {f"GREASE ({grease})": "abcd"},
                {"X25519MLKEM768 (4588)": "00" * 1216},
            ],
        },
        {"name": "trust_anchors (0xca34)", "data": "0000"},
        {"name": f"GREASE (0x{grease + 0x2020:04x})", "data": "ef01"},
    ]
    if resumed:
        extensions.append(
            {
                "name": "pre_shared_key (41)",
                "identities": [{"identity": "012345", "obfuscated_ticket_age": 42}],
                "binders": ["abcdef"],
            }
        )
    return {
        "user_agent": "Mozilla/5.0 Chrome/149.0.0.0 Safari/537.36",
        "http_version": "h2",
        "tls": {
            "tls_version_record": "771",
            "tls_version_negotiated": "772",
            "ciphers": [f"GREASE (0x{grease:04x})", "TLS_AES_128_GCM_SHA256"],
            "extensions": extensions,
            "ja3": "771,4865,10-16-51-51764,4588-29,0",
            "ja4": ("t13d1518h2_same" if resumed else "t13d1517h2_same"),
            "ja4_r": "same-ja4-r",
            "peetprint": "same-peetprint",
        },
        "http2": {
            "akamai_fingerprint": "1:65536;2:0;4:6291456;6:262144|15663105|0|m,a,s,p",
            "akamai_fingerprint_hash": "same-akamai-hash",
            "sent_frames": [
                {
                    "frame_type": "SETTINGS",
                    "length": 24,
                    "settings": [
                        "HEADER_TABLE_SIZE = 65536",
                        "ENABLE_PUSH = 0",
                        "INITIAL_WINDOW_SIZE = 6291456",
                        "MAX_HEADER_LIST_SIZE = 262144",
                    ],
                },
                {"frame_type": "WINDOW_UPDATE", "length": 4, "increment": 15663105},
                {
                    "frame_type": "HEADERS",
                    "length": 100,
                    "headers": [
                        ":method: GET",
                        ":authority: tls.peet.ws",
                        ":scheme: https",
                        ":path: /api/all",
                        "user-agent: Mozilla/5.0 Chrome/149.0.0.0 Safari/537.36",
                        "accept-language: en-US,en;q=0.9",
                    ],
                },
            ],
        },
    }


class StrictFingerprintCompareTests(unittest.TestCase):
    """Protect the wire observables the acceptance gate claims to compare."""

    def assert_mismatch(
        self, chrome: dict[str, Any], wreq: dict[str, Any]
    ) -> None:
        with self.assertRaises(AssertionError):
            compare.compare_phase(
                compare.normalized_peet(chrome, "chrome"),
                compare.normalized_peet(wreq, "wreq"),
                resumed=False,
            )

    def test_grease_and_random_keys_keep_shape_and_position(self) -> None:
        chrome = capture(grease=0x0A0A)
        wreq = capture(grease=0x2A2A)
        wreq["tls"]["extensions"][3]["shared_keys"][1][
            "X25519MLKEM768 (4588)"
        ] = "ff" * 1216
        compare.compare_phase(
            compare.normalized_peet(chrome, "chrome"),
            compare.normalized_peet(wreq, "wreq"),
            resumed=False,
        )

    def test_resumed_psk_random_material_keeps_strict_shape(self) -> None:
        chrome = capture(resumed=True)
        wreq = copy.deepcopy(chrome)
        psk = wreq["tls"]["extensions"][-1]
        psk["identities"][0]["identity"] = "fedcba"
        psk["identities"][0]["obfuscated_ticket_age"] = 99
        psk["binders"][0] = "123456"
        compare.compare_phase(
            compare.normalized_peet(chrome, "chrome"),
            compare.normalized_peet(wreq, "wreq"),
            resumed=True,
        )

        missing_psk = copy.deepcopy(wreq)
        missing_psk["tls"]["extensions"].pop()
        with self.assertRaises(AssertionError):
            compare.compare_phase(
                compare.normalized_peet(chrome, "chrome"),
                compare.normalized_peet(missing_psk, "wreq"),
                resumed=True,
            )

    def test_permutable_tls_extension_order_is_not_compared_byte_for_byte(self) -> None:
        chrome = capture()
        wreq = copy.deepcopy(chrome)
        wreq["tls"]["extensions"][1:3] = reversed(wreq["tls"]["extensions"][1:3])
        wreq["tls"]["ja3"] = "771,4865,16-10-51-51764,4588-29,0"
        compare.compare_phase(
            compare.normalized_peet(chrome, "chrome"),
            compare.normalized_peet(wreq, "wreq"),
            resumed=False,
        )

    def test_leading_and_terminal_grease_positions_are_strict(self) -> None:
        chrome = capture()
        leading = copy.deepcopy(chrome)
        leading["tls"]["extensions"][0:2] = reversed(
            leading["tls"]["extensions"][0:2]
        )
        self.assert_mismatch(chrome, leading)

        terminal = copy.deepcopy(chrome)
        terminal["tls"]["extensions"][-2:] = reversed(
            terminal["tls"]["extensions"][-2:]
        )
        self.assert_mismatch(chrome, terminal)

    def test_supported_groups_and_alpn_are_strict(self) -> None:
        chrome = capture()
        curves = copy.deepcopy(chrome)
        curves["tls"]["extensions"][1]["supported_groups"].pop()
        self.assert_mismatch(chrome, curves)

        alpn = copy.deepcopy(chrome)
        alpn["tls"]["extensions"][2]["protocols"].reverse()
        self.assert_mismatch(chrome, alpn)

    def test_http2_settings_and_header_order_are_strict(self) -> None:
        chrome = capture()
        settings = copy.deepcopy(chrome)
        settings["http2"]["sent_frames"][0]["settings"].reverse()
        self.assert_mismatch(chrome, settings)

        headers = copy.deepcopy(chrome)
        headers["http2"]["sent_frames"][2]["headers"][-2:] = reversed(
            headers["http2"]["sent_frames"][2]["headers"][-2:]
        )
        self.assert_mismatch(chrome, headers)


class StableChromeCaptureTests(unittest.TestCase):
    """Reject non-Stable products and mislabeled handshake phases."""

    def test_only_google_chrome_stable_product_name_is_accepted(self) -> None:
        self.assertEqual(
            capture_tool.google_chrome_version("Google Chrome 151.0.7922.108"),
            "151.0.7922.108",
        )
        for product in (
            "Google Chrome for Testing 151.0.7922.108",
            "Chromium 151.0.7922.108",
            "HeadlessChrome 151.0.7922.108",
            "Google Chrome Beta 151.0.7922.108",
        ):
            with self.assertRaises(AssertionError):
                capture_tool.google_chrome_version(product)

    def test_windows_materialization_is_bound_to_the_binary(self) -> None:
        version_info = {
            "ProductName": "Google Chrome",
            "ProductVersion": "149.0.7827.201",
            "FileDescription": "Google Chrome",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "Chrome-bin" / "chrome.exe"
            binary.parent.mkdir()
            binary.write_bytes(b"signed chrome fixture")
            report = root / "materialization.json"
            report.write_text(
                json.dumps(
                    {
                        "schema": (
                            "darkpanda-google-chrome-stable-materialization/v1"
                        ),
                        "version": version_info["ProductVersion"],
                        "platform": "win64",
                        "chrome": {
                            "path": "Chrome-bin/chrome.exe",
                            "sha256": capture_tool.sha256(binary),
                            "signature": {
                                "Status": "Valid",
                                "Subject": "Google LLC",
                                "Verifier": "signtool.exe",
                            },
                            "versionInfo": version_info,
                        },
                    }
                ),
                encoding="utf-8",
            )
            self.assertEqual(
                capture_tool.windows_materialization(
                    binary.resolve(), report, version_info
                ),
                {
                    "kind": "authenticode",
                    "Status": "Valid",
                    "Subject": "Google LLC",
                    "Verifier": "signtool.exe",
                },
            )
            binary.write_bytes(b"tampered")
            with self.assertRaises(AssertionError):
                capture_tool.windows_materialization(
                    binary.resolve(), report, version_info
                )

    def test_capture_phase_requires_real_psk_evidence(self) -> None:
        capture_tool.validate_phase(capture(resumed=False), "cold")
        capture_tool.validate_phase(capture(resumed=True), "resumed")
        with self.assertRaises(AssertionError):
            capture_tool.validate_phase(capture(resumed=False), "resumed")

    def test_resumed_capture_flushes_stable_socket_pool(self) -> None:
        requests: list[dict[str, Any]] = []
        replies = iter(
            (
                {"targetId": "target"},
                {"sessionId": "session"},
                {},
                {"result": {"value": True}},
                {},
            )
        )

        class FakeSocket:
            def send(self, message: str) -> None:
                request = json.loads(message)
                requests.append(request)
                reply = {"id": request["id"], "result": next(replies)}
                self.reply = json.dumps(reply)

            def recv(self) -> str:
                return self.reply

            def close(self) -> None:
                pass

        websocket = mock.Mock()
        websocket.create_connection.return_value = FakeSocket()
        with (
            mock.patch.object(
                capture_tool,
                "open_json",
                return_value={"webSocketDebuggerUrl": "ws://stable"},
            ),
            mock.patch.dict(sys.modules, {"websocket": websocket}),
        ):
            capture_tool.flush_socket_pools("http://stable")

        expressions = [
            request["params"]["expression"]
            for request in requests
            if request.get("method") == "Runtime.evaluate"
        ]
        self.assertEqual(len(expressions), 1)
        self.assertIn("sockets-view-flush-button", expressions[0])

    def test_comparator_requires_exact_windows_stable_oracle(self) -> None:
        wrapped = {
            "schema": compare.CHROME_CAPTURE_SCHEMA,
            "phase": "cold",
            "host": {"system": "Windows"},
            "browser": {
                "product": "Google Chrome Stable",
                "version": compare.TARGET_CHROME_VERSION,
                "provenance": {
                    "kind": "authenticode",
                    "Status": "Valid",
                    "Subject": "CN=Google LLC",
                },
            },
            "devtools": {
                "browser": f"Chrome/{compare.TARGET_CHROME_VERSION}",
            },
            "automation": {"headless": False, "userAgentOverride": False},
            "responseBodyJson": capture(),
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "chrome.json"
            path.write_text(json.dumps(wrapped), encoding="utf-8")
            self.assertEqual(compare.load_chrome_peet(path, "cold"), capture())
            mutations = (
                ("browser", "product", "Google Chrome for Testing"),
                ("browser", "version", "149.0.7827.203"),
                ("host", "system", "Darwin"),
                ("automation", "userAgentOverride", True),
            )
            for section, key, value in mutations:
                invalid = copy.deepcopy(wrapped)
                invalid[section][key] = value
                path.write_text(json.dumps(invalid), encoding="utf-8")
                with self.subTest(section=section, key=key, value=value):
                    with self.assertRaises(AssertionError):
                        compare.load_chrome_peet(path, "cold")


if __name__ == "__main__":
    unittest.main()
