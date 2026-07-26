from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tools.ci import verify_chromium_toolchain


class ChromiumToolchainManifestTests(unittest.TestCase):
    def test_bundle_member_is_recorded_as_posix_relative_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            tool = root / "llvm" / "bin" / "clang"
            tool.parent.mkdir(parents=True)
            tool.write_bytes(b"clang")
            self.assertEqual(
                verify_chromium_toolchain.bundle_relative(root, tool),
                "llvm/bin/clang",
            )

    def test_path_outside_bundle_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            root = base / "toolchain"
            outside = base / "clang"
            root.mkdir()
            outside.write_bytes(b"clang")
            with self.assertRaisesRegex(RuntimeError, "escapes bundle root"):
                verify_chromium_toolchain.bundle_relative(root, outside)

    def test_internal_symlink_keeps_its_flavor_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            tools = root / "llvm" / "bin"
            tools.mkdir(parents=True)
            target = tools / "lld"
            target.write_bytes(b"lld")
            linker = tools / "ld.lld"
            try:
                linker.symlink_to(target.name)
            except OSError as error:
                self.skipTest(f"symlinks are unavailable: {error}")

            self.assertEqual(
                verify_chromium_toolchain.require_within(
                    root, "llvm/bin/ld.lld"
                ),
                linker,
            )
            self.assertEqual(
                verify_chromium_toolchain.bundle_relative(root, linker),
                "llvm/bin/ld.lld",
            )


if __name__ == "__main__":
    unittest.main()
