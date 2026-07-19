#!/usr/bin/env python3
"""Verify and safely extract pinned CI-only dependency source archives."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def extract(archive: Path, expected_sha: str, workspace: Path, top_level: str) -> None:
    archive = archive.resolve(strict=True)
    workspace = workspace.resolve(strict=True)
    if sha256(archive) != expected_sha:
        raise SystemExit(f"dependency source archive SHA-256 mismatch: {archive.name}")
    destination = workspace / top_level
    if destination.exists():
        raise SystemExit(f"dependency source destination already exists: {destination}")

    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        if not members:
            raise SystemExit(f"dependency source archive is empty: {archive}")
        for member in members:
            path = PurePosixPath(member.name)
            if (
                path.is_absolute()
                or ".." in path.parts
                or not path.parts
                or path.parts[0] != top_level
                or not (member.isdir() or member.isfile())
            ):
                raise SystemExit(
                    f"unsafe member in dependency source archive {archive.name}: "
                    f"{member.name}"
                )
        for member in members:
            output = workspace.joinpath(*PurePosixPath(member.name).parts)
            if member.isdir():
                output.mkdir(parents=True, exist_ok=True)
                continue
            output.parent.mkdir(parents=True, exist_ok=True)
            source = bundle.extractfile(member)
            if source is None:
                raise SystemExit(f"cannot read archive member: {member.name}")
            with source, output.open("wb") as destination_stream:
                shutil.copyfileobj(source, destination_stream)
            os.chmod(output, member.mode & 0o777)

    for required in ("build.zig", "build.zig.zon"):
        if not (destination / required).is_file():
            raise SystemExit(f"extracted dependency is missing {required}: {destination}")
    if (destination / ".git").exists():
        raise SystemExit(f"dependency source archive unexpectedly contains Git metadata: {destination}")
    print(f"verified {archive.name} -> {destination}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--asset-dir", type=Path, required=True)
    result.add_argument("--workspace", type=Path, required=True)
    result.add_argument("--zig-v8-archive", required=True)
    result.add_argument("--zig-v8-sha256", required=True)
    result.add_argument("--boringssl-archive", required=True)
    result.add_argument("--boringssl-sha256", required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    extract(
        args.asset_dir / args.zig_v8_archive,
        args.zig_v8_sha256,
        args.workspace,
        "zig-v8-fork",
    )
    extract(
        args.asset_dir / args.boringssl_archive,
        args.boringssl_sha256,
        args.workspace,
        "boringssl-zig-fork",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
