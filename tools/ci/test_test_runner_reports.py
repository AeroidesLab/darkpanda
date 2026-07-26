#!/usr/bin/env python3
"""Integration checks for the custom Zig test runner result contract."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET


FIXTURE = r"""
const std = @import("std");

test "passing <& test" {
    try std.testing.expect(true);
}

test "intentional failure" {
    return error.IntentionalFailure;
}

test "after first failure" {
    try std.testing.expect(true);
}

test "memory leak" {
    _ = try std.testing.allocator.alloc(u8, 1);
}
"""


def run_case(
    *,
    zig: Path,
    repo: Path,
    work: Path,
    name: str,
    test_filter: str,
    fail_first: bool,
    expected_exit: int,
) -> tuple[dict[str, object], ET.Element, str]:
    json_path = work / f"{name}.json"
    junit_path = work / f"{name}.xml"
    env = os.environ.copy()
    env.update(
        {
            "TEST_FILTER": test_filter,
            "TEST_FAIL_FIRST": "true" if fail_first else "false",
            "TEST_VERBOSE": "true",
            "TEST_JSON_OUTPUT": str(json_path),
            "TEST_JUNIT_OUTPUT": str(junit_path),
        }
    )
    env.pop("METRICS", None)

    completed = subprocess.run(
        [
            str(zig),
            "test",
            str(work / "fixture.zig"),
            "--test-runner",
            str(repo / "src" / "test_runner.zig"),
            "--cache-dir",
            str(work / "cache"),
            "--global-cache-dir",
            str(work / "global-cache"),
        ],
        cwd=repo,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        timeout=120,
        check=False,
    )
    if completed.returncode != expected_exit:
        raise AssertionError(
            f"{name}: expected exit {expected_exit}, got {completed.returncode}\n"
            f"{completed.stdout}"
        )
    if not json_path.is_file() or not junit_path.is_file():
        raise AssertionError(f"{name}: runner did not write both reports")

    report = json.loads(json_path.read_text(encoding="utf-8"))
    root = ET.parse(junit_path).getroot()
    if report.get("schema") != "darkpanda-test-results/v1":
        raise AssertionError(f"{name}: unexpected JSON schema")
    if root.tag != "testsuites":
        raise AssertionError(f"{name}: unexpected JUnit root {root.tag!r}")
    return report, root, completed.stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument(
        "--repo",
        type=Path,
        default=Path(__file__).resolve().parents[2],
    )
    args = parser.parse_args()
    zig = args.zig.resolve(strict=True)
    repo = args.repo.resolve(strict=True)

    with tempfile.TemporaryDirectory(prefix="darkpanda-test-runner-") as temp:
        work = Path(temp)
        (work / "fixture.zig").write_text(FIXTURE, encoding="utf-8")

        passed, passed_xml, _ = run_case(
            zig=zig,
            repo=repo,
            work=work,
            name="passed",
            test_filter="passing <& test",
            fail_first=False,
            expected_exit=0,
        )
        assert passed["summary"]["success"] is True
        assert passed["summary"]["selected"] == 1
        assert passed["tests"][0]["name"] == "passing <& test"
        assert passed_xml.find(".//testcase").attrib["name"] == "passing <& test"

        failed, failed_xml, failed_console = run_case(
            zig=zig,
            repo=repo,
            work=work,
            name="fail-first",
            test_filter="",
            fail_first=True,
            expected_exit=1,
        )
        failed_names = [case["name"] for case in failed["tests"]]
        assert "intentional failure" in failed_names
        assert "after first failure" not in failed_names
        assert failed["summary"]["failed"] == 1
        assert "Failed Test Summary" in failed_console
        assert "- intentional failure" in failed_console
        assert failed_xml.find(".//failure") is not None

        leaked, leaked_xml, _ = run_case(
            zig=zig,
            repo=repo,
            work=work,
            name="leak",
            test_filter="memory leak",
            fail_first=False,
            expected_exit=1,
        )
        assert leaked["summary"]["leaked"] == 1
        assert leaked["summary"]["failed"] == 1
        assert leaked["tests"][0]["memory_leak"] is True
        assert "Memory leak detected" in (leaked_xml.findtext(".//failure") or "")

        empty, empty_xml, _ = run_case(
            zig=zig,
            repo=repo,
            work=work,
            name="zero-match",
            test_filter="does not exist",
            fail_first=False,
            expected_exit=1,
        )
        assert empty["summary"]["zero_matches"] is True
        assert empty["summary"]["selected"] == 0
        assert empty["tests"] == []
        discovery = empty_xml.find(".//testcase[@name='test discovery']/failure")
        assert discovery is not None

    print("custom test runner report checks: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
