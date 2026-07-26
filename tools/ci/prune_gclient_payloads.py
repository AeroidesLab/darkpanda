#!/usr/bin/env python3
"""Remove verified gclient transport caches before publishing a toolchain."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys
from typing import Any


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: pathlib.Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise RuntimeError(f"expected a JSON object: {path}")
    return value


def related_metadata(payload: pathlib.Path) -> tuple[pathlib.Path, ...]:
    gcs_name = payload.name[1:]
    prefix = gcs_name.replace(".", "_")
    return (
        payload.with_name(f".{prefix}_hash"),
        payload.with_name(f".{prefix}_content_names"),
        payload.with_name(f".{prefix}_is_first_class_gcs"),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=pathlib.Path)
    parser.add_argument("--toolchain-dir", required=True, type=pathlib.Path)
    parser.add_argument("--target", required=True)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    repo = args.repo.resolve()
    toolchain = args.toolchain_dir.resolve()
    profile = load_json(repo / "tools/ci/chromium-profile.json")
    manifest = load_json(toolchain / "metadata/toolchain.json")
    if manifest.get("target") != args.target:
        raise RuntimeError(
            f"toolchain target mismatch: {manifest.get('target')} != {args.target}"
        )
    payloads = profile["gclient_transport_payloads"].get(args.target)
    if not isinstance(payloads, list) or not payloads:
        raise RuntimeError(f"no transport payload policy for {args.target}")

    removed: list[dict[str, Any]] = []
    for relative in payloads:
        payload = (toolchain / str(relative)).resolve()
        try:
            payload.relative_to(toolchain)
        except ValueError as exc:
            raise RuntimeError(f"payload escapes toolchain root: {payload}") from exc
        for path in (payload, *related_metadata(payload)):
            if not path.exists():
                continue
            if not path.is_file() or path.is_symlink():
                raise RuntimeError(f"refusing to prune non-regular payload: {path}")
            removed.append(
                {
                    "path": path.relative_to(toolchain).as_posix(),
                    "size": path.stat().st_size,
                    "sha256": sha256_file(path),
                }
            )
            path.unlink()

    remaining = [
        relative
        for relative in payloads
        if (toolchain / str(relative)).exists()
    ]
    if remaining:
        raise RuntimeError("transport payloads remain: " + ", ".join(remaining))
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(
            {
                "schema": "darkpanda-gclient-payload-prune/v1",
                "target": args.target,
                "removed": removed,
                "removedBytes": sum(item["size"] for item in removed),
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(f"removed {sum(item['size'] for item in removed)} transport bytes")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, OSError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
