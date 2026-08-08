"""Tests for the machine-readable CreepJS parity gate."""

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
        "hashes": {section: f"hash-{section}" for section in sections},
    }


class CreepJSProbeTests(unittest.TestCase):
    """Reject missing coverage, lies, bot signals, and engine drift."""

    def test_strict_report_parity(self) -> None:
        chrome = report()
        probe.compare_reports(chrome, copy.deepcopy(chrome))
        mutations = (
            lambda value: value["sections"].remove("navigator"),
            lambda value: value.update(liesTotal=1),
            lambda value: value["headless"].update(headlessRating=33),
            lambda value: value["hashes"].update(maths="different"),
        )
        for mutate in mutations:
            darkpanda = copy.deepcopy(chrome)
            mutate(darkpanda)
            with self.subTest(mutation=mutate):
                with self.assertRaises(AssertionError):
                    probe.compare_reports(chrome, darkpanda)


if __name__ == "__main__":
    unittest.main()
