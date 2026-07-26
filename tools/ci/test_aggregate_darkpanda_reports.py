#!/usr/bin/env python3

from __future__ import annotations

import gzip
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.ci import aggregate_darkpanda_reports


COMPONENTS = ("canvas", "html5ever", "wreq", "boringssl")
PROFILE_SHA = "a" * 64
TOOLCHAIN_MANIFEST_SHA = "b" * 64
V8_VERSION = "14.9.207.35"
V8_REVISION = "933ce636c562cd54d68e7f7c93ab5cdffd685fca"
ZIG_V8_REVISION = "a844a6300b048743cc3f82fd3e609e3d568a73c0"
ZIG_VERSION = "0.15.2"
TARGETS = {
    "windows-x86_64": {
        "platform": "windows",
        "zig_target": "x86_64-windows-msvc",
        "suffix": ".zip",
        "runtime": (
            "darkpanda.exe",
            "darkpanda.dll",
            "wreq.dll",
            "canvas.dll",
            "html5ever.dll",
            "msvcp140.dll",
            "vcruntime140.dll",
            "vcruntime140_1.dll",
        ),
    },
    "linux-x86_64": {
        "platform": "linux",
        "zig_target": "x86_64-linux-gnu",
        "suffix": ".tar.gz",
        "runtime": (
            "darkpanda",
            "libdarkpanda.so",
            "libwreq.so",
            "libcanvas.so",
            "libhtml5ever.so",
        ),
    },
}
STEPS = (
    "sourceContract",
    "installZig",
    "v8Build",
    "v8Verify",
    "install",
    "package",
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def encode_json(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True) + "\n").encode()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(encode_json(value))


class AggregateDarkPandaReportsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.results = self.root / "results"
        self.release = self.root / "release"
        self.revisions = {
            name: f"{index + 1:x}" * 40 for index, name in enumerate(COMPONENTS)
        }
        self.darkpanda_revision = "d" * 40
        self.resolved = self.root / "resolved-inputs.json"
        write_json(
            self.resolved,
            {
                "schema": "darkpanda-resolved-inputs/v4",
                "darkpanda": {"revision": self.darkpanda_revision},
                "browserProfile": {"profileSha256": PROFILE_SHA},
                "buildDependencies": {
                    "zig": {
                        "version": ZIG_VERSION,
                        "sha256": {
                            "windows-x86_64": "c" * 64,
                            "linux-x86_64": "e" * 64,
                        },
                    },
                    "v8": {
                        "version": V8_VERSION,
                        "revision": V8_REVISION,
                        "zigV8": {
                            "repository": "AeroidesLab/zig-v8-fork",
                            "revision": ZIG_V8_REVISION,
                        },
                    },
                },
                "components": {
                    name: {"revision": revision}
                    for name, revision in self.revisions.items()
                },
            },
        )
        for target_id in TARGETS:
            self.make_platform(target_id)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_platform(self, target_id: str) -> None:
        target = TARGETS[target_id]
        result = self.results / f"darkpanda-result-{target_id}"
        reports = result / "reports"
        reports.mkdir(parents=True)

        package_dir = result / "prebuilt" / target_id
        package_dir.mkdir(parents=True)
        archive_name = f"darkpanda-1.0.0-{target['zig_target']}{target['suffix']}"
        archive_path = package_dir / archive_name
        package_sha = self.make_archive(archive_path, target_id)
        (package_dir / f"{archive_name}.sha256").write_text(
            f"{package_sha}  {archive_name}\n", encoding="utf-8"
        )
        package_attestation_path = (
            reports / f"packaged-runtime-{target_id}.json"
        )
        packaged_paths = {
            "windows": {
                "ffi": "bin/darkpanda.dll",
                "wreq": "bin/wreq.dll",
                "canvas": "bin/canvas.dll",
                "html5ever": "bin/html5ever.dll",
            },
            "linux": {
                "ffi": "bin/libdarkpanda.so",
                "wreq": "bin/libwreq.so",
                "canvas": "bin/libcanvas.so",
                "html5ever": "bin/libhtml5ever.so",
            },
        }[str(target["platform"])]
        write_json(
            package_attestation_path,
            {
                "schema": "darkpanda-packaged-runtime-attestation/v1",
                "status": "PASS",
                "archive": archive_name,
                "archiveSha256": package_sha,
                "extractedRoot": archive_name[: -len(str(target["suffix"]))],
                "cleanEnvironment": True,
                "loaderPolicy": (
                    "archive-bin-plus-windows-system"
                    if target["platform"] == "windows"
                    else "elf-origin-plus-system"
                ),
                "cliVersionOutput": "DarkPanda 1.0.0",
                "loadedLibraries": (
                    [
                        "bin/darkpanda.dll",
                        "bin/wreq.dll",
                        "bin/canvas.dll",
                        "bin/html5ever.dll",
                    ]
                    if target["platform"] == "windows"
                    else [
                        "bin/libdarkpanda.so",
                        "bin/libwreq.so",
                        "bin/libcanvas.so",
                        "bin/libhtml5ever.so",
                    ]
                ),
                "runtime": {
                    "schema": "darkpanda-runtime-load-attestation/v1",
                    "status": "PASS",
                    "canvasAbiVersion": 5,
                    "loadedLibraries": list(packaged_paths.values()),
                    "paths": packaged_paths,
                },
            },
        )
        step_results = {name: "success" for name in STEPS}
        if target["platform"] == "windows":
            step_results["vcRuntime"] = "success"
        write_json(
            reports / f"darkpanda-{target_id}.json",
            {
                "schema": "darkpanda-platform-result/v2",
                "target": target_id,
                "platform": target["platform"],
                "status": "passed",
                "sourceRevision": self.darkpanda_revision,
                "chromiumProfileSha256": PROFILE_SHA,
                "resolvedInputsSha256": file_digest(self.resolved),
                "components": self.revisions,
                "v8Version": V8_VERSION,
                "v8Revision": V8_REVISION,
                "zigV8SourceRevision": ZIG_V8_REVISION,
                "steps": step_results,
                "reports": {
                    "packageRuntimeAttestationSha256": file_digest(
                        package_attestation_path
                    ),
                },
                "package": {"name": archive_name, "sha256": package_sha},
            },
        )

    def make_archive(self, archive_path: Path, target_id: str) -> str:
        target = TARGETS[target_id]
        root = archive_path.name[: -len(str(target["suffix"]))]
        files: dict[str, bytes] = {
            f"bin/{name}": f"{target_id}:{name}".encode()
            for name in target["runtime"]
        }
        dependency_records = {}
        for name in target["runtime"]:
            if target["platform"] == "windows":
                dependency_records[name] = {
                    "peImports": [],
                    "bundledImports": [],
                    "apiSetImports": [],
                    "system32Imports": [],
                }
            else:
                dependency_records[name] = {
                    "needed": [],
                    "bundledNeeded": [],
                    "operatingSystemNeeded": [],
                    "runtimePaths": [],
                }
        dependency_policy: dict[str, object] = {
            "archiveRuntimeNames": list(target["runtime"]),
        }
        if target["platform"] == "windows":
            dependency_policy["bundledVisualCRuntime"] = [
                name
                for name in target["runtime"]
                if name.startswith(("msvcp", "vcruntime", "concrt"))
            ]
            dependency_policy["operatingSystemImportPolicy"] = (
                "api-set-or-existing-system32-file"
            )
        else:
            dependency_policy.update(
                {
                    "neededAllowlist": sorted(
                        {
                            name
                            for name in target["runtime"]
                            if name.endswith(".so")
                        }
                        | {
                            "libc.so.6",
                            "libdl.so.2",
                            "libgcc_s.so.1",
                            "libm.so.6",
                            "libpthread.so.0",
                            "librt.so.1",
                            "libstdc++.so.6",
                        }
                    ),
                    "runtimePathPolicy": "$ORIGIN-relative-only",
                    "systemLibraryRoots": [
                        "/lib",
                        "/lib64",
                        "/usr/lib",
                        "/usr/lib64",
                    ],
                }
            )
        files["metadata/runtime-dependencies.json"] = encode_json(
            {
                "schema": "darkpanda-runtime-dependencies/v2",
                "platform": target["platform"],
                "policy": dependency_policy,
                "binaries": dependency_records,
            }
        )
        component_records = {}
        for component in COMPONENTS:
            info = encode_json(
                {
                    "schema": "darkpanda-component-build-info/v1",
                    "component": component,
                    "requestedTarget": target_id,
                    "source": {
                        "revision": self.revisions[component],
                        "dirty": False,
                    },
                    "chromiumProfileSha256": PROFILE_SHA,
                    "toolchainManifestSha256": TOOLCHAIN_MANIFEST_SHA,
                }
            )
            path = f"metadata/components/{component}/build-info.json"
            files[path] = info
            files[f"metadata/components/{component}/test-results.json"] = encode_json(
                {"component": component, "status": "passed"}
            )
            component_records[component] = {
                "target": target_id,
                "revision": self.revisions[component],
                "chromiumProfileSha256": PROFILE_SHA,
                "toolchainManifestSha256": TOOLCHAIN_MANIFEST_SHA,
                "buildInfoSha256": digest(info),
            }
        files["BUILD-INFO.json"] = encode_json(
            {
                "schema": "darkpanda-prebuilt-runtime/v1",
                "version": "1.0.0",
                "platform": target["platform"],
                "target": target["zig_target"],
                "source": {"revision": self.darkpanda_revision},
                "dependencies": {
                    "v8Version": V8_VERSION,
                    "v8Revision": V8_REVISION,
                    "zigV8SourceRevision": ZIG_V8_REVISION,
                    "boringSslSourceRevision": self.revisions["boringssl"],
                    "components": component_records,
                },
                "runtimeClosure": list(target["runtime"]),
            }
        )
        files["SHA256SUMS"] = "".join(
            f"{digest(data)}  {name}\n"
            for name, data in sorted(files.items())
        ).encode()

        if target["platform"] == "windows":
            with zipfile.ZipFile(
                archive_path, "w", compression=zipfile.ZIP_DEFLATED
            ) as archive:
                for name, data in sorted(files.items()):
                    archive.writestr(f"{root}/{name}", data)
        else:
            with archive_path.open("wb") as raw:
                with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as compressed:
                    with tarfile.open(fileobj=compressed, mode="w") as archive:
                        for name, data in sorted(files.items()):
                            info = tarfile.TarInfo(f"{root}/{name}")
                            info.size = len(data)
                            info.mode = 0o644
                            archive.addfile(info, io.BytesIO(data))
        return file_digest(archive_path)

    def run_validator(self) -> subprocess.CompletedProcess[str]:
        script = Path(__file__).with_name("aggregate_darkpanda_reports.py")
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
                "--release-dir",
                str(self.release),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_two_complete_platforms_pass(self) -> None:
        completed = self.run_validator()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        summary = json.loads((self.root / "summary.json").read_text())
        self.assertEqual(summary["status"], "passed")
        self.assertEqual(set(summary["platforms"]), set(TARGETS))
        self.assertTrue((self.release / "SHA256SUMS").is_file())
        self.assertEqual(
            len(list(self.release.glob("*.sha256"))),
            2,
        )

    def test_bad_package_checksum_still_writes_failure_summary(self) -> None:
        checksum = next(
            (
                self.results
                / "darkpanda-result-linux-x86_64"
                / "prebuilt"
                / "linux-x86_64"
            ).glob("*.sha256")
        )
        checksum.write_text(f"{'0' * 64}  {checksum.name[:-7]}\n", encoding="utf-8")
        completed = self.run_validator()
        self.assertNotEqual(completed.returncode, 0)
        summary = json.loads((self.root / "summary.json").read_text())
        self.assertEqual(summary["status"], "failed")
        self.assertIn("external archive checksum mismatch", "\n".join(summary["errors"]))

    def test_incomplete_runtime_load_proof_fails(self) -> None:
        target_id = "linux-x86_64"
        result = self.results / f"darkpanda-result-{target_id}"
        attestation = (
            result / "reports" / f"packaged-runtime-{target_id}.json"
        )
        payload = json.loads(attestation.read_text(encoding="utf-8"))
        del payload["runtime"]["paths"]["html5ever"]
        write_json(attestation, payload)
        platform = result / "reports" / f"darkpanda-{target_id}.json"
        platform_payload = json.loads(platform.read_text(encoding="utf-8"))
        platform_payload["reports"]["packageRuntimeAttestationSha256"] = (
            file_digest(attestation)
        )
        write_json(platform, platform_payload)

        completed = self.run_validator()
        self.assertNotEqual(completed.returncode, 0)
        summary = json.loads((self.root / "summary.json").read_text())
        self.assertEqual(summary["status"], "failed")
        self.assertIn(
            "packaged runtime attestation",
            "\n".join(summary["errors"]),
        )

    def test_packaged_runtime_must_use_clean_loader_policy(self) -> None:
        target_id = "linux-x86_64"
        result = self.results / f"darkpanda-result-{target_id}"
        attestation = (
            result / "reports" / f"packaged-runtime-{target_id}.json"
        )
        payload = json.loads(attestation.read_text(encoding="utf-8"))
        payload["loaderPolicy"] = "inherited-build-environment"
        write_json(attestation, payload)
        platform = result / "reports" / f"darkpanda-{target_id}.json"
        platform_payload = json.loads(platform.read_text(encoding="utf-8"))
        platform_payload["reports"]["packageRuntimeAttestationSha256"] = (
            file_digest(attestation)
        )
        write_json(platform, platform_payload)

        completed = self.run_validator()
        self.assertNotEqual(completed.returncode, 0)
        summary = json.loads((self.root / "summary.json").read_text())
        self.assertEqual(summary["status"], "failed")
        self.assertIn(
            "packaged runtime attestation",
            "\n".join(summary["errors"]),
        )

    def test_archive_reader_rejects_windows_drive_and_ads_names(self) -> None:
        for name in ("C:/escape", "root/file:stream", r"\\server\share\file"):
            with self.subTest(name=name):
                with self.assertRaisesRegex(ValueError, "unsafe archive path"):
                    aggregate_darkpanda_reports.safe_relative(name)

    def test_aggregate_rejects_vc_runtime_forged_as_system32(self) -> None:
        target = TARGETS["windows-x86_64"]
        records = {
            name: {
                "peImports": [],
                "bundledImports": [],
                "apiSetImports": [],
                "system32Imports": [],
            }
            for name in target["runtime"]
        }
        records["darkpanda.exe"] = {
            "peImports": ["vcruntime140.dll"],
            "bundledImports": [],
            "apiSetImports": [],
            "system32Imports": ["vcruntime140.dll"],
        }
        payload = encode_json(
            {
                "schema": "darkpanda-runtime-dependencies/v2",
                "platform": "windows",
                "policy": {
                    "archiveRuntimeNames": list(target["runtime"]),
                    "bundledVisualCRuntime": [
                        "msvcp140.dll",
                        "vcruntime140.dll",
                        "vcruntime140_1.dll",
                    ],
                    "operatingSystemImportPolicy": (
                        "api-set-or-existing-system32-file"
                    ),
                },
                "binaries": records,
            }
        )

        class FakeArchive:
            def read(self, _name: str) -> bytes:
                return payload

        with self.assertRaisesRegex(ValueError, "Windows dependency closure"):
            aggregate_darkpanda_reports.validate_dependency_manifest(
                FakeArchive(),  # type: ignore[arg-type]
                "root",
                target,
            )

    def test_aggregate_rejects_non_basename_pe_import(self) -> None:
        target = TARGETS["windows-x86_64"]
        records = {
            name: {
                "peImports": [],
                "bundledImports": [],
                "apiSetImports": [],
                "system32Imports": [],
            }
            for name in target["runtime"]
        }
        escaped = r"C:\runner\foo.dll"
        records["darkpanda.exe"] = {
            "peImports": [escaped],
            "bundledImports": [],
            "apiSetImports": [],
            "system32Imports": [escaped],
        }
        payload = encode_json(
            {
                "schema": "darkpanda-runtime-dependencies/v2",
                "platform": "windows",
                "policy": {
                    "archiveRuntimeNames": list(target["runtime"]),
                    "bundledVisualCRuntime": [
                        "msvcp140.dll",
                        "vcruntime140.dll",
                        "vcruntime140_1.dll",
                    ],
                    "operatingSystemImportPolicy": (
                        "api-set-or-existing-system32-file"
                    ),
                },
                "binaries": records,
            }
        )

        class FakeArchive:
            def read(self, _name: str) -> bytes:
                return payload

        with self.assertRaisesRegex(ValueError, "Windows dependency closure"):
            aggregate_darkpanda_reports.validate_dependency_manifest(
                FakeArchive(),  # type: ignore[arg-type]
                "root",
                target,
            )


if __name__ == "__main__":
    unittest.main()
