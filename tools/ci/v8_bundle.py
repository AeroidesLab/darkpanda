#!/usr/bin/env python3
"""Create and verify the cache contract for a source-built V8 archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
from typing import Any


SCHEMA = "darkpanda-ci-v8-bundle/v2"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def expected_fields(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "buildMode": args.build_mode,
        "platform": args.platform,
        "target": args.target,
        "v8Version": args.v8_version,
        "v8Revision": args.v8_revision,
        "zigV8SourceRevision": args.zig_v8_source_revision,
        "zigVersion": args.zig_version,
    }


def create(args: argparse.Namespace) -> None:
    archive = args.archive.resolve(strict=True)
    manifest = args.manifest.resolve()
    if not archive.is_file() or archive.stat().st_size == 0:
        raise SystemExit(f"V8 archive is empty or not a file: {archive}")
    if manifest.parent != archive.parent:
        raise SystemExit("the V8 archive and manifest must share one cache directory")

    payload = expected_fields(args)
    payload["archive"] = {
        "name": archive.name,
        "size": archive.stat().st_size,
        "sha256": sha256(archive),
    }
    payload["completeRuntimeArtifact"] = False
    payload["cacheContract"] = {
        "immutableInputs": True,
        "browserOutputsIncluded": False,
    }
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(payload, separators=(",", ":"), sort_keys=True))


def verify(args: argparse.Namespace) -> None:
    manifest = args.manifest.resolve(strict=True)
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    for key, value in expected_fields(args).items():
        if payload.get(key) != value:
            raise SystemExit(
                f"V8 cache manifest mismatch for {key}: "
                f"expected {value!r}, got {payload.get(key)!r}"
            )
    if payload.get("completeRuntimeArtifact") is not False:
        raise SystemExit("V8 cache must be marked as a dependency, not a runtime artifact")
    cache_contract = payload.get("cacheContract") or {}
    if cache_contract.get("browserOutputsIncluded") is not False:
        raise SystemExit("V8 cache contract unexpectedly contains browser outputs")

    record = payload.get("archive") or {}
    archive = manifest.parent / str(record.get("name", ""))
    archive = archive.resolve(strict=True)
    if os.path.commonpath((str(manifest.parent), str(archive))) != str(
        manifest.parent
    ):
        raise SystemExit("V8 archive escaped its cache directory")
    if archive.stat().st_size != record.get("size"):
        raise SystemExit("V8 archive size does not match the cache manifest")
    actual_sha = sha256(archive)
    if actual_sha != record.get("sha256"):
        raise SystemExit("V8 archive SHA-256 does not match the cache manifest")
    print(str(archive))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    subparsers = result.add_subparsers(dest="command", required=True)
    for name in ("create", "verify"):
        command = subparsers.add_parser(name)
        command.add_argument("--manifest", type=Path, required=True)
        command.add_argument("--build-mode", choices=("source",), required=True)
        if name == "create":
            command.add_argument("--archive", type=Path, required=True)
        command.add_argument("--platform", required=True)
        command.add_argument("--target", required=True)
        command.add_argument("--v8-version", required=True)
        command.add_argument("--v8-revision", required=True)
        command.add_argument("--zig-v8-source-revision", required=True)
        command.add_argument("--zig-version", required=True)
        command.set_defaults(handler=create if name == "create" else verify)
    return result


def main() -> int:
    args = parser().parse_args()
    args.handler(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
