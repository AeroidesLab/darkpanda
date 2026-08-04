from __future__ import annotations

import argparse
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import tempfile
import unittest

from tools.ci import v8_bundle as subject


class V8BundleTests(unittest.TestCase):
    """Validate source-built V8 cache manifests and archive integrity."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive = self.root / "libc_v8_standalone.a"
        self.archive.write_bytes(b"source-built-v8")
        self.manifest = self.root / "manifest.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def arguments(self, command: str) -> argparse.Namespace:
        values = [
            command,
            "--manifest",
            str(self.manifest),
            "--build-mode",
            "source",
            "--platform",
            "linux-x86_64",
            "--target",
            "x86_64-linux-gnu",
            "--v8-version",
            "14.9.207.35",
            "--v8-revision",
            "9" * 40,
            "--zig-v8-source-revision",
            "8" * 40,
            "--zig-version",
            "0.15.2",
        ]
        if command == "create":
            values.extend(("--archive", str(self.archive)))
        return subject.parser().parse_args(values)

    def test_source_build_contract_round_trips(self) -> None:
        with redirect_stdout(io.StringIO()):
            subject.create(self.arguments("create"))
        payload = json.loads(self.manifest.read_text(encoding="utf-8"))
        self.assertEqual(payload["buildMode"], "source")
        with redirect_stdout(io.StringIO()):
            subject.verify(self.arguments("verify"))

    def test_modified_archive_is_rejected(self) -> None:
        with redirect_stdout(io.StringIO()):
            subject.create(self.arguments("create"))
        self.archive.write_bytes(b"tampered-v8-xxx")
        with self.assertRaisesRegex(SystemExit, "SHA-256 does not match"):
            subject.verify(self.arguments("verify"))


if __name__ == "__main__":
    unittest.main()
