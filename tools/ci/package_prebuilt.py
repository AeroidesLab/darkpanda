#!/usr/bin/env python3
"""Build a deterministic, self-describing DarkPanda runtime archive."""

from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath, PureWindowsPath
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
from typing import Any, Iterable
import zipfile


SCHEMA = "darkpanda-prebuilt-runtime/v1"
MIB = 1024 * 1024


RUNTIME_NAMES = {
    "windows": (
        "darkpanda.exe",
        "darkpanda.dll",
        "wreq.dll",
        "canvas.dll",
        "html5ever.dll",
        "msvcp140.dll",
        "vcruntime140.dll",
        "vcruntime140_1.dll",
    ),
    "linux": (
        "darkpanda",
        "libdarkpanda.so",
        "libwreq.so",
        "libcanvas.so",
        "libhtml5ever.so",
    ),
    "macos": (
        "darkpanda",
        "libdarkpanda.dylib",
        "libwreq.dylib",
        "libcanvas.dylib",
        "libhtml5ever.dylib",
    ),
}
COMPONENT_NAMES = ("canvas", "html5ever", "wreq", "boringssl")
PACKAGE_TARGETS = {
    "windows": {
        "x86_64-windows-msvc": "windows-x86_64",
    },
    "linux": {
        "x86_64-linux-gnu": "linux-x86_64",
    },
}
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
LINUX_SYSTEM_LIBRARY_ROOTS = (
    Path("/lib"),
    Path("/lib64"),
    Path("/usr/lib"),
    Path("/usr/lib64"),
)
ELF_DYNAMIC_PATTERN = re.compile(
    r"\((NEEDED|RPATH|RUNPATH)\).*?\[([^\]]*)\]"
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(MIB), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(
    command: list[str],
    *,
    environment: dict[str, str] | None = None,
    cwd: Path | None = None,
) -> str:
    completed = subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=environment,
        cwd=cwd,
    )
    return completed.stdout


def c_string(data: bytes, offset: int) -> str:
    end = data.find(b"\0", offset)
    if end < 0:
        raise ValueError("unterminated PE string")
    return data[offset:end].decode("ascii", errors="replace")


def pe_imports(path: Path) -> list[str]:
    """Read normal and delay-load DLL names without external Python packages."""
    data = path.read_bytes()
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise ValueError(f"not a PE image: {path}")
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise ValueError(f"invalid PE signature: {path}")
    coff = pe_offset + 4
    section_count = struct.unpack_from("<H", data, coff + 2)[0]
    optional_size = struct.unpack_from("<H", data, coff + 16)[0]
    optional = coff + 20
    magic = struct.unpack_from("<H", data, optional)[0]
    if magic == 0x20B:
        directory = optional + 112
        image_base = struct.unpack_from("<Q", data, optional + 24)[0]
    elif magic == 0x10B:
        directory = optional + 96
        image_base = struct.unpack_from("<I", data, optional + 28)[0]
    else:
        raise ValueError(f"unsupported PE optional header: 0x{magic:x}")
    sections_offset = optional + optional_size
    sections: list[tuple[int, int, int, int]] = []
    for index in range(section_count):
        base = sections_offset + index * 40
        virtual_size, virtual_address, raw_size, raw_offset = struct.unpack_from(
            "<IIII", data, base + 8
        )
        sections.append((virtual_address, max(virtual_size, raw_size), raw_offset, raw_size))

    def rva_offset(rva: int) -> int:
        for virtual_address, span, raw_offset, raw_size in sections:
            if virtual_address <= rva < virtual_address + span:
                relative = rva - virtual_address
                if relative >= raw_size:
                    raise ValueError(f"PE RVA points outside raw section: 0x{rva:x}")
                return raw_offset + relative
        raise ValueError(f"unmapped PE RVA: 0x{rva:x}")

    names: set[str] = set()
    import_rva, _ = struct.unpack_from("<II", data, directory + 8)
    if import_rva:
        cursor = rva_offset(import_rva)
        while True:
            descriptor = struct.unpack_from("<IIIII", data, cursor)
            if descriptor == (0, 0, 0, 0, 0):
                break
            names.add(c_string(data, rva_offset(descriptor[3])).lower())
            cursor += 20

    delay_rva, _ = struct.unpack_from("<II", data, directory + 13 * 8)
    if delay_rva:
        cursor = rva_offset(delay_rva)
        while True:
            descriptor = struct.unpack_from("<IIIIIIII", data, cursor)
            if descriptor == (0, 0, 0, 0, 0, 0, 0, 0):
                break
            attributes, name_rva = descriptor[0], descriptor[1]
            if not attributes & 1:
                if name_rva < image_base:
                    raise ValueError(
                        f"invalid delay-load VA below image base: 0x{name_rva:x}"
                    )
                name_rva -= image_base
            names.add(c_string(data, rva_offset(name_rva)).lower())
            cursor += 32
    return sorted(names)


def validate_windows_dependency_contract(
    *,
    binary: Path,
    imports: list[str],
    bundled_names: set[str],
    system32: Path,
) -> dict[str, Any]:
    unsafe = [
        name
        for name in imports
        if (
            PureWindowsPath(name).name != name
            or bool(PureWindowsPath(name).drive)
            or bool(PureWindowsPath(name).root)
            or any(character in name for character in ("/", "\\", ":"))
            or name in ("", ".", "..")
            or not name.endswith(".dll")
        )
    ]
    if unsafe:
        raise SystemExit(
            f"Windows imports must be plain DLL basenames in {binary}: "
            + ", ".join(unsafe)
        )
    bundled = sorted(name for name in imports if name in bundled_names)
    external = sorted(name for name in imports if name not in bundled_names)
    missing_bundled = [
        name
        for name in external
        if name.startswith(("msvcp", "vcruntime", "concrt"))
        or name.startswith(("darkpanda", "wreq", "canvas", "html5ever"))
    ]
    if missing_bundled:
        raise SystemExit(
            f"unbundled Windows runtime dependencies in {binary}: "
            + ", ".join(missing_bundled)
        )
    unknown = [
        name
        for name in external
        if not name.startswith(("api-ms-win-", "ext-ms-win-"))
        and not (system32 / name).is_file()
    ]
    if unknown:
        raise SystemExit(
            f"Windows imports are neither packaged nor present in System32 for {binary}: "
            + ", ".join(unknown)
        )
    api_sets = sorted(
        name
        for name in external
        if name.startswith(("api-ms-win-", "ext-ms-win-"))
    )
    system32_imports = sorted(name for name in external if name not in api_sets)
    return {
        "peImports": imports,
        "bundledImports": bundled,
        "apiSetImports": api_sets,
        "system32Imports": system32_imports,
    }


def clean_loader_environment() -> dict[str, str]:
    environment = os.environ.copy()
    for name in tuple(environment):
        if name.startswith(("LD_", "DYLD_")):
            environment.pop(name)
    return environment


def elf_dynamic_contract(dynamic: str) -> tuple[list[str], list[str]]:
    needed: list[str] = []
    runtime_paths: list[str] = []
    for tag, value in ELF_DYNAMIC_PATTERN.findall(dynamic):
        if tag == "NEEDED":
            needed.append(value)
        else:
            runtime_paths.extend(value.split(":"))
    return needed, runtime_paths


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


def parse_ldd_resolutions(linked: str) -> dict[str, Path]:
    resolutions: dict[str, Path] = {}
    for raw_line in linked.splitlines():
        line = raw_line.strip()
        match = re.match(r"(\S+)\s+=>\s+(\S+)\s+\(", line)
        if match is not None and match.group(2) != "not":
            resolutions[match.group(1)] = Path(match.group(2))
            continue
        direct = re.match(r"(/\S+)\s+\(", line)
        if direct is not None:
            path = Path(direct.group(1))
            resolutions[path.name] = path
    return resolutions


def is_system_library(path: Path) -> bool:
    if not path.is_absolute():
        return False
    resolved = path.resolve(strict=True)
    return any(
        resolved == root.resolve() or resolved.is_relative_to(root.resolve())
        for root in LINUX_SYSTEM_LIBRARY_ROOTS
    )


def validate_elf_dependency_contract(
    *,
    binary: Path,
    dynamic: str,
    linked: str,
    bundled: dict[str, Path],
) -> dict[str, Any]:
    needed, runtime_paths = elf_dynamic_contract(dynamic)
    if len(needed) != len(set(needed)):
        raise SystemExit(f"duplicate ELF DT_NEEDED entries in {binary}")
    forbidden_needed = sorted(set(needed) - set(bundled) - LINUX_OS_NEEDED)
    if forbidden_needed:
        raise SystemExit(
            f"ELF DT_NEEDED is outside the runtime allowlist in {binary}: "
            + ", ".join(forbidden_needed)
        )
    forbidden_paths = sorted(
        value for value in runtime_paths if not valid_origin_runtime_path(value)
    )
    if forbidden_paths:
        raise SystemExit(
            f"ELF RPATH/RUNPATH must be $ORIGIN-relative in {binary}: "
            + ", ".join(repr(value) for value in forbidden_paths)
        )
    if "not found" in linked:
        raise SystemExit(f"unresolved ELF dependency in {binary}:\n{linked}")

    resolutions = parse_ldd_resolutions(linked)
    for name in needed:
        resolved = resolutions.get(name)
        if resolved is None:
            raise SystemExit(f"ldd did not resolve {name} for {binary}:\n{linked}")
        if name in bundled:
            expected = bundled[name].resolve(strict=True)
            if resolved.resolve(strict=True) != expected:
                raise SystemExit(
                    f"bundled ELF dependency {name} escaped the package in {binary}: "
                    f"{resolved} != {expected}"
                )
        elif not is_system_library(resolved):
            raise SystemExit(
                f"ELF operating-system dependency {name} resolved outside system "
                f"library roots in {binary}: {resolved}"
            )
    return {
        "needed": needed,
        "bundledNeeded": sorted(name for name in needed if name in bundled),
        "operatingSystemNeeded": sorted(
            name for name in needed if name in LINUX_OS_NEEDED
        ),
        "runtimePaths": runtime_paths,
    }


def dependency_report(platform: str, binaries: Iterable[Path]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    binary_list = list(binaries)
    bundled_names = {path.name.lower() for path in binary_list}
    for binary in binary_list:
        if platform == "windows":
            imports = pe_imports(binary)
            system_root = Path(os.environ.get("SystemRoot", r"C:\Windows"))
            result[binary.name] = validate_windows_dependency_contract(
                binary=binary,
                imports=imports,
                bundled_names=bundled_names,
                system32=system_root / "System32",
            )
        elif platform == "linux":
            environment = clean_loader_environment()
            dynamic = run(["readelf", "-d", str(binary)], environment=environment)
            linked = run(["ldd", str(binary)], environment=environment)
            linux_bundled = {
                path.name: path for path in binary_list if path.suffix == ".so"
            }
            result[binary.name] = validate_elf_dependency_contract(
                binary=binary,
                dynamic=dynamic,
                linked=linked,
                bundled=linux_bundled,
            )
        else:
            linked = run(["otool", "-L", str(binary)])
            loads = run(["otool", "-l", str(binary)])
            forbidden = ("/Users/runner/", "/private/var/", "/opt/hostedtoolcache/")
            linked_lines = linked.splitlines()
            if any(marker in line for marker in forbidden for line in linked_lines[1:]):
                raise SystemExit(f"non-portable Mach-O dependency in {binary}:\n{linked}")
            result[binary.name] = {
                "otoolLibraries": linked_lines,
                "otoolLoadCommands": loads.splitlines(),
            }
    policy: dict[str, Any] = {
        "archiveRuntimeNames": [path.name for path in binary_list],
    }
    if platform == "linux":
        policy.update(
            {
                "neededAllowlist": sorted(
                    {path.name for path in binary_list if path.suffix == ".so"}
                    | LINUX_OS_NEEDED
                ),
                "runtimePathPolicy": "$ORIGIN-relative-only",
                "systemLibraryRoots": [
                    path.as_posix() for path in LINUX_SYSTEM_LIBRARY_ROOTS
                ],
            }
        )
    elif platform == "windows":
        policy["bundledVisualCRuntime"] = [
            name
            for name in RUNTIME_NAMES["windows"]
            if name.startswith(("msvcp", "vcruntime", "concrt"))
        ]
        policy["operatingSystemImportPolicy"] = (
            "api-set-or-existing-system32-file"
        )
    return {
        "schema": "darkpanda-runtime-dependencies/v2",
        "platform": platform,
        "policy": policy,
        "binaries": result,
    }


def copy_tree_files(source: Path, destination: Path) -> None:
    for path in sorted(source.rglob("*")):
        if (
            not path.is_file()
            or "__pycache__" in path.parts
            or path.suffix in {".pyc", ".pyo"}
        ):
            continue
        relative = path.relative_to(source)
        output = destination / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, output)


def requested_target(report: dict[str, Any]) -> Any:
    return report.get("requestedTarget") or report.get("target")


def source_revision(component: str, build_info: dict[str, Any]) -> Any:
    source = build_info.get("source")
    if isinstance(source, dict) and source.get("revision"):
        return source["revision"]
    return (
        build_info.get(f"{component}Revision")
        or build_info.get("sourceRevision")
    )


def verified_component_metadata(
    component: str,
    dist_value: Path,
    expected_target: str,
) -> tuple[Path, dict[str, Any]]:
    """Verify one standardized component dist before embedding its provenance."""
    dist = dist_value.resolve(strict=True)
    if not dist.is_dir() or not dist.is_absolute():
        raise SystemExit(f"{component} dist is not an absolute directory: {dist}")
    metadata = dist / "metadata"
    required = {
        "buildInfo": metadata / "build-info.json",
        "testResults": metadata / "test-results.json",
        "checksums": metadata / "SHA256SUMS",
    }
    missing = [str(path) for path in required.values() if not path.is_file()]
    if missing:
        raise SystemExit(
            f"{component} dist is missing required metadata:\n" + "\n".join(missing)
        )

    declared: dict[str, str] = {}
    for line_number, raw_line in enumerate(
        required["checksums"].read_text(encoding="utf-8").splitlines(), start=1
    ):
        digest, separator, relative_text = raw_line.partition("  ")
        if (
            not separator
            or not re.fullmatch(r"[0-9a-fA-F]{64}", digest)
            or not relative_text
        ):
            raise SystemExit(
                f"invalid {component} SHA256SUMS line {line_number}: {raw_line!r}"
            )
        relative = PurePosixPath(relative_text)
        if relative.is_absolute() or ".." in relative.parts or relative_text in declared:
            raise SystemExit(
                f"unsafe or duplicate {component} checksum path: {relative_text!r}"
            )
        source = dist.joinpath(*relative.parts).resolve(strict=True)
        if not source.is_file() or not source.is_relative_to(dist):
            raise SystemExit(
                f"{component} checksum path escapes dist or is not a file: {relative_text}"
            )
        actual = sha256(source)
        if actual.lower() != digest.lower():
            raise SystemExit(
                f"{component} checksum mismatch for {relative_text}: "
                f"expected {digest.lower()}, got {actual}"
            )
        declared[relative_text] = digest.lower()

    checksum_relative = required["checksums"].relative_to(dist).as_posix()
    actual_files = {
        path.relative_to(dist).as_posix()
        for path in dist.rglob("*")
        if path.is_file() and path != required["checksums"]
    }
    if set(declared) != actual_files:
        missing_entries = sorted(actual_files - set(declared))
        stale_entries = sorted(set(declared) - actual_files)
        details = []
        if missing_entries:
            details.append("unhashed files: " + ", ".join(missing_entries))
        if stale_entries:
            details.append("missing files: " + ", ".join(stale_entries))
        raise SystemExit(f"incomplete {component} SHA256SUMS: " + "; ".join(details))
    if checksum_relative in declared:
        raise SystemExit(f"{component} SHA256SUMS must not hash itself")

    build_info = json.loads(required["buildInfo"].read_text(encoding="utf-8"))
    test_results = json.loads(required["testResults"].read_text(encoding="utf-8"))
    if build_info.get("component") != component:
        raise SystemExit(
            f"{component} build-info.json identifies {build_info.get('component')!r}"
        )
    if test_results.get("component") != component or test_results.get("status") != "passed":
        raise SystemExit(
            f"{component} test-results.json must identify the component and report passed"
        )
    if requested_target(build_info) != expected_target:
        raise SystemExit(
            f"{component} build-info target mismatch: "
            f"{requested_target(build_info)!r} != {expected_target!r}"
        )
    if requested_target(test_results) != expected_target:
        raise SystemExit(
            f"{component} test-results target mismatch: "
            f"{requested_target(test_results)!r} != {expected_target!r}"
        )
    source = build_info.get("source")
    revision = source_revision(component, build_info)
    if (
        not isinstance(source, dict)
        or source.get("dirty") is not False
        or not isinstance(revision, str)
        or not re.fullmatch(r"[0-9a-f]{40}", revision)
    ):
        raise SystemExit(
            f"{component} build-info has no clean 40-character source revision"
        )
    profile_sha = build_info.get("chromiumProfileSha256")
    manifest_sha = build_info.get("toolchainManifestSha256")
    if not isinstance(profile_sha, str) or not re.fullmatch(
        r"[0-9a-f]{64}", profile_sha
    ):
        raise SystemExit(f"{component} build-info has no Chromium profile hash")
    if not isinstance(manifest_sha, str) or not re.fullmatch(
        r"[0-9a-f]{64}", manifest_sha
    ):
        raise SystemExit(f"{component} build-info has no toolchain manifest hash")
    return dist, {
        "target": expected_target,
        "revision": revision,
        "chromiumProfileSha256": profile_sha,
        "toolchainManifestSha256": manifest_sha,
        "buildInfoSha256": sha256(required["buildInfo"]),
        "testResultsSha256": sha256(required["testResults"]),
        "checksumsSha256": sha256(required["checksums"]),
    }


def normalize_mode(path: Path) -> int:
    if path.name == "darkpanda" or path.suffix in {".so", ".dylib"}:
        return 0o755
    return 0o644


def payload_records(
    root: Path, excluded_paths: frozenset[str] = frozenset()
) -> list[dict[str, Any]]:
    records = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        if relative in excluded_paths:
            continue
        records.append(
            {
                "path": relative,
                "size": path.stat().st_size,
                "sha256": sha256(path),
            }
        )
    return records


def add_tar_file(archive: tarfile.TarFile, path: Path, arcname: str, epoch: int) -> None:
    info = archive.gettarinfo(str(path), arcname=arcname)
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = epoch
    info.mode = normalize_mode(path)
    with path.open("rb") as stream:
        archive.addfile(info, stream)


def create_tar_gz(root: Path, output: Path, epoch: int) -> None:
    with output.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=epoch, compresslevel=9) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for path in sorted(root.rglob("*")):
                    if path.is_file():
                        add_tar_file(archive, path, f"{root.name}/{path.relative_to(root).as_posix()}", epoch)


def create_zip(root: Path, output: Path, epoch: int) -> None:
    timestamp = dt.datetime.fromtimestamp(max(epoch, 315532800), tz=dt.timezone.utc)
    date_time = (timestamp.year, timestamp.month, timestamp.day, timestamp.hour, timestamp.minute, timestamp.second)
    with zipfile.ZipFile(
        output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9, strict_timestamps=False
    ) as archive:
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            info = zipfile.ZipInfo(
                f"{root.name}/{path.relative_to(root).as_posix()}", date_time=date_time
            )
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = normalize_mode(path) << 16
            info.create_system = 3
            archive.writestr(info, path.read_bytes(), compresslevel=9)


def safe_archive_relative(name: str) -> PurePosixPath:
    relative = PurePosixPath(name.rstrip("/"))
    windows = PureWindowsPath(name)
    if (
        not name
        or relative.is_absolute()
        or windows.is_absolute()
        or bool(windows.drive)
        or bool(windows.root)
        or ".." in relative.parts
        or "\\" in name
        or any(":" in part for part in relative.parts)
        or any(part in ("", ".") for part in relative.parts)
    ):
        raise ValueError(f"unsafe archive member: {name!r}")
    return relative


def extract_runtime_archive(
    archive_path: Path,
    destination: Path,
    expected_root: str,
) -> Path:
    """Extract only regular files/directories and require the expected layout root."""
    destination.mkdir(parents=True, exist_ok=False)
    destination_root = destination.resolve(strict=True)
    roots: set[str] = set()
    if archive_path.name.endswith(".zip"):
        with zipfile.ZipFile(archive_path) as archive:
            for info in archive.infolist():
                relative = safe_archive_relative(info.filename)
                roots.add(relative.parts[0])
                target = destination.joinpath(*relative.parts).resolve(strict=False)
                if not target.is_relative_to(destination_root):
                    raise ValueError(f"archive member escapes destination: {info.filename}")
                file_type = (info.external_attr >> 16) & 0o170000
                if file_type == 0o120000:
                    raise ValueError(f"ZIP symlink is forbidden: {info.filename}")
                if info.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(info) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
                mode = (info.external_attr >> 16) & 0o777
                if mode:
                    os.chmod(target, mode)
    elif archive_path.name.endswith(".tar.gz"):
        with tarfile.open(archive_path, mode="r:gz") as archive:
            for member in archive.getmembers():
                relative = safe_archive_relative(member.name)
                roots.add(relative.parts[0])
                target = destination.joinpath(*relative.parts).resolve(strict=False)
                if not target.is_relative_to(destination_root):
                    raise ValueError(f"archive member escapes destination: {member.name}")
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                if not member.isfile():
                    raise ValueError(
                        f"non-regular tar member is forbidden: {member.name}"
                    )
                source = archive.extractfile(member)
                if source is None:
                    raise ValueError(f"could not extract tar member: {member.name}")
                target.parent.mkdir(parents=True, exist_ok=True)
                with source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
                os.chmod(target, member.mode & 0o777)
    else:
        raise ValueError(f"unsupported runtime archive: {archive_path}")

    if roots != {expected_root}:
        raise ValueError(
            f"archive must contain exactly the {expected_root!r} root, got {sorted(roots)}"
        )
    extracted_root = destination / expected_root
    if not extracted_root.is_dir():
        raise ValueError(f"archive layout root is missing: {extracted_root}")
    return extracted_root


def runtime_paths(platform: str, root: Path) -> dict[str, Path]:
    names = {
        "windows": {
            "cli": "darkpanda.exe",
            "ffi": "darkpanda.dll",
            "wreq": "wreq.dll",
            "canvas": "canvas.dll",
            "html5ever": "html5ever.dll",
        },
        "linux": {
            "cli": "darkpanda",
            "ffi": "libdarkpanda.so",
            "wreq": "libwreq.so",
            "canvas": "libcanvas.so",
            "html5ever": "libhtml5ever.so",
        },
        "macos": {
            "cli": "darkpanda",
            "ffi": "libdarkpanda.dylib",
            "wreq": "libwreq.dylib",
            "canvas": "libcanvas.dylib",
            "html5ever": "libhtml5ever.dylib",
        },
    }[platform]
    result = {name: root / "bin" / filename for name, filename in names.items()}
    missing = [str(path) for path in result.values() if not path.is_file()]
    if missing:
        raise ValueError("archive runtime layout is incomplete:\n" + "\n".join(missing))
    return result


def archive_runtime_environment(
    platform: str,
    bin_dir: Path,
    python_root: Path,
) -> tuple[dict[str, str], str]:
    environment = clean_loader_environment()
    environment.pop("PYTHONHOME", None)
    environment["PYTHONPATH"] = str(python_root)
    environment["PYTHONNOUSERSITE"] = "1"
    if platform == "windows":
        system_root = Path(environment.get("SystemRoot", r"C:\Windows"))
        environment["PATH"] = os.pathsep.join(
            (str(bin_dir), str(system_root / "System32"), str(system_root))
        )
        policy = "archive-bin-plus-windows-system"
    else:
        environment["PATH"] = "/usr/local/bin:/usr/bin:/bin"
        policy = "elf-origin-plus-system" if platform == "linux" else "macho-rpath-plus-system"
    return environment, policy


def subprocess_failure(error: BaseException) -> str:
    if isinstance(error, subprocess.CalledProcessError):
        output = "\n".join(
            value.strip()
            for value in (error.stdout or "", error.stderr or "")
            if value.strip()
        )
        return f"{error}; output: {output}" if output else str(error)
    return str(error)


def attest_runtime_archive(
    *,
    platform: str,
    archive_path: Path,
    archive_sha256: str,
    archive_root: str,
    repository: Path,
    output_path: Path,
) -> None:
    output_path = output_path.resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    report: dict[str, Any] = {
        "schema": "darkpanda-packaged-runtime-attestation/v1",
        "status": "FAIL",
        "archive": archive_path.name,
        "archiveSha256": archive_sha256,
        "extractedRoot": archive_root,
    }
    try:
        with tempfile.TemporaryDirectory(
            prefix=".archive-runtime-", dir=archive_path.parent
        ) as temporary:
            extraction = Path(temporary) / "unpacked"
            extracted_root = extract_runtime_archive(
                archive_path, extraction, archive_root
            )
            paths = runtime_paths(platform, extracted_root)
            python_root = extracted_root / "python"
            if not python_root.is_dir():
                raise ValueError(f"archive Python package is missing: {python_root}")
            environment, loader_policy = archive_runtime_environment(
                platform, extracted_root / "bin", python_root
            )
            version = subprocess.run(
                [str(paths["cli"]), "version"],
                check=True,
                cwd=extracted_root / "bin",
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            ).stdout.strip()
            if not version:
                raise ValueError("archive CLI version command returned no output")

            closure_names = ("ffi", "wreq", "canvas", "html5ever")
            subprocess.run(
                [
                    sys.executable,
                    "-c",
                    (
                        "import ctypes,sys;"
                        "[ctypes.CDLL(path) for path in sys.argv[1:]]"
                    ),
                    *(str(paths[name]) for name in closure_names),
                ],
                check=True,
                cwd=extracted_root / "bin",
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            attestation_script = repository / "tools" / "runtime_artifact_attestation.py"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(attestation_script),
                    "--python-root",
                    str(python_root),
                    "--library",
                    str(paths["ffi"]),
                    "--wreq",
                    str(paths["wreq"]),
                    "--canvas",
                    str(paths["canvas"]),
                    "--html5ever",
                    str(paths["html5ever"]),
                ],
                check=True,
                cwd=extracted_root / "bin",
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            runtime = json.loads(completed.stdout)
            if (
                not isinstance(runtime, dict)
                or runtime.get("schema")
                != "darkpanda-runtime-load-attestation/v1"
                or runtime.get("status") != "PASS"
                or runtime.get("canvasAbiVersion") != 5
            ):
                raise ValueError(
                    "archive runtime attestation did not prove the runtime load contract"
                )
            original_paths = runtime.get("paths")
            if not isinstance(original_paths, dict):
                raise ValueError("archive runtime attestation did not report loaded paths")
            for name in closure_names:
                value = original_paths.get(name)
                if (
                    not isinstance(value, str)
                    or Path(value).resolve(strict=True) != paths[name].resolve(strict=True)
                ):
                    raise ValueError(
                        f"archive runtime attestation loaded {name} outside the archive"
                    )
            runtime_proof = {
                name: runtime[name]
                for name in (
                    "status",
                    "ffiAbiVersion",
                    "ffiVersion",
                    "wreqAbiVersion",
                    "wreqVersion",
                    "canvasAbiVersion",
                    "canvasVersion",
                )
                if name in runtime
            }
            runtime_proof["loadedLibraries"] = [
                paths[name].relative_to(extracted_root).as_posix()
                for name in closure_names
            ]
            runtime_proof["paths"] = {
                name: paths[name].relative_to(extracted_root).as_posix()
                for name in closure_names
            }
            report.update(
                {
                    "status": "PASS",
                    "cleanEnvironment": True,
                    "loaderPolicy": loader_policy,
                    "cliVersionOutput": version,
                    "loadedLibraries": [
                        paths[name].relative_to(extracted_root).as_posix()
                        for name in closure_names
                    ],
                    "runtime": runtime_proof,
                }
            )
    except (
        OSError,
        ValueError,
        KeyError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
    ) as error:
        report["error"] = subprocess_failure(error)
        output_path.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        raise SystemExit(f"archive runtime attestation failed: {report['error']}") from error

    output_path.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def sanitized(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._+-]", "_", value)


def component_target(platform: str, target: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9._+-]+", target) is None:
        raise SystemExit(f"invalid package target syntax: {target}")
    expected = PACKAGE_TARGETS.get(platform, {}).get(target)
    if expected is None:
        raise SystemExit(f"unsupported package platform/target: {platform}/{target}")
    return expected


def direct_output_path(output: Path, name: str) -> Path:
    candidate = (output / name).resolve()
    if candidate == output or candidate.parent != output:
        raise SystemExit(f"package output path escapes output directory: {name}")
    return candidate


def package(args: argparse.Namespace) -> None:
    repo = args.repo.resolve(strict=True)
    install = args.install_root.resolve(strict=True)
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    expected_component_target = component_target(args.platform, args.target)
    component_metadata: dict[str, dict[str, Any]] = {}
    component_dists: dict[str, Path] = {}
    for component in COMPONENT_NAMES:
        dist, record = verified_component_metadata(
            component,
            getattr(args, f"{component}_dist"),
            expected_component_target,
        )
        component_dists[component] = dist
        component_metadata[component] = record
    profiles = {
        record["chromiumProfileSha256"]
        for record in component_metadata.values()
    }
    manifests = {
        record["toolchainManifestSha256"]
        for record in component_metadata.values()
    }
    if len(profiles) != 1:
        raise SystemExit("component dists do not share one Chromium profile hash")
    if len(manifests) != 1:
        raise SystemExit("component dists do not share one toolchain manifest hash")
    if component_metadata["boringssl"]["revision"] != args.boringssl_source_revision:
        raise SystemExit(
            "BoringSSL package revision does not match its component metadata"
        )

    bin_dir = install / "bin"
    include_dir = install / "include"
    runtime = [bin_dir / name for name in RUNTIME_NAMES[args.platform]]
    missing = [str(path) for path in runtime if not path.is_file()]
    for header in ("darkpanda.h", "canvas.h"):
        if not (include_dir / header).is_file():
            missing.append(str(include_dir / header))
    if missing:
        raise SystemExit("missing runtime bundle inputs:\n" + "\n".join(missing))

    source_epoch = args.source_date_epoch
    archive_stem = f"darkpanda-{sanitized(args.version)}-{args.target}"
    staging = direct_output_path(output, archive_stem)
    if staging.exists():
        shutil.rmtree(staging)
    (staging / "bin").mkdir(parents=True)
    (staging / "include").mkdir()
    (staging / "metadata").mkdir()

    for binary in runtime:
        shutil.copy2(binary, staging / "bin" / binary.name)
    for header in ("darkpanda.h", "canvas.h"):
        shutil.copy2(include_dir / header, staging / "include" / header)
    for name in ("LICENSE", "README.md", "build.zig.zon"):
        shutil.copy2(repo / name, staging / ("metadata" if name == "build.zig.zon" else "") / name)
    for component, dist in component_dists.items():
        copy_tree_files(
            dist / "metadata",
            staging / "metadata" / "components" / component,
        )
    copy_tree_files(repo / "python" / "darkpanda", staging / "python" / "darkpanda")

    staged_runtime = [staging / "bin" / path.name for path in runtime]
    dependencies = dependency_report(args.platform, staged_runtime)
    (staging / "metadata" / "runtime-dependencies.json").write_text(
        json.dumps(dependencies, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    records = payload_records(
        staging, frozenset({"BUILD-INFO.json", "SHA256SUMS"})
    )
    build_info = {
        "schema": SCHEMA,
        "artifactName": archive_stem,
        "version": args.version,
        "platform": args.platform,
        "target": args.target,
        "optimization": {
            "zig": "ReleaseFast",
            "rustOptLevel": 3,
            "rustLto": "fat",
            "rustCodegenUnits": 1,
            "portableCpuBaseline": True,
        },
        "source": {
            "repository": args.repository,
            "revision": args.source_revision,
            "sourceDateEpoch": source_epoch,
        },
        "dependencies": {
            "v8Version": args.v8_version,
            "v8Revision": args.v8_revision,
            "v8ArchiveSha256": args.v8_archive_sha256,
            "zigV8SourceRevision": args.zig_v8_source_revision,
            "boringSslSourceRevision": args.boringssl_source_revision,
            "components": component_metadata,
        },
        "toolchain": {
            "zig": args.zig_version,
            "rustc": args.rust_version,
            "runnerImage": args.runner_image,
        },
        "runtimeClosure": [path.name for path in staged_runtime],
        "files": records,
    }
    (staging / "BUILD-INFO.json").write_text(
        json.dumps(build_info, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    checksum_records = payload_records(staging, frozenset({"SHA256SUMS"}))
    (staging / "SHA256SUMS").write_text(
        "".join(f"{record['sha256']}  {record['path']}\n" for record in checksum_records),
        encoding="utf-8",
    )

    for path in staging.rglob("*"):
        if path.is_file():
            os.chmod(path, normalize_mode(path))
            os.utime(path, (source_epoch, source_epoch))

    suffix = ".zip" if args.platform == "windows" else ".tar.gz"
    archive = direct_output_path(output, f"{archive_stem}{suffix}")
    if archive.exists():
        archive.unlink()
    if args.platform == "windows":
        create_zip(staging, archive, source_epoch)
    else:
        create_tar_gz(staging, archive, source_epoch)
    archive_sha = sha256(archive)
    checksum = archive.with_name(archive.name + ".sha256")
    checksum.write_text(f"{archive_sha}  {archive.name}\n", encoding="utf-8")
    attest_runtime_archive(
        platform=args.platform,
        archive_path=archive,
        archive_sha256=archive_sha,
        archive_root=archive_stem,
        repository=repo,
        output_path=args.package_runtime_attestation,
    )
    print(
        json.dumps(
            {
                "archive": str(archive),
                "checksum": str(checksum),
                "sha256": archive_sha,
                "size": archive.stat().st_size,
            },
            separators=(",", ":"),
            sort_keys=True,
        )
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--repo", type=Path, required=True)
    result.add_argument("--install-root", type=Path, required=True)
    result.add_argument("--output-dir", type=Path, required=True)
    result.add_argument(
        "--package-runtime-attestation",
        type=Path,
        required=True,
    )
    for component in COMPONENT_NAMES:
        result.add_argument(f"--{component}-dist", type=Path, required=True)
    result.add_argument("--platform", choices=sorted(RUNTIME_NAMES), required=True)
    result.add_argument("--target", required=True)
    result.add_argument("--version", required=True)
    result.add_argument("--repository", required=True)
    result.add_argument("--source-revision", required=True)
    result.add_argument("--source-date-epoch", type=int, required=True)
    result.add_argument("--v8-version", required=True)
    result.add_argument("--v8-revision", required=True)
    result.add_argument("--v8-archive-sha256", required=True)
    result.add_argument("--zig-v8-source-revision", required=True)
    result.add_argument("--boringssl-source-revision", required=True)
    result.add_argument("--zig-version", required=True)
    result.add_argument("--rust-version", required=True)
    result.add_argument("--runner-image", required=True)
    return result


def main() -> int:
    package(parser().parse_args())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
