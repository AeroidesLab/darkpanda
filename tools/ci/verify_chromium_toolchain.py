#!/usr/bin/env python3
"""Verify a gclient-materialized Chromium toolchain and write its attestation."""

from __future__ import annotations

import argparse
import hashlib
import json
import ntpath
import os
import pathlib
import subprocess
import sys
from typing import Any


TARGETS = {
    "windows-x86_64": {
        "executables": {
            "cc": "llvm/bin/clang-cl.exe",
            "cxx": "llvm/bin/clang-cl.exe",
            "linker": "llvm/bin/lld-link.exe",
            "archiver": "llvm/bin/lld-link.exe",
            "objdump": "llvm/bin/llvm-objdump.exe",
            "rustc": "rust/bin/rustc.exe",
            "cargo": "rust/bin/cargo.exe",
            "gn": "buildtools/gn.exe",
            "ninja": "buildtools/ninja.exe",
        },
        "rust_target": "x86_64-pc-windows-msvc",
        "tool_arguments": {"archiver": ["/lib"]},
    },
    "linux-x86_64": {
        "executables": {
            "cc": "llvm/bin/clang",
            "cxx": "llvm/bin/clang++",
            "linker": "llvm/bin/ld.lld",
            "archiver": "llvm/bin/llvm-ar",
            "ranlib": "llvm/bin/llvm-ranlib",
            "objdump": "llvm/bin/llvm-objdump",
            "rustc": "rust/bin/rustc",
            "cargo": "rust/bin/cargo",
            "gn": "buildtools/gn",
            "ninja": "buildtools/ninja",
        },
        "rust_target": "x86_64-unknown-linux-gnu",
        "sysroot": "sysroot",
        "tool_arguments": {},
    },
    "macos-x86_64": {
        "executables": {
            "cc": "llvm/bin/clang",
            "cxx": "llvm/bin/clang++",
            "archiver": "llvm/bin/llvm-ar",
            "objdump": "llvm/bin/llvm-objdump",
            "rustc": "rust/bin/rustc",
            "cargo": "rust/bin/cargo",
            "gn": "buildtools/gn",
            "ninja": "buildtools/ninja",
        },
        "rust_target": "x86_64-apple-darwin",
        "tool_arguments": {},
    },
    "macos-aarch64": {
        "executables": {
            "cc": "llvm/bin/clang",
            "cxx": "llvm/bin/clang++",
            "archiver": "llvm/bin/llvm-ar",
            "objdump": "llvm/bin/llvm-objdump",
            "rustc": "rust/bin/rustc",
            "cargo": "rust/bin/cargo",
            "gn": "buildtools/gn",
            "ninja": "buildtools/ninja",
        },
        "rust_target": "aarch64-apple-darwin",
        "tool_arguments": {},
    },
}


def sha256(path: pathlib.Path) -> str:
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
    files.sort(key=lambda entry: (ntpath.normcase(entry[0]), entry[0]))
    for relative_text, path in files:
        relative = relative_text.encode("utf-8")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(bytes.fromhex(sha256(path)))
        count += 1
    return digest.hexdigest(), count


def run_version(path: pathlib.Path) -> str:
    result = subprocess.run(
        [str(path), "--version"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return result.stdout.strip()


def require_within(root: pathlib.Path, relative: str) -> pathlib.Path:
    root = root.resolve()
    path = pathlib.Path(os.path.abspath(root / relative))
    resolved = path.resolve()
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise RuntimeError(f"tool escapes bundle root: {resolved}") from exc
    if not path.is_file():
        raise RuntimeError(f"required Chromium tool is missing: {path}")
    if os.name != "nt" and not os.access(path, os.X_OK):
        path.chmod(path.stat().st_mode | 0o111)
    return path


def bundle_relative(root: pathlib.Path, path: pathlib.Path) -> str:
    root = root.resolve()
    path = pathlib.Path(os.path.abspath(path))
    resolved = path.resolve()
    try:
        relative = path.relative_to(root)
        resolved.relative_to(root)
    except ValueError as exc:
        raise RuntimeError(f"path escapes bundle root: {resolved}") from exc
    if relative == pathlib.Path("."):
        raise RuntimeError(f"path does not name a bundle member: {path}")
    return relative.as_posix()


def load_json(path: pathlib.Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise RuntimeError(f"expected a JSON object: {path}")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=pathlib.Path, required=True)
    parser.add_argument("--toolchain-dir", type=pathlib.Path, required=True)
    parser.add_argument("--target", choices=sorted(TARGETS), required=True)
    parser.add_argument("--depot-tools-dir", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()

    repo = args.repo.resolve()
    toolchain = args.toolchain_dir.resolve()
    depot_tools = args.depot_tools_dir.resolve()
    profile_path = repo / "tools/ci/chromium-profile.json"
    deps_path = repo / "DEPS"
    profile = load_json(profile_path)
    deps_text = deps_path.read_text(encoding="utf-8")
    official_report_path = (
        toolchain / "metadata" / "official-chromium-deps.json"
    )
    official_deps_path = toolchain / "metadata" / "Chromium-DEPS"
    official_report = load_json(official_report_path)
    if (
        official_report.get("schema") != "darkpanda-official-chromium-deps/v1"
        or official_report.get("chromium_revision") != profile["chromium_revision"]
        or official_report.get("decoded_sha256")
        != profile["chromium_deps"]["decoded_sha256"]
        or not official_deps_path.is_file()
        or sha256(official_deps_path)
        != profile["chromium_deps"]["decoded_sha256"]
    ):
        raise RuntimeError("official Chromium DEPS attestation is invalid")

    skia_dependencies = profile["skia_git_dependencies"]
    if not isinstance(skia_dependencies, dict) or not skia_dependencies:
        raise RuntimeError("fixed profile has no Skia Git dependency graph")
    expected_literals = (
        profile["skia_revision"],
        *skia_dependencies.values(),
        profile["llvm"]["package"],
        profile["rust"]["revision"],
        profile["rust"]["paired_llvm_package"],
        profile["gn"]["cipd_version"],
        profile["ninja"]["cipd_version"],
        profile["linux_x86_64_sysroot"]["sha256"],
    )
    missing_literals = [value for value in expected_literals if str(value) not in deps_text]
    if missing_literals:
        raise RuntimeError(
            "DEPS and chromium-profile.json disagree; missing values: "
            + ", ".join(map(str, missing_literals))
        )

    target = TARGETS[args.target]
    tools = {
        name: require_within(toolchain, relative)
        for name, relative in target["executables"].items()
    }
    if "sysroot" in target:
        sysroot = (toolchain / str(target["sysroot"])).resolve()
        if not sysroot.is_dir() or not any(sysroot.iterdir()):
            raise RuntimeError(f"Chromium Linux sysroot is missing or empty: {sysroot}")
    else:
        sysroot = None

    versions = {name: run_version(path) for name, path in tools.items()}
    llvm_revision = profile["llvm"]["revision"]
    rust_revision = profile["rust"]["revision"]
    if llvm_revision not in versions["cc"]:
        raise RuntimeError(
            f"clang does not match fixed profile {llvm_revision}: {versions['cc']}"
        )
    if rust_revision not in versions["rustc"]:
        raise RuntimeError(
            f"rustc does not match fixed profile {rust_revision}: {versions['rustc']}"
        )
    expected_gn = profile["gn"]["expected_version"]
    if versions["gn"].splitlines()[0].strip() != expected_gn:
        raise RuntimeError(
            f"GN does not match fixed profile {expected_gn}: {versions['gn']}"
        )
    expected_ninja = profile["ninja"]["expected_version"]
    if versions["ninja"].splitlines()[0].strip() != expected_ninja:
        raise RuntimeError(
            f"ninja does not match fixed profile {expected_ninja}: {versions['ninja']}"
        )

    skia = toolchain / "skia"
    skia_revision = subprocess.run(
        ["git", "-C", str(skia), "rev-parse", "HEAD"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    ).stdout.strip()
    if skia_revision != profile["skia_revision"]:
        raise RuntimeError(
            f"Skia revision mismatch: {skia_revision} != {profile['skia_revision']}"
        )
    observed_skia_dependencies: dict[str, str] = {}
    for relative, expected_revision in sorted(skia_dependencies.items()):
        dependency = (skia / relative).resolve()
        try:
            dependency.relative_to(skia.resolve())
        except ValueError as exc:
            raise RuntimeError(
                f"Skia dependency escapes the checkout: {dependency}"
            ) from exc
        if not (dependency / ".git").exists():
            raise RuntimeError(f"Skia dependency is not a Git checkout: {dependency}")
        observed_revision = subprocess.run(
            ["git", "-C", str(dependency), "rev-parse", "HEAD"],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        ).stdout.strip()
        if observed_revision != expected_revision:
            raise RuntimeError(
                f"Skia dependency mismatch for {relative}: "
                f"{observed_revision} != {expected_revision}"
            )
        observed_skia_dependencies[relative] = observed_revision

    subtree_profile = profile["skia_chromium_subtrees"]
    subtree_manifest_path = (
        toolchain / "metadata" / "skia-chromium-subtrees.json"
    )
    subtree_manifest = load_json(subtree_manifest_path)
    if subtree_manifest.get("schema") != "darkpanda-skia-chromium-subtrees/v1":
        raise RuntimeError(f"invalid Chromium subtree manifest: {subtree_manifest_path}")
    if subtree_manifest.get("profile_sha256") != sha256(profile_path):
        raise RuntimeError("Chromium subtree manifest was made for another profile")
    subtree_records = subtree_manifest.get("subtrees")
    if not isinstance(subtree_records, dict) or set(subtree_records) != set(
        subtree_profile
    ):
        raise RuntimeError("Chromium subtree manifest has the wrong source set")
    observed_subtrees: dict[str, dict[str, Any]] = {}
    for relative, expected in sorted(subtree_profile.items()):
        record = subtree_records[relative]
        destination = (skia / relative).resolve()
        try:
            destination.relative_to(skia.resolve())
        except ValueError as exc:
            raise RuntimeError(
                f"Chromium subtree escapes the Skia checkout: {destination}"
            ) from exc
        if not destination.is_dir():
            raise RuntimeError(f"Chromium subtree is missing: {destination}")
        if (
            record.get("chromium_revision") != profile["chromium_revision"]
            or record.get("source_path") != expected["source_path"]
            or record.get("git_tree_id") != expected["tree_id"]
            or record.get("content_tree_sha256")
            != expected["content_tree_sha256"]
        ):
            raise RuntimeError(f"Chromium subtree provenance mismatch: {relative}")
        content_digest, file_count = tree_digest(destination)
        if (
            content_digest != record.get("content_tree_sha256")
            or file_count != record.get("file_count")
            or file_count < 1
        ):
            raise RuntimeError(f"Chromium subtree content mismatch: {relative}")
        observed_subtrees[relative] = record

    depot_revision = subprocess.run(
        ["git", "-C", str(depot_tools), "rev-parse", "HEAD"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    ).stdout.strip()

    manifest = {
        "schema": "darkpanda-chromium-toolchain/v2",
        "target": args.target,
        "profile": profile,
        "profile_sha256": sha256(profile_path),
        "deps_sha256": sha256(deps_path),
        "depot_tools_revision": depot_revision,
        "official_chromium_deps": official_report,
        "skia_revision": skia_revision,
        "skia_git_dependencies": observed_skia_dependencies,
        "skia_chromium_subtrees": observed_subtrees,
        "rust_target": target["rust_target"],
        "tool_arguments": target["tool_arguments"],
        "sysroot": bundle_relative(toolchain, sysroot) if sysroot else None,
        "tools": {
            name: {
                "path": bundle_relative(toolchain, path),
                "sha256": sha256(path),
                "version": versions[name],
            }
            for name, path in tools.items()
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError, KeyError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
