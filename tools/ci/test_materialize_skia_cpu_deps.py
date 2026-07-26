from __future__ import annotations

import hashlib
import ntpath
from pathlib import Path
import tempfile
import unittest

from tools.ci.materialize_skia_cpu_deps import tree_digest
from tools.ci.verify_chromium_toolchain import tree_digest as verify_tree_digest


class MaterializeSkiaCpuDepsTest(unittest.TestCase):
    def test_tree_digest_uses_platform_independent_casefolded_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = {
                "BUILD.gn": b"build",
                "arm0.c": b"root",
                "arm/arm_init.c": b"arm",
                "README.chromium": b"readme",
            }
            for relative, content in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)

            expected = hashlib.sha256()
            expected_order = [
                "arm0.c",
                "arm/arm_init.c",
                "BUILD.gn",
                "README.chromium",
            ]
            self.assertEqual(
                expected_order,
                sorted(files, key=lambda value: (ntpath.normcase(value), value)),
            )
            for relative in expected_order:
                encoded = relative.encode("utf-8")
                expected.update(len(encoded).to_bytes(8, "big"))
                expected.update(encoded)
                expected.update(hashlib.sha256(files[relative]).digest())

            expected_digest = (expected.hexdigest(), len(files))
            self.assertEqual(tree_digest(root), expected_digest)
            self.assertEqual(verify_tree_digest(root), expected_digest)


if __name__ == "__main__":
    unittest.main()
