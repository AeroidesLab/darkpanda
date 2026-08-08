"""Tests for the machine-readable CreepJS compatibility gate."""

from __future__ import annotations

import copy
import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).resolve().parents[2] / "tests" / "creepjs_probe.py"
SPEC = importlib.util.spec_from_file_location("creepjs_probe", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {MODULE_PATH}")
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


def report() -> dict:
    sections = sorted(probe.MINIMUM_SECTIONS)
    return {
        "ready": True,
        "sections": sections,
        "stableSections": ["navigator", "screen"],
        "liedSections": [],
        "liesTotal": 0,
        "headless": {
            "likeHeadlessRating": 0,
            "headlessRating": 0,
            "stealthRating": 0,
            "likeHeadless": [],
            "headless": [],
            "stealth": [],
        },
        "features": {
            "version": "113-115",
            "versionRange": ["115", "115", "114", "113"],
            "cssVersion": "114-115",
            "windowVersion": "113-115",
            "jsVersion": "114-115",
            "cssFeatures": ["backdrop-filter"],
            "windowFeatures": sorted(probe.REQUIRED_WINDOW_FEATURES),
            "jsFeatures": sorted(probe.REQUIRED_JS_FEATURES),
        },
        "hashes": {
            section: f"hash-{section}"
            for section in set(sections) | set(probe.STRICT_HASH_SECTIONS)
        },
    }


class CreepJSProbeTests(unittest.TestCase):
    """Reject missing coverage, lies, bot signals, and engine drift."""

    def test_strict_bot_signal_and_coverage_contract(self) -> None:
        chrome = report()
        coverage = probe.compare_reports(chrome, copy.deepcopy(chrome))
        self.assertEqual(
            coverage,
            {
                "chromeWindowFeatures": len(probe.REQUIRED_WINDOW_FEATURES),
                "darkpandaWindowFeatures": len(probe.REQUIRED_WINDOW_FEATURES),
                "chromeJsFeatures": len(probe.REQUIRED_JS_FEATURES),
                "darkpandaJsFeatures": len(probe.REQUIRED_JS_FEATURES),
            },
        )
        mutations = (
            lambda value: value["sections"].remove("navigator"),
            lambda value: value.update(liesTotal=1),
            lambda value: value["headless"].update(headlessRating=33),
            lambda value: value["hashes"].update(maths="different"),
            lambda value: value["features"].update(jsVersion="different"),
            lambda value: value["features"]["windowFeatures"].remove(
                "SubmitEvent"
            ),
            lambda value: value["features"]["jsFeatures"].append(
                "NotAChromeFeature"
            ),
        )
        for mutate in mutations:
            darkpanda = copy.deepcopy(chrome)
            mutate(darkpanda)
            with self.subTest(mutation=mutate):
                with self.assertRaises(AssertionError):
                    probe.compare_reports(chrome, darkpanda)

    def test_api_inventory_hashes_are_reported_as_coverage(self) -> None:
        chrome = report()
        darkpanda = copy.deepcopy(chrome)
        darkpanda["hashes"].update(
            features="different",
            htmlElementVersion="different",
            windowFeatures="different",
        )
        probe.compare_reports(chrome, darkpanda)


if __name__ == "__main__":
    unittest.main()
