#!/usr/bin/env python3
"""Prove the local minimal DEPS graph is derived from fixed Chromium DEPS."""

from __future__ import annotations

import argparse
import base64
import hashlib
import importlib
import json
import pathlib
import sys
import urllib.request
from collections.abc import Mapping
from typing import Any


GIT_DEPENDENCIES = {
    "browser/chromium-toolchain/skia": "src/third_party/skia",
    "browser/chromium-toolchain/skia/third_party/externals/freetype": (
        "src/third_party/freetype/src"
    ),
    "browser/chromium-toolchain/skia/third_party/externals/harfbuzz": (
        "src/third_party/harfbuzz/src"
    ),
    "browser/chromium-toolchain/skia/third_party/externals/icu": (
        "src/third_party/icu"
    ),
    "browser/chromium-toolchain/skia/third_party/externals/libjpeg-turbo": (
        "src/third_party/libjpeg_turbo"
    ),
    "browser/chromium-toolchain/skia/third_party/externals/libwebp": (
        "src/third_party/libwebp/src"
    ),
    "browser/chromium-toolchain/skia/third_party/externals/wuffs": (
        "src/third_party/wuffs/src"
    ),
}
GCS_DEPENDENCIES = {
    "browser/chromium-toolchain/llvm": (
        "src/third_party/llvm-build/Release+Asserts"
    ),
    "browser/chromium-toolchain/rust": "src/third_party/rust-toolchain",
    "browser/chromium-toolchain/sysroot": (
        "src/build/linux/debian_bullseye_amd64-sysroot"
    ),
}


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def load_json(path: pathlib.Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise RuntimeError(f"expected a JSON object: {path}")
    return value


def git_url(value: Any) -> str:
    if isinstance(value, Mapping):
        value = value.get("url")
    if not isinstance(value, str):
        value = str(value)
    return value


def object_identity(value: dict[str, Any]) -> tuple[Any, ...]:
    return (
        value.get("object_name"),
        value.get("sha256sum"),
        value.get("size_bytes"),
        value.get("generation"),
        value.get("output_file"),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=pathlib.Path)
    parser.add_argument("--depot-tools-dir", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--deps-output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    repo = args.repo.resolve()
    depot_tools = args.depot_tools_dir.resolve()
    profile_path = repo / "tools/ci/chromium-profile.json"
    local_deps_path = repo / "DEPS"
    profile = load_json(profile_path)
    revision = profile["chromium_revision"]
    expected_url = (
        "https://chromium.googlesource.com/chromium/src/+/"
        f"{revision}/DEPS?format=TEXT"
    )
    url = profile["chromium_deps"]["gitiles_url"]
    if url != expected_url:
        raise RuntimeError(f"Chromium DEPS URL is not fixed to {revision}: {url}")

    request = urllib.request.Request(
        url,
        headers={"User-Agent": "DarkPanda fixed Chromium profile verifier"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        encoded = response.read()
    try:
        decoded = base64.b64decode(b"".join(encoded.split()), validate=True)
    except ValueError as exc:
        raise RuntimeError("official Chromium DEPS response is not base64") from exc
    observed_sha = sha256_bytes(decoded)
    expected_sha = profile["chromium_deps"]["decoded_sha256"]
    if observed_sha != expected_sha:
        raise RuntimeError(
            f"official Chromium DEPS hash mismatch: {observed_sha} != {expected_sha}"
        )

    sys.path.insert(0, str(depot_tools))
    gclient_eval = importlib.import_module("gclient_eval")
    builtin_vars = {"host_os": "linux", "host_cpu": "x64"}
    official = gclient_eval.Exec(
        decoded.decode("utf-8"),
        expected_url,
        builtin_vars=builtin_vars,
    )
    local_text = local_deps_path.read_text(encoding="utf-8")
    local = gclient_eval.Exec(
        local_text,
        str(local_deps_path),
        builtin_vars=builtin_vars,
    )

    official_vars = official["vars"]
    local_vars = local["vars"]
    expected_vars = {
        "skia_revision": profile["skia_revision"],
        "gn_version": profile["gn"]["cipd_version"],
        "ninja_version": profile["ninja"]["cipd_version"],
    }
    for name, expected in expected_vars.items():
        official_value = str(official_vars.get(name))
        local_value = str(local_vars.get(name))
        if official_value != expected or local_value != expected:
            raise RuntimeError(
                f"{name} mismatch: official={official_value!r}, "
                f"local={local_value!r}, profile={expected!r}"
            )

    git_records: dict[str, str] = {}
    for local_name, official_name in GIT_DEPENDENCIES.items():
        local_url = git_url(local["deps"].get(local_name))
        official_url = git_url(official["deps"].get(official_name))
        if local_url != official_url:
            raise RuntimeError(
                f"Git dependency mismatch for {local_name}: "
                f"{local_url!r} != {official_url!r}"
            )
        if local_name.endswith("/skia"):
            profile_revision = profile["skia_revision"]
        else:
            relative = local_name.split("/skia/", 1)[1]
            profile_revision = profile["skia_git_dependencies"].get(relative)
        if not profile_revision or not local_url.endswith(f"@{profile_revision}"):
            raise RuntimeError(
                f"profile revision mismatch for {local_name}: {profile_revision!r}"
            )
        git_records[local_name] = local_url

    gcs_records: dict[str, list[dict[str, Any]]] = {}
    for local_name, official_name in GCS_DEPENDENCIES.items():
        local_dep = local["deps"].get(local_name)
        official_dep = official["deps"].get(official_name)
        if not isinstance(local_dep, Mapping) or not isinstance(
            official_dep, Mapping
        ):
            raise RuntimeError(f"missing structured GCS dependency: {local_name}")
        if (
            local_dep.get("dep_type") != "gcs"
            or local_dep.get("bucket") != official_dep.get("bucket")
        ):
            raise RuntimeError(f"GCS bucket/type mismatch: {local_name}")
        official_objects = {
            object_identity(item) for item in official_dep.get("objects", [])
        }
        observed = []
        for item in local_dep.get("objects", []):
            identity = object_identity(item)
            if identity not in official_objects:
                raise RuntimeError(
                    f"GCS object is not in Chromium {revision}: {identity[0]}"
                )
            observed.append(
                {
                    key: item[key]
                    for key in (
                        "object_name",
                        "sha256sum",
                        "size_bytes",
                        "generation",
                    )
                    if key in item
                }
            )
        if not observed:
            raise RuntimeError(f"local GCS dependency is empty: {local_name}")
        gcs_records[local_name] = observed

    args.deps_output.parent.mkdir(parents=True, exist_ok=True)
    args.deps_output.write_bytes(decoded)
    report = {
        "schema": "darkpanda-official-chromium-deps/v1",
        "chromium_revision": revision,
        "gitiles_url": url,
        "decoded_sha256": observed_sha,
        "local_deps_sha256": sha256_bytes(local_text.encode("utf-8")),
        "variables": expected_vars,
        "git_dependencies": git_records,
        "gcs_dependencies": gcs_records,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        KeyError,
        OSError,
        RuntimeError,
        UnicodeError,
        json.JSONDecodeError,
    ) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
