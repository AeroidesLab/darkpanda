from __future__ import annotations

import hashlib
from pathlib import Path
import tempfile
import unittest

from tools.ci.materialize_skia_cpu_deps import tree_digest


class MaterializeSkiaCpuDepsTest(unittest.TestCase):
    def test_tree_digest_uses_platform_independent_casefolded_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = {
                "BUILD.gn": b"build",
                "arm/arm_init.c": b"arm",
                "README.chromium": b"readme",
            }
            for relative, content in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)

            expected = hashlib.sha256()
            for relative in sorted(files, key=lambda value: (value.casefold(), value)):
                encoded = relative.encode("utf-8")
                expected.update(len(encoded).to_bytes(8, "big"))
                expected.update(encoded)
                expected.update(hashlib.sha256(files[relative]).digest())

            self.assertEqual(tree_digest(root), (expected.hexdigest(), len(files)))


if __name__ == "__main__":
    unittest.main()
