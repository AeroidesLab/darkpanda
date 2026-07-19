#!/usr/bin/env python3
"""Produce a deterministic SHA-256 proof for a source/dependency tree."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path


BUILD_OUTPUT_NAMES = {
    ".a",
    ".cargo-canvas-v2",
    ".git",
    ".lp-cache",
    "__pycache__",
    "artifacts",
    "out",
    "target",
    "zig-out",
}
BUILD_OUTPUT_PREFIXES = (".zig-cache", ".zig-global-cache", ".zig-out-")


def excluded(relative: Path, source_tree: bool) -> bool:
    if not source_tree:
        return False
    return any(
        part in BUILD_OUTPUT_NAMES or part.startswith(BUILD_OUTPUT_PREFIXES)
        for part in relative.parts
    )


def digest_tree(root: Path, source_tree: bool) -> dict[str, object]:
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise NotADirectoryError(root)

    records: list[str] = []
    file_count = 0
    symlink_count = 0
    byte_count = 0

    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        relative_directory = directory_path.relative_to(root)
        directory_names[:] = sorted(
            name
            for name in directory_names
            if not excluded(relative_directory / name, source_tree)
        )
        for name in sorted(file_names):
            path = directory_path / name
            relative = path.relative_to(root)
            if excluded(relative, source_tree):
                continue
            relative_text = relative.as_posix()
            if path.is_symlink():
                target = os.readlink(path)
                records.append(f"L\t{relative_text}\t{target}")
                symlink_count += 1
                continue
            stat = path.stat()
            sha256 = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    sha256.update(chunk)
            records.append(f"F\t{relative_text}\t{stat.st_size}\t{sha256.hexdigest()}")
            file_count += 1
            byte_count += stat.st_size

    canonical = ("\n".join(records) + "\n").encode("utf-8")
    return {
        "schema": "darkpanda-tree-proof/v1",
        "root": str(root),
        "digest": hashlib.sha256(canonical).hexdigest(),
        "fileCount": file_count,
        "symlinkCount": symlink_count,
        "byteCount": byte_count,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument(
        "--source-tree",
        action="store_true",
        help="exclude known build outputs and caches",
    )
    args = parser.parse_args()
    print(json.dumps(digest_tree(args.directory, args.source_tree), separators=(",", ":")))


if __name__ == "__main__":
    main()
