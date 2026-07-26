#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.ci import package_prebuilt


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value) + "\n", encoding="utf-8")


class PackagePrebuiltContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.dist = Path(self.temporary.name) / "canvas"
        (self.dist / "bin").mkdir(parents=True)
        (self.dist / "bin" / "canvas.dll").write_bytes(b"canvas")
        self.metadata = self.dist / "metadata"
        write_json(
            self.metadata / "build-info.json",
            {
                "component": "canvas",
                "requestedTarget": "windows-x86_64",
                "source": {
                    "revision": "a" * 40,
                    "dirty": False,
                },
                "chromiumProfileSha256": "b" * 64,
                "toolchainManifestSha256": "c" * 64,
            },
        )
        write_json(
            self.metadata / "test-results.json",
            {
                "component": "canvas",
                "requestedTarget": "windows-x86_64",
                "status": "passed",
            },
        )
        self.rewrite_checksums()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def rewrite_checksums(self) -> None:
        checksum = self.metadata / "SHA256SUMS"
        lines = []
        for path in sorted(self.dist.rglob("*")):
            if path.is_file() and path != checksum:
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                lines.append(
                    f"{digest}  {path.relative_to(self.dist).as_posix()}"
                )
        checksum.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def test_clean_component_metadata_is_embedded(self) -> None:
        _, record = package_prebuilt.verified_component_metadata(
            "canvas",
            self.dist,
            "windows-x86_64",
        )
        self.assertEqual(record["revision"], "a" * 40)
        self.assertEqual(record["chromiumProfileSha256"], "b" * 64)
        self.assertEqual(record["toolchainManifestSha256"], "c" * 64)

    def test_dirty_source_is_rejected(self) -> None:
        path = self.metadata / "build-info.json"
        value = json.loads(path.read_text(encoding="utf-8"))
        value["source"]["dirty"] = True
        write_json(path, value)
        self.rewrite_checksums()
        with self.assertRaisesRegex(SystemExit, "no clean 40-character"):
            package_prebuilt.verified_component_metadata(
                "canvas",
                self.dist,
                "windows-x86_64",
            )

    def test_target_mismatch_is_rejected(self) -> None:
        with self.assertRaisesRegex(SystemExit, "target mismatch"):
            package_prebuilt.verified_component_metadata(
                "canvas",
                self.dist,
                "linux-x86_64",
            )

    def test_component_target_inference(self) -> None:
        self.assertEqual(
            package_prebuilt.component_target(
                "windows",
                "x86_64-windows-msvc",
            ),
            "windows-x86_64",
        )
        self.assertEqual(
            package_prebuilt.component_target(
                "linux",
                "x86_64-linux-gnu",
            ),
            "linux-x86_64",
        )

    def test_target_traversal_is_rejected(self) -> None:
        with self.assertRaisesRegex(SystemExit, "invalid package target syntax"):
            package_prebuilt.component_target(
                "windows",
                "x86_64/../../victim",
            )

    def test_unconfigured_target_is_rejected(self) -> None:
        with self.assertRaisesRegex(SystemExit, "unsupported package platform/target"):
            package_prebuilt.component_target(
                "linux",
                "aarch64-linux-gnu",
            )

    def test_output_symlink_escape_is_rejected(self) -> None:
        output = Path(self.temporary.name) / "output"
        outside = Path(self.temporary.name) / "outside"
        output.mkdir()
        outside.mkdir()
        link = output / "darkpanda-version-target"
        try:
            link.symlink_to(outside, target_is_directory=True)
        except OSError as error:
            self.skipTest(f"directory symlinks unavailable: {error}")
        with self.assertRaisesRegex(SystemExit, "escapes output directory"):
            package_prebuilt.direct_output_path(output.resolve(), link.name)

    def test_elf_dependency_contract_accepts_packaged_origin_library(self) -> None:
        bin_dir = Path(self.temporary.name) / "runtime" / "bin"
        bin_dir.mkdir(parents=True)
        binary = bin_dir / "libdarkpanda.so"
        dependency = bin_dir / "libcanvas.so"
        binary.write_bytes(b"binary")
        dependency.write_bytes(b"dependency")
        dynamic = (
            " 0x0000000000000001 (NEEDED) Shared library: [libcanvas.so]\n"
            " 0x000000000000001d (RUNPATH) Library runpath: [$ORIGIN]\n"
        )
        linked = f"libcanvas.so => {dependency} (0x00000000)\n"

        report = package_prebuilt.validate_elf_dependency_contract(
            binary=binary,
            dynamic=dynamic,
            linked=linked,
            bundled={"libcanvas.so": dependency},
        )

        self.assertEqual(report["needed"], ["libcanvas.so"])
        self.assertEqual(report["runtimePaths"], ["$ORIGIN"])
        encoded = json.dumps(report)
        self.assertNotIn(str(dependency), encoded)
        self.assertNotIn("0x", encoded)

    def test_elf_dependency_contract_rejects_absolute_runpath(self) -> None:
        binary = Path(self.temporary.name) / "libdarkpanda.so"
        dependency = Path(self.temporary.name) / "libcanvas.so"
        binary.write_bytes(b"binary")
        dependency.write_bytes(b"dependency")
        dynamic = (
            " 0x0000000000000001 (NEEDED) Shared library: [libcanvas.so]\n"
            " 0x000000000000001d (RUNPATH) Library runpath: [/tmp/build]\n"
        )
        with self.assertRaisesRegex(SystemExit, r"must be \$ORIGIN-relative"):
            package_prebuilt.validate_elf_dependency_contract(
                binary=binary,
                dynamic=dynamic,
                linked=f"libcanvas.so => {dependency} (0x0)\n",
                bundled={"libcanvas.so": dependency},
            )

    def test_elf_dependency_contract_rejects_unlisted_host_library(self) -> None:
        binary = Path(self.temporary.name) / "libdarkpanda.so"
        binary.write_bytes(b"binary")
        dynamic = (
            " 0x0000000000000001 (NEEDED) "
            "Shared library: [libfrom-runner-workspace.so]\n"
        )
        with self.assertRaisesRegex(SystemExit, "outside the runtime allowlist"):
            package_prebuilt.validate_elf_dependency_contract(
                binary=binary,
                dynamic=dynamic,
                linked="",
                bundled={},
            )

    def test_archive_extraction_rejects_parent_traversal(self) -> None:
        archive = Path(self.temporary.name) / "runtime.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("../escape", b"forbidden")
        destination = Path(self.temporary.name) / "extracted"
        with self.assertRaisesRegex(ValueError, "unsafe archive member"):
            package_prebuilt.extract_runtime_archive(
                archive,
                destination,
                "runtime",
            )
        self.assertFalse((Path(self.temporary.name) / "escape").exists())

    def test_archive_extraction_rejects_windows_drives_and_ads(self) -> None:
        for kind in ("zip", "tar"):
            for index, member in enumerate(("C:/escape", "root/file:stream")):
                with self.subTest(kind=kind, member=member):
                    suffix = ".zip" if kind == "zip" else ".tar.gz"
                    archive = (
                        Path(self.temporary.name)
                        / f"unsafe-{kind}-{index}{suffix}"
                    )
                    if kind == "zip":
                        with zipfile.ZipFile(archive, "w") as output:
                            output.writestr(member, b"forbidden")
                    else:
                        with tarfile.open(archive, "w:gz") as output:
                            info = tarfile.TarInfo(member)
                            info.size = len(b"forbidden")
                            output.addfile(info, io.BytesIO(b"forbidden"))
                    destination = (
                        Path(self.temporary.name) / f"extract-{kind}-{index}"
                    )
                    with self.assertRaisesRegex(
                        ValueError, "unsafe archive member"
                    ):
                        package_prebuilt.extract_runtime_archive(
                            archive,
                            destination,
                            "root",
                        )

    def test_deterministic_archive_writers_repeat_exact_sha256(self) -> None:
        root = Path(self.temporary.name) / "payload"
        root.mkdir()
        (root / "file.txt").write_text("deterministic\n", encoding="utf-8")
        epoch = 1_700_000_000
        for kind in ("zip", "tar"):
            first = Path(self.temporary.name) / f"first.{kind}"
            second = Path(self.temporary.name) / f"second.{kind}"
            if kind == "zip":
                package_prebuilt.create_zip(root, first, epoch)
                package_prebuilt.create_zip(root, second, epoch)
            else:
                package_prebuilt.create_tar_gz(root, first, epoch)
                package_prebuilt.create_tar_gz(root, second, epoch)
            self.assertEqual(
                package_prebuilt.sha256(first),
                package_prebuilt.sha256(second),
            )

    def test_windows_import_contract_allows_only_api_set_or_system32(self) -> None:
        root = Path(self.temporary.name)
        system32 = root / "Windows" / "System32"
        system32.mkdir(parents=True)
        (system32 / "kernel32.dll").write_bytes(b"system")
        binary = root / "darkpanda.exe"
        binary.write_bytes(b"binary")

        report = package_prebuilt.validate_windows_dependency_contract(
            binary=binary,
            imports=["api-ms-win-core-file-l1-1-0.dll", "kernel32.dll"],
            bundled_names=set(),
            system32=system32,
        )
        self.assertEqual(
            report["apiSetImports"],
            ["api-ms-win-core-file-l1-1-0.dll"],
        )
        self.assertEqual(report["system32Imports"], ["kernel32.dll"])

        with self.assertRaisesRegex(SystemExit, "neither packaged nor present"):
            package_prebuilt.validate_windows_dependency_contract(
                binary=binary,
                imports=["unknown.dll"],
                bundled_names=set(),
                system32=system32,
            )

        for unsafe in (r"C:\runner\foo.dll", r"..\foo.dll", "nested/foo.dll"):
            with self.subTest(unsafe=unsafe):
                with self.assertRaisesRegex(SystemExit, "plain DLL basenames"):
                    package_prebuilt.validate_windows_dependency_contract(
                        binary=binary,
                        imports=[unsafe],
                        bundled_names=set(),
                        system32=system32,
                    )

        (system32 / "vcruntime140.dll").write_bytes(b"system")
        with self.assertRaisesRegex(SystemExit, "unbundled Windows runtime"):
            package_prebuilt.validate_windows_dependency_contract(
                binary=binary,
                imports=["vcruntime140.dll"],
                bundled_names=set(),
                system32=system32,
            )

    def test_loader_environment_removes_all_injection_variables(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "LD_LIBRARY_PATH": "/build/lib",
                "LD_AUDIT": "/build/audit.so",
                "DYLD_INSERT_LIBRARIES": "/build/inject.dylib",
            },
            clear=False,
        ):
            environment = package_prebuilt.clean_loader_environment()
        self.assertFalse(
            any(name.startswith(("LD_", "DYLD_")) for name in environment)
        )


if __name__ == "__main__":
    unittest.main()
