#!/usr/bin/env python3
"""Validate py-darkpanda platform results and add wheels to the release set."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath, PureWindowsPath
import re
import shutil
import zipfile


SCHEMA = "darkpanda-python-wheel/v1"
SUMMARY_SCHEMA = "darkpanda-python-aggregate/v1"
TARGETS = {
    "windows-x86_64": (
        "darkpanda.dll",
        "wreq.dll",
        "canvas.dll",
        "html5ever.dll",
        "msvcp140.dll",
        "vcruntime140.dll",
        "vcruntime140_1.dll",
    ),
    "linux-x86_64": (
        "libdarkpanda.so",
        "libwreq.so",
        "libcanvas.so",
        "libhtml5ever.so",
    ),
    "macos-x86_64": (
        "libdarkpanda.dylib",
        "libwreq.dylib",
        "libcanvas.dylib",
        "libhtml5ever.dylib",
    ),
    "macos-aarch64": (
        "libdarkpanda.dylib",
        "libwreq.dylib",
        "libcanvas.dylib",
        "libhtml5ever.dylib",
    ),
}
REQUIRED_STEPS = ("rustTest", "wheelBuild", "wheelInstall", "pythonTest")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON root is not an object: {path}")
    return value


def parse_checksum(path: Path, filename: str) -> str:
    fields = path.read_text(encoding="utf-8").strip().split()
    if (
        len(fields) != 2
        or fields[1].lstrip("*") != filename
        or not re.fullmatch(r"[0-9a-fA-F]{64}", fields[0])
    ):
        raise ValueError(f"invalid checksum file: {path}")
    return fields[0].lower()


def safe_wheel_name(name: str) -> PurePosixPath:
    if not name or "\x00" in name or "\\" in name:
        raise ValueError(f"unsafe wheel member: {name!r}")
    posix = PurePosixPath(name)
    windows = PureWindowsPath(name)
    if (
        posix.is_absolute()
        or windows.is_absolute()
        or windows.drive
        or ".." in posix.parts
    ):
        raise ValueError(f"unsafe wheel member: {name!r}")
    return posix


def validate_wheel(wheel: Path, libraries: tuple[str, ...]) -> None:
    with zipfile.ZipFile(wheel) as bundle:
        infos = bundle.infolist()
        names = [safe_wheel_name(info.filename).as_posix() for info in infos]
    if len(names) != len(set(names)):
        raise ValueError(f"wheel contains duplicate members: {wheel}")
    required = {
        "darkpanda/__init__.py",
        "darkpanda/_api.py",
        "darkpanda/_cdp.py",
        "darkpanda/_native.pyi",
        "darkpanda/py.typed",
        *(f"darkpanda/_native_libs/{name}" for name in libraries),
    }
    missing = sorted(required - set(names))
    if missing:
        raise ValueError("wheel is missing files: " + ", ".join(missing))
    extensions = [
        name
        for name in names
        if name.startswith("darkpanda/_native.")
        and name.endswith((".pyd", ".so", ".dylib"))
    ]
    if len(extensions) != 1 or "darkpanda/_native.py" in names:
        raise ValueError("wheel does not contain exactly one PyO3 extension")


def validate_target(
    root: Path,
    target_id: str,
    resolved: dict[str, object],
    release: Path,
) -> dict[str, object]:
    report_path = root / "python-reports" / f"py-darkpanda-{target_id}.json"
    report = load_json(report_path)
    binding = resolved["pythonBinding"]
    browser = resolved["darkpanda"]
    profile = resolved["browserProfile"]
    if (
        report.get("schema") != SCHEMA
        or report.get("status") != "passed"
        or report.get("target") != target_id
        or report.get("sourceRevision") != binding["revision"]  # type: ignore[index]
        or report.get("browserRevision") != browser["revision"]  # type: ignore[index]
        or report.get("chromiumProfileSha256")
        != profile["profileSha256"]  # type: ignore[index]
        or report.get("bundledLibraries") != list(TARGETS[target_id])
        or not re.fullmatch(
            r"[0-9a-f]{64}", str(report.get("toolchainManifestSha256", ""))
        )
    ):
        raise ValueError(f"Python report does not match resolved inputs: {report_path}")
    steps = report.get("steps")
    if not isinstance(steps, dict) or any(
        not isinstance(steps.get(name), dict)
        or steps[name].get("status") != "passed"  # type: ignore[index]
        for name in REQUIRED_STEPS
    ):
        raise ValueError(f"Python wheel steps did not all pass: {report_path}")
    wheel_dir = root / "python-output" / target_id
    wheels = sorted(wheel_dir.glob("*.whl"))
    if len(wheels) != 1:
        raise ValueError(f"expected one wheel for {target_id}, found {len(wheels)}")
    wheel = wheels[0]
    checksum = wheel.with_name(wheel.name + ".sha256")
    actual_sha = sha256(wheel)
    if parse_checksum(checksum, wheel.name) != actual_sha:
        raise ValueError(f"wheel checksum mismatch: {wheel}")
    wheel_record = report.get("wheel")
    if (
        not isinstance(wheel_record, dict)
        or wheel_record.get("name") != wheel.name
        or wheel_record.get("sha256") != actual_sha
        or wheel_record.get("size") != wheel.stat().st_size
    ):
        raise ValueError(f"wheel report mismatch: {wheel}")
    validate_wheel(wheel, TARGETS[target_id])
    shutil.copy2(wheel, release / wheel.name)
    shutil.copy2(checksum, release / checksum.name)
    return {
        "status": "passed",
        "wheel": wheel.name,
        "sha256": actual_sha,
        "size": wheel.stat().st_size,
    }


def write_checksums(release: Path) -> None:
    records = [
        f"{sha256(path)}  {path.name}\n"
        for path in sorted(release.iterdir())
        if path.is_file()
        and not path.name.endswith(".sha256")
        and path.name != "SHA256SUMS"
    ]
    (release / "SHA256SUMS").write_text(
        "".join(records), encoding="utf-8", newline="\n"
    )


def aggregate(args: argparse.Namespace) -> int:
    results = args.results.resolve(strict=True)
    resolved = load_json(args.resolved_inputs.resolve(strict=True))
    release = args.release_dir.resolve(strict=True)
    errors: list[str] = []
    platforms: dict[str, dict[str, object]] = {}
    binding = resolved.get("pythonBinding")
    if (
        resolved.get("schema") != "darkpanda-resolved-inputs/v6"
        or not isinstance(binding, dict)
        or binding.get("repository") != "AeroidesLab/py-darkpanda"
        or not re.fullmatch(r"[0-9a-f]{40}", str(binding.get("revision", "")))
    ):
        errors.append("resolved inputs have no valid py-darkpanda source")
    expected = {f"python-result-{target}" for target in TARGETS}
    actual = {path.name for path in results.iterdir() if path.is_dir()}
    if expected != actual:
        errors.append(
            "Python result directories differ: "
            f"missing={sorted(expected - actual)}, unexpected={sorted(actual - expected)}"
        )
    if not errors:
        for target_id in TARGETS:
            try:
                platforms[target_id] = validate_target(
                    results / f"python-result-{target_id}",
                    target_id,
                    resolved,
                    release,
                )
            except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
                platforms[target_id] = {"status": "failed", "error": str(error)}
                errors.append(f"{target_id}: {error}")
    if not errors:
        write_checksums(release)
    status = "passed" if not errors else "failed"
    payload = {
        "schema": SUMMARY_SCHEMA,
        "status": status,
        "sourceRevision": binding.get("revision") if isinstance(binding, dict) else None,
        "platforms": platforms,
        "errors": errors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    lines = [
        "## py-darkpanda wheels",
        "",
        f"- Status: `{status}`",
        "",
        "| Target | Result | Wheel |",
        "|---|---:|---|",
    ]
    for target_id in TARGETS:
        result = platforms.get(target_id, {})
        lines.append(
            f"| `{target_id}` | `{result.get('status', 'missing')}` | "
            f"`{result.get('wheel', '')}` |"
        )
    if errors:
        lines.extend(["", "### Errors", "", *(f"- {error}" for error in errors)])
    args.markdown.write_text(
        "\n".join(lines) + "\n", encoding="utf-8", newline="\n"
    )
    return 0 if not errors else 1


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--results", required=True, type=Path)
    result.add_argument("--resolved-inputs", required=True, type=Path)
    result.add_argument("--release-dir", required=True, type=Path)
    result.add_argument("--output", required=True, type=Path)
    result.add_argument("--markdown", required=True, type=Path)
    return result


def main() -> int:
    return aggregate(parser().parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
