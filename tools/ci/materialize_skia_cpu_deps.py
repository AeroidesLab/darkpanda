#!/usr/bin/env python3
"""Materialize Chromium-owned source subtrees required by CPU-only Skia."""

from __future__ import annotations

import argparse
import hashlib
import json
import ntpath
import os
import pathlib
import shutil
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from typing import Any

RETRYABLE_HTTP_STATUS = frozenset({408, 425, 429, 500, 502, 503, 504})


def open_url_with_retry(
    request: urllib.request.Request,
    *,
    timeout_seconds: float = 120,
    max_attempts: int = 6,
    initial_backoff_seconds: float = 2,
    max_backoff_seconds: float = 30,
    sleep: Callable[[float], None] = time.sleep,
) -> Any:
    """Open a URL with bounded retries for transient transport failures."""
    if max_attempts < 1:
        raise ValueError("max_attempts must be positive")
    if initial_backoff_seconds < 0 or max_backoff_seconds < 0:
        raise ValueError("retry backoff must be non-negative")

    for attempt in range(1, max_attempts + 1):
        try:
            return urllib.request.urlopen(request, timeout=timeout_seconds)
        except urllib.error.HTTPError as exc:
            if exc.code not in RETRYABLE_HTTP_STATUS or attempt == max_attempts:
                raise
            retry_after = exc.headers.get("Retry-After") if exc.headers else None
            try:
                retry_after_seconds = float(retry_after) if retry_after else 0
            except ValueError:
                retry_after_seconds = 0
            backoff = initial_backoff_seconds * (2 ** (attempt - 1))
            delay = min(max(backoff, retry_after_seconds), max_backoff_seconds)
            reason = f"HTTP {exc.code}"
            exc.close()
        except (urllib.error.URLError, TimeoutError) as exc:
            if attempt == max_attempts:
                raise
            backoff = initial_backoff_seconds * (2 ** (attempt - 1))
            delay = min(backoff, max_backoff_seconds)
            reason = type(exc).__name__

        print(
            f"warning: {reason} while fetching {request.full_url}; "
            f"retrying in {delay:g}s ({attempt}/{max_attempts})",
            file=sys.stderr,
        )
        sleep(delay)

    raise AssertionError("unreachable retry loop")


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_digest(root: pathlib.Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    count = 0
    files = [
        (path.relative_to(root).as_posix(), path)
        for path in root.rglob("*")
        if path.is_file()
    ]
    # The fixed profile digests were generated from WindowsPath ordering,
    # which normalizes both case and path separators.  Apply that comparison
    # key explicitly so every runner hashes the same byte stream.  The original
    # spelling is a deterministic tie-breaker for paths that normalize equally.
    files.sort(key=lambda entry: (ntpath.normcase(entry[0]), entry[0]))
    for relative_text, path in files:
        relative = relative_text.encode("utf-8")
        content_digest = bytes.fromhex(sha256_file(path))
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(content_digest)
        count += 1
    return digest.hexdigest(), count


def load_json(path: pathlib.Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise RuntimeError(f"expected a JSON object: {path}")
    return value


def safe_extract(archive_path: pathlib.Path, destination: pathlib.Path) -> None:
    with tarfile.open(archive_path, mode="r:gz") as archive:
        for member in archive.getmembers():
            normalized = member.name.replace("\\", "/")
            while normalized.startswith("./"):
                normalized = normalized[2:]
            relative = pathlib.PurePosixPath(normalized)
            if (
                not normalized
                or relative.is_absolute()
                or ".." in relative.parts
                or member.issym()
                or member.islnk()
                or member.isdev()
            ):
                raise RuntimeError(f"unsafe Gitiles archive member: {member.name!r}")
            output = destination.joinpath(*relative.parts)
            if member.isdir():
                output.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                raise RuntimeError(
                    f"unsupported Gitiles archive member: {member.name!r}"
                )
            output.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise RuntimeError(f"cannot read archive member: {member.name!r}")
            with source, output.open("wb") as target:
                shutil.copyfileobj(source, target)
            if os.name != "nt":
                output.chmod(member.mode & 0o777)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=pathlib.Path)
    parser.add_argument("--toolchain-dir", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    repo = args.repo.resolve()
    toolchain = args.toolchain_dir.resolve()
    skia = (toolchain / "skia").resolve()
    profile_path = repo / "tools/ci/chromium-profile.json"
    profile = load_json(profile_path)
    revision = str(profile["chromium_revision"])
    if len(revision) != 40 or any(char not in "0123456789abcdef" for char in revision):
        raise RuntimeError(f"invalid Chromium revision: {revision!r}")
    subtrees = profile["skia_chromium_subtrees"]
    if not isinstance(subtrees, dict) or not subtrees:
        raise RuntimeError("fixed profile has no Chromium subtree sources")
    if not (skia / ".git").exists():
        raise RuntimeError(f"Skia is not a Git checkout: {skia}")

    records: dict[str, dict[str, Any]] = {}
    for relative, entry in sorted(subtrees.items()):
        if not isinstance(entry, dict):
            raise RuntimeError(f"invalid subtree profile entry: {relative}")
        source_path = str(entry["source_path"]).strip("/")
        expected_tree = str(entry["tree_id"])
        expected_content = str(entry["content_tree_sha256"])
        destination = (skia / relative).resolve()
        try:
            destination.relative_to(skia)
        except ValueError as exc:
            raise RuntimeError(
                f"subtree destination escapes the Skia checkout: {destination}"
            ) from exc
        if destination.exists():
            raise RuntimeError(
                f"subtree destination already exists before materialization: {destination}"
            )

        encoded_path = urllib.parse.quote(source_path, safe="/")
        metadata_url = (
            "https://chromium.googlesource.com/chromium/src/+/"
            f"{revision}/{encoded_path}?format=JSON"
        )
        url = (
            "https://chromium.googlesource.com/chromium/src/+archive/"
            f"{revision}/{encoded_path}.tar.gz"
        )
        metadata_request = urllib.request.Request(
            metadata_url,
            headers={"User-Agent": "DarkPanda fixed Chromium profile materializer"},
        )
        with open_url_with_retry(metadata_request) as response:
            metadata_bytes = response.read()
        xssi_prefix = b")]}'\n"
        if not metadata_bytes.startswith(xssi_prefix):
            raise RuntimeError(f"invalid Gitiles metadata response: {metadata_url}")
        source_metadata = json.loads(
            metadata_bytes[len(xssi_prefix) :].decode("utf-8")
        )
        if source_metadata.get("id") != expected_tree:
            raise RuntimeError(
                f"Git tree mismatch for {source_path}: "
                f"{source_metadata.get('id')} != {expected_tree}"
            )
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix=f"darkpanda-{destination.name}-",
            dir=destination.parent,
        ) as temporary_name:
            temporary = pathlib.Path(temporary_name)
            archive_path = temporary / "source.tar.gz"
            request = urllib.request.Request(
                url,
                headers={"User-Agent": "DarkPanda fixed Chromium profile materializer"},
            )
            with (
                open_url_with_retry(request) as response,
                archive_path.open("wb") as stream,
            ):
                shutil.copyfileobj(response, stream)
            observed_archive = sha256_file(archive_path)
            extracted = temporary / "extracted"
            extracted.mkdir()
            safe_extract(archive_path, extracted)
            observed_content, file_count = tree_digest(extracted)
            if file_count == 0:
                raise RuntimeError(f"Chromium subtree is empty: {source_path}")
            if observed_content != expected_content:
                raise RuntimeError(
                    f"content tree mismatch for {source_path}: "
                    f"{observed_content} != {expected_content}"
                )
            shutil.move(str(extracted), str(destination))

        records[relative] = {
            "kind": "chromium-subtree",
            "source_path": source_path,
            "chromium_revision": revision,
            "git_tree_id": expected_tree,
            "metadata_url": metadata_url,
            "archive_url": url,
            "transport_archive_sha256": observed_archive,
            "content_tree_sha256": observed_content,
            "file_count": file_count,
        }

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(
            {
                "schema": "darkpanda-skia-chromium-subtrees/v1",
                "profile_sha256": sha256_file(profile_path),
                "subtrees": records,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, OSError, RuntimeError, tarfile.TarError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
