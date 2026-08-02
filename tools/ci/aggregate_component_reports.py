#!/usr/bin/env python3
"""Validate and aggregate every native component report without hiding failures."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys
from typing import Any


COMPONENTS = ("canvas", "html5ever", "wreq", "boringssl")
TARGETS = (
    "windows-x86_64",
    "linux-x86_64",
    "macos-x86_64",
    "macos-aarch64",
)
REQUIRED_TEST_FRAGMENTS = {
    "canvas": ("cargo", "abi", "fma", "ninja"),
    "html5ever": ("cargo", "abi"),
    "wreq": ("cargo", "abi"),
    "boringssl": ("archive-contract", "abi", "ctest"),
}
REQUIRED_LIBRARIES = {
    ("canvas", "windows-x86_64"): "bin/canvas.dll",
    ("canvas", "linux-x86_64"): "bin/libcanvas.so",
    ("canvas", "macos-x86_64"): "bin/libcanvas.dylib",
    ("canvas", "macos-aarch64"): "bin/libcanvas.dylib",
    ("html5ever", "windows-x86_64"): "bin/html5ever.dll",
    ("html5ever", "linux-x86_64"): "bin/libhtml5ever.so",
    ("html5ever", "macos-x86_64"): "bin/libhtml5ever.dylib",
    ("html5ever", "macos-aarch64"): "bin/libhtml5ever.dylib",
    ("wreq", "windows-x86_64"): "bin/wreq.dll",
    ("wreq", "linux-x86_64"): "bin/libwreq.so",
    ("wreq", "macos-x86_64"): "bin/libwreq.dylib",
    ("wreq", "macos-aarch64"): "bin/libwreq.dylib",
    ("boringssl", "windows-x86_64"): "lib/crypto.lib",
    ("boringssl", "linux-x86_64"): "lib/libcrypto.a",
    ("boringssl", "macos-x86_64"): "lib/libcrypto.a",
    ("boringssl", "macos-aarch64"): "lib/libcrypto.a",
}
REQUIRED_CONSUMER_FILES = {
    ("canvas", "windows-x86_64"): ("include/canvas.h", "lib/canvas.lib"),
    ("canvas", "linux-x86_64"): ("include/canvas.h",),
    ("canvas", "macos-x86_64"): ("include/canvas.h",),
    ("canvas", "macos-aarch64"): ("include/canvas.h",),
    ("html5ever", "windows-x86_64"): ("lib/html5ever.dll.lib",),
    ("html5ever", "linux-x86_64"): (),
    ("html5ever", "macos-x86_64"): (),
    ("html5ever", "macos-aarch64"): (),
    ("wreq", "windows-x86_64"): (),
    ("wreq", "linux-x86_64"): (),
    ("wreq", "macos-x86_64"): (),
    ("wreq", "macos-aarch64"): (),
    ("boringssl", "windows-x86_64"): ("include/openssl/sha.h",),
    ("boringssl", "linux-x86_64"): ("include/openssl/sha.h",),
    ("boringssl", "macos-x86_64"): ("include/openssl/sha.h",),
    ("boringssl", "macos-aarch64"): ("include/openssl/sha.h",),
}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path: pathlib.Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError("JSON root is not an object")
    return value


def source_revision(build_info: dict[str, Any], component: str) -> Any:
    source = build_info.get("source")
    if isinstance(source, dict) and source.get("revision"):
        return source["revision"]
    return build_info.get(f"{component}Revision") or build_info.get("sourceRevision")


def requested_target(value: dict[str, Any]) -> Any:
    return value.get("requestedTarget") or value.get("target")


def validate_checksums(
    dist: pathlib.Path,
    checksum_path: pathlib.Path,
    errors: list[str],
) -> None:
    declared: dict[str, str] = {}
    try:
        lines = checksum_path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        errors.append(f"cannot read SHA256SUMS: {exc}")
        return
    for number, line in enumerate(lines, 1):
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match:
            errors.append(f"invalid SHA256SUMS line {number}")
            continue
        digest, relative_text = match.groups()
        relative = pathlib.PurePosixPath(relative_text)
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or "\\" in relative_text
            or relative_text in ("", ".")
        ):
            errors.append(f"unsafe SHA256SUMS path: {relative_text}")
            continue
        if relative_text in declared:
            errors.append(f"duplicate SHA256SUMS path: {relative_text}")
            continue
        declared[relative_text] = digest
        path = dist.joinpath(*relative.parts)
        if path.is_symlink():
            errors.append(f"checksummed path must not be a symlink: {relative_text}")
        elif not path.is_file():
            errors.append(f"checksummed file is missing: {relative_text}")
        elif sha256_file(path) != digest:
            errors.append(f"checksum mismatch: {relative_text}")

    actual = {
        path.relative_to(dist).as_posix()
        for path in dist.rglob("*")
        if path.is_file() and path != checksum_path
    }
    missing = sorted(actual - set(declared))
    extra = sorted(set(declared) - actual)
    if missing:
        errors.append("unchecksummed files: " + ", ".join(missing[:5]))
    if extra:
        errors.append("checksums without files: " + ", ".join(extra[:5]))


def validate_one(
    results: pathlib.Path,
    component: str,
    target: str,
    expected_revision: str,
    expected_profile: str,
) -> dict[str, Any]:
    artifact_name = f"component-{component}-{target}"
    artifact = results / artifact_name
    errors: list[str] = []
    result: dict[str, Any] = {
        "component": component,
        "target": target,
        "artifact": artifact_name,
        "status": "failed",
        "errors": errors,
    }
    if not artifact.is_dir():
        errors.append("artifact is missing")
        return result

    def unique(name: str) -> pathlib.Path | None:
        found = sorted(artifact.rglob(name))
        if len(found) != 1:
            errors.append(f"expected exactly one {name}, found {len(found)}")
            return None
        return found[0]

    test_path = unique("test-results.json")
    build_path = unique("build-info.json")
    checksum_path = unique("SHA256SUMS")
    if not test_path or not build_path or not checksum_path:
        return result
    if (
        test_path.parent.name != "metadata"
        or build_path.parent != test_path.parent
        or checksum_path.parent != test_path.parent
    ):
        errors.append("build-info, test-results, and SHA256SUMS must share metadata/")
        return result
    dist = test_path.parent.parent

    try:
        tests = read_json(test_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        errors.append(f"invalid test-results.json: {exc}")
        tests = {}
    try:
        build = read_json(build_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        errors.append(f"invalid build-info.json: {exc}")
        build = {}

    if tests.get("schema") != "darkpanda-component-test-results/v1":
        errors.append("invalid test report schema")
    if tests.get("component") != component:
        errors.append("test report component mismatch")
    if requested_target(tests) != target:
        errors.append("test report target mismatch")
    if tests.get("status") != "passed":
        errors.append(f"test report status is {tests.get('status')!r}")
    suites = tests.get("suites")
    if suites is None:
        suites = tests.get("tests")
    if not isinstance(suites, list) or not suites:
        errors.append("test report has no suites")
        suites = []
    suite_names: list[str] = []
    for suite in suites:
        if not isinstance(suite, dict):
            errors.append("test suite is not an object")
            continue
        suite_names.append(str(suite.get("name", "")).lower())
        if suite.get("status") != "passed":
            errors.append(
                f"suite {suite.get('name')!r} status is {suite.get('status')!r}"
            )
    for fragment in REQUIRED_TEST_FRAGMENTS[component]:
        if not any(fragment in name for name in suite_names):
            errors.append(f"required test suite is missing: {fragment}")

    schema = build.get("schema")
    if not isinstance(schema, str) or not schema.startswith(
        "darkpanda-component-build"
    ):
        errors.append("invalid build report schema")
    if build.get("component") != component:
        errors.append("build report component mismatch")
    if requested_target(build) != target:
        errors.append("build report target mismatch")
    if source_revision(build, component) != expected_revision:
        errors.append("build source revision does not match resolved inputs")
    source = build.get("source")
    if not isinstance(source, dict) or source.get("dirty") is not False:
        errors.append("build source is dirty or has no clean-source attestation")
    if build.get("chromiumProfileSha256") != expected_profile:
        errors.append("build Chromium profile hash mismatch")
    manifest_sha = build.get("toolchainManifestSha256")
    if not isinstance(manifest_sha, str) or not SHA256_RE.fullmatch(manifest_sha):
        errors.append("build report has no valid toolchain manifest hash")
    else:
        result["toolchainManifestSha256"] = manifest_sha

    if component == "boringssl" and target == "windows-x86_64":
        configuration = build.get("configuration")
        crt = configuration.get("crt") if isinstance(configuration, dict) else None
        if (
            not isinstance(crt, dict)
            or crt.get("linkage") != "static"
            or crt.get("flag") != "/MT"
        ):
            errors.append("BoringSSL Windows crypto archive is not audited as /MT")

    required_library = dist / REQUIRED_LIBRARIES[(component, target)]
    if not required_library.is_file():
        errors.append(
            f"required short-name artifact is missing: "
            f"{REQUIRED_LIBRARIES[(component, target)]}"
        )
    for required_relative in REQUIRED_CONSUMER_FILES[(component, target)]:
        required = dist.joinpath(*pathlib.PurePosixPath(required_relative).parts)
        if not required.is_file():
            errors.append(f"required consumer file is missing: {required_relative}")
    validate_checksums(dist, checksum_path, errors)
    if not errors:
        result["status"] = "passed"
    result["testReport"] = test_path.relative_to(artifact).as_posix()
    result["buildReport"] = build_path.relative_to(artifact).as_posix()
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", required=True, type=pathlib.Path)
    parser.add_argument("--resolved-inputs", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--markdown", required=True, type=pathlib.Path)
    args = parser.parse_args()

    top_errors: list[str] = []
    try:
        resolved = read_json(args.resolved_inputs)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        resolved = {}
        top_errors.append(f"invalid resolved-inputs.json: {exc}")
    components = resolved.get("components")
    browser_profile = resolved.get("browserProfile")
    python_binding = resolved.get("pythonBinding")
    if (
        resolved.get("schema") != "darkpanda-resolved-inputs/v5"
        or not isinstance(components, dict)
        or not isinstance(browser_profile, dict)
        or not isinstance(python_binding, dict)
        or python_binding.get("repository") != "AeroidesLab/py-darkpanda"
        or not re.fullmatch(
            r"[0-9a-f]{40}", str(python_binding.get("revision", ""))
        )
    ):
        top_errors.append("resolved inputs have no component/profile graph")
        components = {}
        browser_profile = {}
    expected_profile = str(browser_profile.get("profileSha256", ""))

    records = []
    for component in COMPONENTS:
        component_record = components.get(component)
        revision = (
            str(component_record.get("revision", ""))
            if isinstance(component_record, dict)
            else ""
        )
        for target in TARGETS:
            records.append(
                validate_one(
                    args.results.resolve(),
                    component,
                    target,
                    revision,
                    expected_profile,
                )
            )

    for target in TARGETS:
        manifests = {
            record.get("toolchainManifestSha256")
            for record in records
            if record["target"] == target
            and isinstance(record.get("toolchainManifestSha256"), str)
        }
        if len(manifests) != 1:
            top_errors.append(
                f"{target} components do not share one toolchain manifest hash"
            )

    expected_artifacts = {
        f"component-{component}-{target}"
        for component in COMPONENTS
        for target in TARGETS
    }
    if args.results.is_dir():
        observed_artifacts = {
            path.name
            for path in args.results.iterdir()
            if path.is_dir() and path.name.startswith("component-")
        }
        unexpected = sorted(observed_artifacts - expected_artifacts)
        if unexpected:
            top_errors.append("unexpected component artifacts: " + ", ".join(unexpected))

    passed = sum(record["status"] == "passed" for record in records)
    total = len(COMPONENTS) * len(TARGETS)
    summary = {
        "schema": "darkpanda-native-summary/v2",
        "status": "passed" if passed == total and not top_errors else "failed",
        "passed": passed,
        "total": total,
        "errors": top_errors,
        "results": records,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )

    lines = [
        "## Native component gate",
        "",
        "| Component | Target | Status | Error |",
        "|---|---|---|---|",
    ]
    for record in records:
        error = "; ".join(record["errors"][:2]).replace("|", "\\|")
        lines.append(
            f"| {record['component']} | {record['target']} | "
            f"{record['status']} | {error} |"
        )
    if top_errors:
        lines.extend(("", "**Gate errors:** " + "; ".join(top_errors)))
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.write_text(
        "\n".join(lines) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
