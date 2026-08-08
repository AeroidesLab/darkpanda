"""Tests for the pinned official Chrome Stable package record."""

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).with_name("materialize_google_chrome_stable.py")
SPEC = importlib.util.spec_from_file_location(
    "materialize_google_chrome_stable", MODULE_PATH
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {MODULE_PATH}")
materialize = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(materialize)


class ChromeStableMaterializationTests(unittest.TestCase):
    """Keep the oracle pinned to Google's Stable package host and identity."""

    def test_profile_accepts_only_the_pinned_google_package(self) -> None:
        profile_path = Path(__file__).with_name("chromium-profile.json")
        profile = json.loads(profile_path.read_text(encoding="utf-8"))
        expected = profile["google_chrome_stable"]
        self.assertEqual(materialize.load_profile(profile_path), expected)

        mutations = (
            ("platform", "mac-arm64"),
            ("package_url", "https://example.com/chrome.crx3"),
            ("package_sha256", "0"),
            ("installer_name", "chrome-for-testing.exe"),
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "profile.json"
            for key, value in mutations:
                invalid = copy.deepcopy(profile)
                invalid["google_chrome_stable"][key] = value
                path.write_text(json.dumps(invalid), encoding="utf-8")
                with self.subTest(key=key, value=value):
                    with self.assertRaises(AssertionError):
                        materialize.load_profile(path)

    def test_signtool_evidence_requires_google_signer(self) -> None:
        output = """
        Successfully verified: chrome.exe
        Signing Certificate Chain:
            Issued to: Google LLC
        """
        self.assertEqual(
            materialize.signtool_evidence(output),
            {
                "Status": "Valid",
                "Subject": "Google LLC",
                "Verifier": "signtool.exe",
            },
        )
        with self.assertRaises(AssertionError):
            materialize.signtool_evidence("Issued to: Example Corp")


if __name__ == "__main__":
    unittest.main()
