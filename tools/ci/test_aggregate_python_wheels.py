from __future__ import annotations

import argparse
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from tools.ci import aggregate_python_wheels as subject


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value) + "\n", encoding="utf-8")


class AggregatePythonWheelsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.results = self.root / "results"
        self.release = self.root / "release"
        self.release.mkdir()
        (self.release / "native.zip").write_bytes(b"native")
        self.python_revision = "a" * 40
        self.browser_revision = "b" * 40
        self.profile = "c" * 64
        self.resolved = self.root / "resolved.json"
        write_json(
            self.resolved,
            {
                "schema": "darkpanda-resolved-inputs/v5",
                "pythonBinding": {
                    "repository": "AeroidesLab/py-darkpanda",
                    "revision": self.python_revision,
                },
                "darkpanda": {"revision": self.browser_revision},
                "browserProfile": {"profileSha256": self.profile},
            },
        )
        for target_id in subject.TARGETS:
            self.make_result(target_id)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_result(self, target_id: str) -> None:
        root = self.results / f"python-result-{target_id}"
        wheel_dir = root / "python-output" / target_id
        wheel_dir.mkdir(parents=True)
        suffix = "win_amd64" if target_id.startswith("windows-") else "manylinux_x86_64"
        wheel = wheel_dir / f"py_darkpanda-0.1.0-cp310-abi3-{suffix}.whl"
        extension = (
            "darkpanda/_native.cp310-win_amd64.pyd"
            if target_id.startswith("windows-")
            else "darkpanda/_native.abi3.so"
        )
        with zipfile.ZipFile(wheel, "w") as bundle:
            for name in (
                "darkpanda/__init__.py",
                "darkpanda/_api.py",
                "darkpanda/_cdp.py",
                "darkpanda/_native.pyi",
                "darkpanda/py.typed",
                extension,
                *(
                    f"darkpanda/_native_libs/{library}"
                    for library in subject.TARGETS[target_id]
                ),
            ):
                bundle.writestr(name, b"x")
        digest = subject.sha256(wheel)
        wheel.with_name(wheel.name + ".sha256").write_text(
            f"{digest}  {wheel.name}\n", encoding="utf-8"
        )
        write_json(
            root / "python-reports" / f"py-darkpanda-{target_id}.json",
            {
                "schema": subject.SCHEMA,
                "status": "passed",
                "target": target_id,
                "sourceRevision": self.python_revision,
                "browserRevision": self.browser_revision,
                "chromiumProfileSha256": self.profile,
                "bundledLibraries": list(subject.TARGETS[target_id]),
                "toolchainManifestSha256": "d" * 64,
                "steps": {
                    name: {"status": "passed"} for name in subject.REQUIRED_STEPS
                },
                "wheel": {
                    "name": wheel.name,
                    "sha256": digest,
                    "size": wheel.stat().st_size,
                },
            },
        )

    def test_aggregate_copies_both_wheels_and_rewrites_release_checksums(self) -> None:
        output = self.root / "summary.json"
        markdown = self.root / "summary.md"
        result = subject.aggregate(
            argparse.Namespace(
                results=self.results,
                resolved_inputs=self.resolved,
                release_dir=self.release,
                output=output,
                markdown=markdown,
            )
        )

        self.assertEqual(result, 0)
        self.assertEqual(load_json(output)["status"], "passed")
        wheels = sorted(self.release.glob("*.whl"))
        self.assertEqual(len(wheels), 2)
        checksums = (self.release / "SHA256SUMS").read_text(encoding="utf-8")
        self.assertIn("native.zip", checksums)
        for wheel in wheels:
            self.assertIn(wheel.name, checksums)
        self.assertNotIn("SHA256SUMS  SHA256SUMS", checksums)


def load_json(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    assert isinstance(value, dict)
    return value


if __name__ == "__main__":
    unittest.main()
