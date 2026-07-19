#!/usr/bin/env python3
"""Build a deterministic, self-describing DarkPanda runtime archive."""

from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tarfile
from typing import Any, Iterable
import zipfile


SCHEMA = "darkpanda-prebuilt-runtime/v1"
MIB = 1024 * 1024


RUNTIME_NAMES = {
    "windows": (
        "darkpanda.exe",
        "darkpanda.dll",
        "wreq.dll",
        "darkpanda_canvas_backend.dll",
        "darkpanda_html5ever.dll",
        "msvcp140.dll",
        "vcruntime140.dll",
        "vcruntime140_1.dll",
    ),
    "linux": (
        "darkpanda",
        "libdarkpanda.so",
        "libwreq.so",
        "libdarkpanda_canvas_backend.so",
        "libdarkpanda_html5ever.so",
    ),
    "macos": (
        "darkpanda",
        "libdarkpanda.dylib",
        "libwreq.dylib",
        "libdarkpanda_canvas_backend.dylib",
        "libdarkpanda_html5ever.dylib",
    ),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(MIB), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command: list[str]) -> str:
    completed = subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
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
    elif magic == 0x10B:
        directory = optional + 96
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
            if attributes & 1:
                names.add(c_string(data, rva_offset(name_rva)).lower())
            cursor += 32
    return sorted(names)


def dependency_report(platform: str, binaries: Iterable[Path]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    binary_list = list(binaries)
    bundled_names = {path.name.lower() for path in binary_list}
    for binary in binary_list:
        if platform == "windows":
            imports = pe_imports(binary)
            bundled = sorted(name for name in imports if name in bundled_names)
            external = sorted(name for name in imports if name not in bundled_names)
            missing_redistributables = [
                name
                for name in external
                if name.startswith(("msvcp", "vcruntime", "concrt"))
                or name.startswith(("darkpanda", "wreq"))
            ]
            if missing_redistributables:
                raise SystemExit(
                    f"unbundled Windows runtime dependencies in {binary}: "
                    + ", ".join(missing_redistributables)
                )
            result[binary.name] = {
                "peImports": imports,
                "bundledImports": bundled,
                "operatingSystemImports": external,
            }
        elif platform == "linux":
            dynamic = run(["readelf", "-d", str(binary)])
            linked = run(["ldd", str(binary)])
            if "not found" in linked:
                raise SystemExit(f"unresolved ELF dependency in {binary}:\n{linked}")
            result[binary.name] = {
                "readelfDynamic": dynamic.splitlines(),
                "ldd": linked.splitlines(),
            }
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
    return result


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


def normalize_mode(path: Path) -> int:
    if path.name == "darkpanda" or path.suffix in {".so", ".dylib"}:
        return 0o755
    return 0o644


def payload_records(
    root: Path, excluded_names: frozenset[str] = frozenset()
) -> list[dict[str, Any]]:
    records = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.name in excluded_names:
            continue
        records.append(
            {
                "path": path.relative_to(root).as_posix(),
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


def sanitized(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9._+-]", "_", value)


def package(args: argparse.Namespace) -> None:
    repo = args.repo.resolve(strict=True)
    install = args.install_root.resolve(strict=True)
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    bin_dir = install / "bin"
    include_dir = install / "include"
    runtime = [bin_dir / name for name in RUNTIME_NAMES[args.platform]]
    missing = [str(path) for path in runtime if not path.is_file()]
    for header in ("darkpanda.h", "darkpanda_canvas_backend.h"):
        if not (include_dir / header).is_file():
            missing.append(str(include_dir / header))
    if missing:
        raise SystemExit("missing runtime bundle inputs:\n" + "\n".join(missing))

    source_epoch = args.source_date_epoch
    archive_stem = f"darkpanda-{sanitized(args.version)}-{args.target}"
    staging = output / archive_stem
    if staging.exists():
        shutil.rmtree(staging)
    (staging / "bin").mkdir(parents=True)
    (staging / "include").mkdir()
    (staging / "metadata").mkdir()

    for binary in runtime:
        shutil.copy2(binary, staging / "bin" / binary.name)
    for header in ("darkpanda.h", "darkpanda_canvas_backend.h"):
        shutil.copy2(include_dir / header, staging / "include" / header)
    for name in ("LICENSE", "README.md", "build.zig.zon"):
        shutil.copy2(repo / name, staging / ("metadata" if name == "build.zig.zon" else "") / name)
    for relative in (
        "src/wreq_transport/Cargo.lock",
        "src/canvas_backend/Cargo.lock",
        "src/html5ever/Cargo.lock",
    ):
        source = repo / relative
        shutil.copy2(source, staging / "metadata" / relative.replace("/", "-"))
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
    archive = output / f"{archive_stem}{suffix}"
    if archive.exists():
        archive.unlink()
    if args.platform == "windows":
        create_zip(staging, archive, source_epoch)
    else:
        create_tar_gz(staging, archive, source_epoch)
    archive_sha = sha256(archive)
    checksum = archive.with_name(archive.name + ".sha256")
    checksum.write_text(f"{archive_sha}  {archive.name}\n", encoding="utf-8")
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
