#!/usr/bin/env python3
"""Validate the two DarkPanda runtime builds and assemble the final archive set."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath, PureWindowsPath
import re
import shutil
import tarfile
import zipfile
from typing import BinaryIO, Callable


SCHEMA = "darkpanda-platform-result/v2"
SUMMARY_SCHEMA = "darkpanda-prebuilt-aggregate/v1"
COMPONENTS = ("canvas", "html5ever", "wreq", "boringssl")
LINUX_OS_NEEDED = frozenset(
    {
        "ld-linux-x86-64.so.2",
        "libc.so.6",
        "libdl.so.2",
        "libgcc_s.so.1",
        "libm.so.6",
        "libpthread.so.0",
        "librt.so.1",
        "libstdc++.so.6",
    }
)
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
COMMON_STEPS = (
    "sourceContract",
    "installZig",
    "v8Build",
    "v8Verify",
    "install",
    "package",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stream_sha256(stream: BinaryIO) -> str:
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON root is not an object: {path}")
    return value


def build_dependency_values(resolved: dict[str, object]) -> dict[str, str]:
    build = resolved.get("buildDependencies")
    if not isinstance(build, dict):
        raise ValueError("resolved inputs have no buildDependencies object")
    zig = build.get("zig")
    v8 = build.get("v8")
    if not isinstance(zig, dict) or not isinstance(v8, dict):
        raise ValueError("resolved Zig/V8 dependency records are incomplete")
    zig_sha = zig.get("sha256")
    zig_v8 = v8.get("zigV8")
    if not isinstance(zig_sha, dict) or not isinstance(zig_v8, dict):
        raise ValueError("resolved Zig archive or zig-v8 record is incomplete")
    prebuilt = zig_v8.get("prebuilt")
    if not isinstance(prebuilt, dict):
        raise ValueError("resolved zig-v8 record has no prebuilt entry")
    prebuilt_assets = prebuilt.get("assets")
    if not isinstance(prebuilt_assets, dict):
        raise ValueError("resolved zig-v8 prebuilt record has no assets")
    prebuilt_linux = prebuilt_assets.get("linux-x86_64")
    if not isinstance(prebuilt_linux, dict):
        raise ValueError("resolved zig-v8 prebuilt record has no Linux asset")
    result = {
        "zigVersion": zig.get("version"),
        "zigWindowsSha256": zig_sha.get("windows-x86_64"),
        "zigLinuxSha256": zig_sha.get("linux-x86_64"),
        "v8Version": v8.get("version"),
        "v8Revision": v8.get("revision"),
        "zigV8Repository": zig_v8.get("repository"),
        "zigV8Revision": zig_v8.get("revision"),
        "zigV8PrebuiltRepository": prebuilt.get("repository"),
        "zigV8PrebuiltRelease": prebuilt.get("release"),
        "zigV8PrebuiltLinuxAsset": prebuilt_linux.get("name"),
        "zigV8PrebuiltLinuxSha256": prebuilt_linux.get("sha256"),
    }
    if (
        any(not isinstance(value, str) or not value for value in result.values())
        or result["zigV8Repository"] != "AeroidesLab/zig-v8-fork"
        or result["zigV8PrebuiltRepository"] != "lightpanda-io/zig-v8-fork"
        or not re.fullmatch(r"[0-9a-f]{40}", result["v8Revision"])
        or not re.fullmatch(r"[0-9a-f]{40}", result["zigV8Revision"])
        or not re.fullmatch(
            r"v[0-9]+\.[0-9]+\.[0-9]+", result["zigV8PrebuiltRelease"]
        )
        or result["zigV8PrebuiltLinuxAsset"]
        != f"libc_v8_{result['v8Version']}_linux_x86_64.a"
        or not re.fullmatch(r"[0-9a-f]{64}", result["zigV8PrebuiltLinuxSha256"])
        or not re.fullmatch(r"[0-9a-f]{64}", result["zigWindowsSha256"])
        or not re.fullmatch(r"[0-9a-f]{64}", result["zigLinuxSha256"])
    ):
        raise ValueError("resolved Zig/V8 dependency values are invalid")
    return result  # type: ignore[return-value]


def safe_relative(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    windows = PureWindowsPath(name)
    if (
        not name
        or path.is_absolute()
        or windows.is_absolute()
        or bool(windows.drive)
        or bool(windows.root)
        or ".." in path.parts
        or "\\" in name
        or any(":" in part for part in path.parts)
        or any(part in ("", ".") for part in path.parts)
    ):
        raise ValueError(f"unsafe archive path: {name!r}")
    return path


class RuntimeArchive:
    """Small uniform reader for ZIP and tar.gz runtime packages."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._close: Callable[[], None]
        self._open: Callable[[str], BinaryIO]
        self.files: dict[str, object] = {}
        self.directories: set[str] = set()

        if path.name.endswith(".zip"):
            archive = zipfile.ZipFile(path)
            self._close = archive.close
            for info in archive.infolist():
                relative = safe_relative(info.filename.rstrip("/"))
                name = relative.as_posix()
                if info.is_dir():
                    self.directories.add(name)
                    continue
                mode = (info.external_attr >> 16) & 0xF000
                if mode == 0xA000:
                    archive.close()
                    raise ValueError(f"ZIP symlink is forbidden: {name}")
                if name in self.files:
                    archive.close()
                    raise ValueError(f"duplicate ZIP member: {name}")
                self.files[name] = info
            self._open = lambda name: archive.open(self.files[name])  # type: ignore[arg-type]
        elif path.name.endswith(".tar.gz"):
            archive = tarfile.open(path, mode="r:gz")
            self._close = archive.close
            for member in archive.getmembers():
                relative = safe_relative(member.name.rstrip("/"))
                name = relative.as_posix()
                if member.isdir():
                    self.directories.add(name)
                    continue
                if not member.isfile():
                    archive.close()
                    raise ValueError(f"non-regular tar member is forbidden: {name}")
                if name in self.files:
                    archive.close()
                    raise ValueError(f"duplicate tar member: {name}")
                self.files[name] = member

            def open_tar(name: str) -> BinaryIO:
                stream = archive.extractfile(self.files[name])  # type: ignore[arg-type]
                if stream is None:
                    raise ValueError(f"could not read tar member: {name}")
                return stream

            self._open = open_tar
        else:
            raise ValueError(f"unsupported runtime archive: {path.name}")

    def close(self) -> None:
        self._close()

    def read(self, name: str) -> bytes:
        if name not in self.files:
            raise ValueError(f"archive member is missing: {name}")
        with self._open(name) as stream:
            return stream.read()

    def member_sha256(self, name: str) -> str:
        if name not in self.files:
            raise ValueError(f"archive member is missing: {name}")
        with self._open(name) as stream:
            return stream_sha256(stream)


def component_revision(build_info: dict[str, object]) -> str:
    source = build_info.get("source")
    if isinstance(source, dict) and isinstance(source.get("revision"), str):
        return source["revision"]
    revision = build_info.get("canvasRevision")
    return revision if isinstance(revision, str) else ""


def parse_checksum(path: Path, expected_name: str) -> str:
    lines = path.read_text(encoding="utf-8").splitlines()
    if len(lines) != 1:
        raise ValueError(f"archive checksum must contain exactly one line: {path}")
    digest, separator, name = lines[0].partition("  ")
    if (
        not separator
        or not re.fullmatch(r"[0-9a-f]{64}", digest)
        or name != expected_name
    ):
        raise ValueError(f"invalid archive checksum line: {path}")
    return digest


def validate_internal_checksums(archive: RuntimeArchive, root: str) -> None:
    checksum_name = f"{root}/SHA256SUMS"
    lines = archive.read(checksum_name).decode("utf-8").splitlines()
    declared: dict[str, str] = {}
    for number, line in enumerate(lines, start=1):
        digest, separator, relative_name = line.partition("  ")
        if (
            not separator
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
            or relative_name in declared
        ):
            raise ValueError(f"invalid internal checksum line {number}: {line!r}")
        relative = safe_relative(relative_name)
        member = f"{root}/{relative.as_posix()}"
        if member == checksum_name or member not in archive.files:
            raise ValueError(f"invalid internal checksum target: {relative_name!r}")
        declared[relative_name] = digest

    actual = {
        name[len(root) + 1 :]
        for name in archive.files
        if name.startswith(f"{root}/") and name != checksum_name
    }
    if set(declared) != actual:
        raise ValueError("internal SHA256SUMS does not cover the complete package payload")
    for relative_name, expected in declared.items():
        actual_digest = archive.member_sha256(f"{root}/{relative_name}")
        if actual_digest != expected:
            raise ValueError(f"internal checksum mismatch: {relative_name}")


def valid_origin_runtime_path(value: str) -> bool:
    match = re.fullmatch(r"\$(?:\{ORIGIN\}|ORIGIN)(?:/(.*))?", value)
    if match is None:
        return False
    suffix = match.group(1)
    if suffix is None or suffix == "":
        return True
    relative = PurePosixPath(suffix)
    return (
        not relative.is_absolute()
        and ".." not in relative.parts
        and all(part not in ("", ".") for part in relative.parts)
    )


def valid_windows_dll_name(name: str) -> bool:
    windows = PureWindowsPath(name)
    return (
        windows.name == name
        and not windows.drive
        and not windows.root
        and not any(character in name for character in ("/", "\\", ":"))
        and name not in ("", ".", "..")
        and name.endswith(".dll")
    )


def validate_dependency_manifest(
    archive: RuntimeArchive,
    root: str,
    target: dict[str, object],
) -> None:
    member = f"{root}/metadata/runtime-dependencies.json"
    manifest = json.loads(archive.read(member))
    if not isinstance(manifest, dict):
        raise ValueError("runtime-dependencies.json root is not an object")
    policy = manifest.get("policy")
    binaries = manifest.get("binaries")
    runtime = tuple(target["runtime"])  # type: ignore[arg-type]
    if (
        manifest.get("schema") != "darkpanda-runtime-dependencies/v2"
        or manifest.get("platform") != target["platform"]
        or not isinstance(policy, dict)
        or not isinstance(binaries, dict)
        or set(binaries) != set(runtime)
        or policy.get("archiveRuntimeNames") != list(runtime)
    ):
        raise ValueError("runtime dependency manifest does not cover the exact archive")

    platform = target["platform"]
    if platform == "linux":
        bundled = {name for name in runtime if name.endswith(".so")}
        allowlist = bundled | LINUX_OS_NEEDED
        if (
            policy.get("neededAllowlist") != sorted(allowlist)
            or policy.get("runtimePathPolicy") != "$ORIGIN-relative-only"
        ):
            raise ValueError("Linux dependency manifest policy is not strict")
        for binary_name, value in binaries.items():
            if not isinstance(value, dict):
                raise ValueError(f"invalid Linux dependency record: {binary_name}")
            needed = value.get("needed")
            bundled_needed = value.get("bundledNeeded")
            system_needed = value.get("operatingSystemNeeded")
            runtime_paths = value.get("runtimePaths")
            if (
                set(value)
                != {
                    "needed",
                    "bundledNeeded",
                    "operatingSystemNeeded",
                    "runtimePaths",
                }
                or not isinstance(needed, list)
                or not all(isinstance(name, str) for name in needed)
                or len(needed) != len(set(needed))
                or not set(needed) <= allowlist
                or bundled_needed
                != sorted(name for name in needed if name in bundled)
                or system_needed
                != sorted(name for name in needed if name in LINUX_OS_NEEDED)
                or not isinstance(runtime_paths, list)
                or not all(
                    isinstance(path, str) and valid_origin_runtime_path(path)
                    for path in runtime_paths
                )
            ):
                raise ValueError(
                    f"Linux dependency closure is not portable: {binary_name}"
                )
    elif platform == "windows":
        visual_c = [
            name
            for name in runtime
            if name.startswith(("msvcp", "vcruntime", "concrt"))
        ]
        if (
            policy.get("bundledVisualCRuntime") != visual_c
            or policy.get("operatingSystemImportPolicy")
            != "api-set-or-existing-system32-file"
        ):
            raise ValueError("Windows dependency manifest does not bundle the VC runtime")
        runtime_lower = {name.lower() for name in runtime}
        for binary_name, value in binaries.items():
            if not isinstance(value, dict):
                raise ValueError(f"invalid PE dependency record: {binary_name}")
            imports = value.get("peImports")
            bundled_imports = value.get("bundledImports")
            api_set_imports = value.get("apiSetImports")
            system32_imports = value.get("system32Imports")
            if (
                set(value)
                != {
                    "peImports",
                    "bundledImports",
                    "apiSetImports",
                    "system32Imports",
                }
                or not isinstance(imports, list)
                or not all(isinstance(name, str) for name in imports)
                or not all(valid_windows_dll_name(name) for name in imports)
                or len(imports) != len(set(imports))
                or not isinstance(api_set_imports, list)
                or not isinstance(system32_imports, list)
                or bundled_imports
                != sorted(name for name in imports if name in runtime_lower)
                or api_set_imports
                != sorted(
                    name
                    for name in imports
                    if name not in runtime_lower
                    and name.startswith(("api-ms-win-", "ext-ms-win-"))
                )
                or system32_imports
                != sorted(
                    name
                    for name in imports
                    if name not in runtime_lower
                    and not name.startswith(("api-ms-win-", "ext-ms-win-"))
                )
                or any(
                    name.startswith(
                        (
                            "msvcp",
                            "vcruntime",
                            "concrt",
                            "darkpanda",
                            "wreq",
                            "canvas",
                            "html5ever",
                        )
                    )
                    for name in (api_set_imports or []) + (system32_imports or [])
                )
            ):
                raise ValueError(f"Windows dependency closure is invalid: {binary_name}")


def validate_packaged_runtime_attestation(
    *,
    report: dict[str, object],
    target: dict[str, object],
    archive_path: Path,
) -> None:
    suffix = str(target["suffix"])
    root = archive_path.name[: -len(suffix)]
    runtime_names = {
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
    loaded_libraries = {
        "windows": [
            "bin/darkpanda.dll",
            "bin/wreq.dll",
            "bin/canvas.dll",
            "bin/html5ever.dll",
        ],
        "linux": [
            "bin/libdarkpanda.so",
            "bin/libwreq.so",
            "bin/libcanvas.so",
            "bin/libhtml5ever.so",
        ],
    }[str(target["platform"])]
    runtime = report.get("runtime")
    expected_policy = (
        "archive-bin-plus-windows-system"
        if target["platform"] == "windows"
        else "elf-origin-plus-system"
    )
    if (
        report.get("schema") != "darkpanda-packaged-runtime-attestation/v1"
        or report.get("status") != "PASS"
        or report.get("archive") != archive_path.name
        or report.get("archiveSha256") != sha256(archive_path)
        or report.get("extractedRoot") != root
        or report.get("cleanEnvironment") is not True
        or report.get("loaderPolicy") != expected_policy
        or not isinstance(report.get("cliVersionOutput"), str)
        or not str(report["cliVersionOutput"]).strip()
        or report.get("loadedLibraries") != loaded_libraries
        or not isinstance(runtime, dict)
        or runtime.get("schema") != "darkpanda-runtime-load-attestation/v1"
        or runtime.get("status") != "PASS"
        or runtime.get("canvasAbiVersion") != 5
        or runtime.get("loadedLibraries") != loaded_libraries
        or runtime.get("paths") != runtime_names
    ):
        raise ValueError("packaged runtime attestation did not prove archive execution")


def validate_package(
    *,
    archive_path: Path,
    target_id: str,
    resolved: dict[str, object],
) -> dict[str, object]:
    target = TARGETS[target_id]
    fixed = build_dependency_values(resolved)
    archive = RuntimeArchive(archive_path)
    try:
        top_levels = {
            PurePosixPath(name).parts[0]
            for name in (*archive.files, *archive.directories)
        }
        if len(top_levels) != 1:
            raise ValueError("runtime archive must contain exactly one top-level directory")
        root = next(iter(top_levels))
        expected_stem = archive_path.name[: -len(str(target["suffix"]))]
        if root != expected_stem:
            raise ValueError(f"archive root {root!r} does not match {expected_stem!r}")

        validate_internal_checksums(archive, root)
        runtime = tuple(target["runtime"])
        packaged_bin = [
            name[len(f"{root}/bin/") :]
            for name in archive.files
            if name.startswith(f"{root}/bin/")
        ]
        if set(packaged_bin) != set(runtime) or any(
            "/" in name for name in packaged_bin
        ):
            raise ValueError("archive bin directory does not contain the exact runtime closure")
        validate_dependency_manifest(archive, root, target)
        build_info = json.loads(archive.read(f"{root}/BUILD-INFO.json"))
        if not isinstance(build_info, dict):
            raise ValueError("BUILD-INFO.json root is not an object")
        source = build_info.get("source")
        dependencies = build_info.get("dependencies")
        if not isinstance(source, dict) or not isinstance(dependencies, dict):
            raise ValueError("BUILD-INFO.json is missing source or dependency provenance")
        if (
            build_info.get("schema") != "darkpanda-prebuilt-runtime/v1"
            or build_info.get("platform") != target["platform"]
            or build_info.get("target") != target["zig_target"]
            or source.get("revision") != resolved["darkpanda"]["revision"]  # type: ignore[index]
            or dependencies.get("v8Version") != fixed["v8Version"]
            or dependencies.get("v8Revision") != fixed["v8Revision"]
            or dependencies.get("zigV8SourceRevision") != fixed["zigV8Revision"]
            or dependencies.get("boringSslSourceRevision")
            != resolved["components"]["boringssl"]["revision"]  # type: ignore[index]
        ):
            raise ValueError("BUILD-INFO.json does not match the resolved runtime inputs")
        if target["platform"] == "linux" and (
            dependencies.get("v8ArchiveSha256")
            != fixed["zigV8PrebuiltLinuxSha256"]
        ):
            raise ValueError("BUILD-INFO.json does not match the resolved runtime inputs")
        if tuple(build_info.get("runtimeClosure", ())) != target["runtime"]:
            raise ValueError("BUILD-INFO.json runtime closure is incomplete or out of order")
        packaged_components = dependencies.get("components")
        if not isinstance(packaged_components, dict) or set(packaged_components) != set(COMPONENTS):
            raise ValueError("BUILD-INFO.json does not contain all four components")

        component_manifest_sha: str | None = None
        for component in COMPONENTS:
            member = f"{root}/metadata/components/{component}/build-info.json"
            component_info = json.loads(archive.read(member))
            if not isinstance(component_info, dict):
                raise ValueError(f"{component} packaged build-info is not an object")
            requested_target = component_info.get(
                "requestedTarget", component_info.get("target")
            )
            component_source = component_info.get("source")
            manifest_sha = component_info.get("toolchainManifestSha256")
            if (
                component_info.get("component") != component
                or requested_target != target_id
                or not isinstance(component_source, dict)
                or component_source.get("dirty") is not False
                or component_revision(component_info)
                != resolved["components"][component]["revision"]  # type: ignore[index]
                or component_info.get("chromiumProfileSha256")
                != resolved["browserProfile"]["profileSha256"]  # type: ignore[index]
                or not isinstance(manifest_sha, str)
                or not re.fullmatch(r"[0-9a-f]{64}", manifest_sha)
            ):
                raise ValueError(f"packaged {component} provenance does not match the run")
            if component_manifest_sha is None:
                component_manifest_sha = manifest_sha
            elif component_manifest_sha != manifest_sha:
                raise ValueError("packaged components do not share one toolchain manifest")
            record = packaged_components.get(component)
            if (
                not isinstance(record, dict)
                or record.get("target") != target_id
                or record.get("revision")
                != resolved["components"][component]["revision"]  # type: ignore[index]
                or record.get("chromiumProfileSha256")
                != resolved["browserProfile"]["profileSha256"]  # type: ignore[index]
                or record.get("toolchainManifestSha256") != manifest_sha
                or record.get("buildInfoSha256") != archive.member_sha256(member)
            ):
                raise ValueError(f"packaged {component} metadata digest does not match")

        return {
            "archive": archive_path.name,
            "sha256": sha256(archive_path),
            "size": archive_path.stat().st_size,
            "version": build_info.get("version"),
        }
    finally:
        archive.close()


def validate_platform(
    *,
    root: Path,
    target_id: str,
    resolved: dict[str, object],
    resolved_sha: str,
    release_dir: Path,
) -> dict[str, object]:
    target = TARGETS[target_id]
    fixed = build_dependency_values(resolved)
    report_path = root / "reports" / f"darkpanda-{target_id}.json"
    report = load_json(report_path)
    if (
        report.get("schema") != SCHEMA
        or report.get("target") != target_id
        or report.get("platform") != target["platform"]
        or report.get("status") != "passed"
        or report.get("sourceRevision") != resolved["darkpanda"]["revision"]  # type: ignore[index]
        or report.get("chromiumProfileSha256")
        != resolved["browserProfile"]["profileSha256"]  # type: ignore[index]
        or report.get("resolvedInputsSha256") != resolved_sha
        or report.get("components")
        != {
            name: resolved["components"][name]["revision"]  # type: ignore[index]
            for name in COMPONENTS
        }
    ):
        raise ValueError(f"platform result does not match resolved inputs: {report_path}")
    if (
        report.get("v8Version") != fixed["v8Version"]
        or report.get("v8Revision") != fixed["v8Revision"]
        or report.get("zigV8SourceRevision") != fixed["zigV8Revision"]
    ):
        raise ValueError(f"platform V8 provenance is not fixed: {report_path}")

    prebuilt = report.get("zigV8Prebuilt")
    if target["platform"] == "linux":
        if not isinstance(prebuilt, dict) or prebuilt != {
            "release": fixed["zigV8PrebuiltRelease"],
            "archiveSha256": fixed["zigV8PrebuiltLinuxSha256"],
        }:
            raise ValueError(
                f"platform V8 prebuilt provenance mismatch: {report_path}"
            )
    elif prebuilt is not None:
        raise ValueError(f"unexpected V8 prebuilt provenance: {report_path}")

    steps = report.get("steps")
    if not isinstance(steps, dict):
        raise ValueError(f"platform result has no step outcomes: {report_path}")
    required_steps = list(COMMON_STEPS)
    if target["platform"] == "windows":
        required_steps.append("vcRuntime")
    failures = [name for name in required_steps if steps.get(name) != "success"]
    if failures:
        raise ValueError(f"platform steps did not pass: {', '.join(failures)}")

    packaged_attestation_path = (
        root / "reports" / f"packaged-runtime-{target_id}.json"
    )
    packaged_attestation = load_json(packaged_attestation_path)

    report_records = report.get("reports")
    if not isinstance(report_records, dict):
        raise ValueError("platform result does not hash its reports")
    expected_report_hashes = {
        "packageRuntimeAttestationSha256": sha256(packaged_attestation_path),
    }
    if report_records != expected_report_hashes:
        raise ValueError("platform result report digests do not match uploaded files")

    package_dir = root / "prebuilt" / target_id
    archives = sorted(
        path
        for path in package_dir.iterdir()
        if path.is_file() and path.name.endswith(str(target["suffix"]))
    )
    if len(archives) != 1:
        raise ValueError(f"expected one {target['suffix']} archive for {target_id}")
    archive_path = archives[0]
    checksum_path = archive_path.with_name(archive_path.name + ".sha256")
    declared_sha = parse_checksum(checksum_path, archive_path.name)
    actual_sha = sha256(archive_path)
    if declared_sha != actual_sha:
        raise ValueError(f"external archive checksum mismatch: {archive_path}")
    package = validate_package(
        archive_path=archive_path,
        target_id=target_id,
        resolved=resolved,
    )
    validate_packaged_runtime_attestation(
        report=packaged_attestation,
        target=target,
        archive_path=archive_path,
    )
    report_package = report.get("package")
    if (
        not isinstance(report_package, dict)
        or report_package.get("name") != archive_path.name
        or report_package.get("sha256") != actual_sha
    ):
        raise ValueError("platform result package record does not match the archive")

    shutil.copy2(archive_path, release_dir / archive_path.name)
    shutil.copy2(checksum_path, release_dir / checksum_path.name)
    return {
        "status": "passed",
        "package": package,
        "packageRuntimeAttestation": {
            "status": packaged_attestation["status"],
            "cliVersionOutput": packaged_attestation["cliVersionOutput"],
        },
    }


def write_outputs(
    *,
    output: Path,
    markdown: Path,
    resolved_sha: str,
    platforms: dict[str, dict[str, object]],
    errors: list[str],
) -> None:
    status = "passed" if not errors else "failed"
    payload = {
        "schema": SUMMARY_SCHEMA,
        "status": status,
        "resolvedInputsSha256": resolved_sha,
        "platforms": platforms,
        "errors": errors,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    lines = [
        "## DarkPanda Windows/Linux aggregate",
        "",
        f"- Status: `{status}`",
        f"- Resolved inputs: `{resolved_sha}`",
        "",
        "| Target | Result | Package |",
        "|---|---:|---|",
    ]
    for target_id in TARGETS:
        result = platforms.get(target_id, {})
        package = result.get("package", {})
        lines.append(
            f"| `{target_id}` | `{result.get('status', 'missing')}` | "
            f"`{package.get('archive', '')}` |"
        )
    if errors:
        lines.extend(["", "### Errors", ""])
        lines.extend(f"- {error}" for error in errors)
    markdown.parent.mkdir(parents=True, exist_ok=True)
    markdown.write_text("\n".join(lines) + "\n", encoding="utf-8")


def aggregate(args: argparse.Namespace) -> int:
    results = args.results.resolve(strict=True)
    resolved_path = args.resolved_inputs.resolve(strict=True)
    resolved = load_json(resolved_path)
    errors: list[str] = []
    platforms: dict[str, dict[str, object]] = {}
    if (
        resolved.get("schema") != "darkpanda-resolved-inputs/v5"
        or not isinstance(resolved.get("darkpanda"), dict)
        or not isinstance(resolved.get("pythonBinding"), dict)
        or resolved["pythonBinding"].get("repository")  # type: ignore[index]
        != "AeroidesLab/py-darkpanda"
        or not re.fullmatch(
            r"[0-9a-f]{40}",
            str(resolved["pythonBinding"].get("revision", "")),  # type: ignore[index]
        )
        or not isinstance(resolved.get("browserProfile"), dict)
        or not isinstance(resolved.get("components"), dict)
        or set(resolved["components"]) != set(COMPONENTS)  # type: ignore[arg-type]
    ):
        errors.append("resolved-inputs.json does not contain the v5 fixed-build graph")
    try:
        build_dependency_values(resolved)
    except ValueError as error:
        errors.append(str(error))

    expected_dirs = {f"darkpanda-result-{target_id}" for target_id in TARGETS}
    actual_dirs = {path.name for path in results.iterdir() if path.is_dir()}
    missing = sorted(expected_dirs - actual_dirs)
    unexpected = sorted(actual_dirs - expected_dirs)
    if missing:
        errors.append("missing platform artifacts: " + ", ".join(missing))
    if unexpected:
        errors.append("unexpected platform artifacts: " + ", ".join(unexpected))

    release_dir = args.release_dir.resolve()
    if release_dir.exists():
        shutil.rmtree(release_dir)
    release_dir.mkdir(parents=True)
    if not errors:
        resolved_sha = sha256(resolved_path)
        for target_id in TARGETS:
            try:
                platforms[target_id] = validate_platform(
                    root=results / f"darkpanda-result-{target_id}",
                    target_id=target_id,
                    resolved=resolved,
                    resolved_sha=resolved_sha,
                    release_dir=release_dir,
                )
            except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
                platforms[target_id] = {"status": "failed", "error": str(error)}
                errors.append(f"{target_id}: {error}")

    if not errors:
        release_records = []
        for path in sorted(release_dir.iterdir()):
            if path.is_file() and not path.name.endswith(".sha256"):
                release_records.append(f"{sha256(path)}  {path.name}\n")
        (release_dir / "SHA256SUMS").write_text(
            "".join(release_records), encoding="utf-8"
        )
    write_outputs(
        output=args.output.resolve(),
        markdown=args.markdown.resolve(),
        resolved_sha=sha256(resolved_path),
        platforms=platforms,
        errors=errors,
    )
    return 0 if not errors else 1


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--results", required=True, type=Path)
    result.add_argument("--resolved-inputs", required=True, type=Path)
    result.add_argument("--output", required=True, type=Path)
    result.add_argument("--markdown", required=True, type=Path)
    result.add_argument("--release-dir", required=True, type=Path)
    return result


def main() -> int:
    return aggregate(parser().parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
