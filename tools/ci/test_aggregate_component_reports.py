#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


COMPONENTS = ("canvas", "html5ever", "wreq", "boringssl")
TARGETS = ("windows-x86_64", "linux-x86_64")
SUITES = {
    "canvas": ("cargo-test", "c-abi-consumer", "fma-audit", "ninja-audit"),
    "html5ever": ("cargo-test", "c-abi-consumer"),
    "wreq": ("cargo-test", "c-abi-consumer"),
    "boringssl": ("crypto-archive-contract", "c-abi-consumer", "ctest"),
}
LIBRARIES = {
    ("canvas", "windows-x86_64"): "bin/canvas.dll",
    ("canvas", "linux-x86_64"): "bin/libcanvas.so",
    ("html5ever", "windows-x86_64"): "bin/html5ever.dll",
    ("html5ever", "linux-x86_64"): "bin/libhtml5ever.so",
    ("wreq", "windows-x86_64"): "bin/wreq.dll",
    ("wreq", "linux-x86_64"): "bin/libwreq.so",
    ("boringssl", "windows-x86_64"): "lib/crypto.lib",
    ("boringssl", "linux-x86_64"): "lib/libcrypto.a",
}
CONSUMER_FILES = {
    ("canvas", "windows-x86_64"): ("include/canvas.h", "lib/canvas.lib"),
    ("canvas", "linux-x86_64"): ("include/canvas.h",),
    ("html5ever", "windows-x86_64"): ("lib/html5ever.dll.lib",),
    ("html5ever", "linux-x86_64"): (),
    ("wreq", "windows-x86_64"): (),
    ("wreq", "linux-x86_64"): (),
    ("boringssl", "windows-x86_64"): ("include/openssl/sha.h",),
    ("boringssl", "linux-x86_64"): ("include/openssl/sha.h",),
}


def write_json(path: pathlib.Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value) + "\n", encoding="utf-8")


class AggregateComponentReportsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.results = self.root / "results"
        self.profile = "a" * 64
        self.revisions = {name: str(index + 1) * 40 for index, name in enumerate(COMPONENTS)}
        self.resolved = self.root / "resolved-inputs.json"
        write_json(
            self.resolved,
            {
                "schema": "darkpanda-resolved-inputs/v4",
                "browserProfile": {"profileSha256": self.profile},
                "components": {
                    name: {"revision": revision}
                    for name, revision in self.revisions.items()
                },
            },
        )
        for component in COMPONENTS:
            for target in TARGETS:
                self.make_artifact(component, target)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_artifact(self, component: str, target: str) -> None:
        dist = (
            self.results
            / f"component-{component}-{target}"
            / "component-dist"
            / component
            / target
        )
        library = dist / LIBRARIES[(component, target)]
        library.parent.mkdir(parents=True, exist_ok=True)
        library.write_bytes(f"{component}-{target}".encode())
        for relative in CONSUMER_FILES[(component, target)]:
            consumer_file = dist.joinpath(*pathlib.PurePosixPath(relative).parts)
            consumer_file.parent.mkdir(parents=True, exist_ok=True)
            consumer_file.write_bytes(relative.encode())
        metadata = dist / "metadata"
        write_json(
            metadata / "test-results.json",
            {
                "schema": "darkpanda-component-test-results/v1",
                "component": component,
                "requestedTarget": target,
                "status": "passed",
                "suites": [
                    {"name": name, "status": "passed"} for name in SUITES[component]
                ],
            },
        )
        write_json(
            metadata / "build-info.json",
            {
                "schema": "darkpanda-component-build-info/v1",
                "component": component,
                "requestedTarget": target,
                "source": {
                    "revision": self.revisions[component],
                    "dirty": False,
                },
                "chromiumProfileSha256": self.profile,
                "toolchainManifestSha256": "b" * 64,
                "configuration": (
                    {
                        "crt": {
                            "linkage": "static",
                            "flag": "/MT",
                        }
                    }
                    if component == "boringssl" and target == "windows-x86_64"
                    else {}
                ),
            },
        )
        checksum = metadata / "SHA256SUMS"
        lines = []
        for path in sorted(item for item in dist.rglob("*") if item.is_file()):
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            lines.append(f"{digest}  {path.relative_to(dist).as_posix()}")
        checksum.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def run_validator(self) -> subprocess.CompletedProcess[str]:
        script = pathlib.Path(__file__).with_name("aggregate_component_reports.py")
        return subprocess.run(
            [
                sys.executable,
                str(script),
                "--results",
                str(self.results),
                "--resolved-inputs",
                str(self.resolved),
                "--output",
                str(self.root / "summary.json"),
                "--markdown",
                str(self.root / "summary.md"),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_complete_unique_matrix_passes(self) -> None:
        completed = self.run_validator()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        summary = json.loads((self.root / "summary.json").read_text())
        self.assertEqual(summary["status"], "passed")
        self.assertEqual(summary["passed"], 8)

    def test_failure_still_writes_diagnostic_summary(self) -> None:
        report = next(
            (self.results / "component-canvas-linux-x86_64").rglob(
                "test-results.json"
            )
        )
        value = json.loads(report.read_text())
        value["suites"] = [
            suite for suite in value["suites"] if "abi" not in suite["name"]
        ]
        write_json(report, value)
        completed = self.run_validator()
        self.assertNotEqual(completed.returncode, 0)
        summary = json.loads((self.root / "summary.json").read_text())
        self.assertEqual(summary["status"], "failed")
        self.assertIn("required test suite is missing: abi", (self.root / "summary.md").read_text())

    def test_dirty_source_and_divergent_manifest_fail(self) -> None:
        dirty = next(
            (self.results / "component-wreq-windows-x86_64").rglob(
                "build-info.json"
            )
        )
        value = json.loads(dirty.read_text())
        value["source"]["dirty"] = True
        value["toolchainManifestSha256"] = "c" * 64
        write_json(dirty, value)
        completed = self.run_validator()
        self.assertNotEqual(completed.returncode, 0)
        summary = json.loads((self.root / "summary.json").read_text())
        self.assertIn(
            "build source is dirty or has no clean-source attestation",
            next(
                record["errors"]
                for record in summary["results"]
                if record["component"] == "wreq"
                and record["target"] == "windows-x86_64"
            ),
        )
        self.assertIn(
            "windows-x86_64 components do not share one toolchain manifest hash",
            summary["errors"],
        )


if __name__ == "__main__":
    unittest.main()
