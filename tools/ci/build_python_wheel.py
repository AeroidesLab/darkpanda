#!/usr/bin/env python3
"""Build and test one py-darkpanda wheel from a verified runtime archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath, PureWindowsPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile


SCHEMA = "darkpanda-python-wheel/v1"
TARGETS = {
    "windows-x86_64": {
        "platform": "windows",
        "rust_target": "x86_64-pc-windows-msvc",
        "archive_suffix": ".zip",
        "libraries": (
            "darkpanda.dll",
            "wreq.dll",
            "canvas.dll",
            "html5ever.dll",
            "webrtc.dll",
            "msvcp140.dll",
            "vcruntime140.dll",
            "vcruntime140_1.dll",
        ),
    },
    "linux-x86_64": {
        "platform": "linux",
        "rust_target": "x86_64-unknown-linux-gnu",
        "archive_suffix": ".tar.gz",
        "libraries": (
            "libdarkpanda.so",
            "libwreq.so",
            "libcanvas.so",
            "libhtml5ever.so",
            "libwebrtc.so",
        ),
    },
    "macos-x86_64": {
        "platform": "macos",
        "rust_target": "x86_64-apple-darwin",
        "archive_suffix": ".tar.gz",
        "libraries": (
            "libdarkpanda.dylib",
            "libwreq.dylib",
            "libcanvas.dylib",
            "libhtml5ever.dylib",
            "libwebrtc.dylib",
        ),
    },
    "macos-aarch64": {
        "platform": "macos",
        "rust_target": "aarch64-apple-darwin",
        "archive_suffix": ".tar.gz",
        "libraries": (
            "libdarkpanda.dylib",
            "libwreq.dylib",
            "libcanvas.dylib",
            "libhtml5ever.dylib",
            "libwebrtc.dylib",
        ),
    },
}


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


def executable_path(path: Path) -> Path:
    """Validate an executable without replacing a venv or tool alias symlink."""
    candidate = Path(os.path.abspath(os.fspath(path)))
    resolved = candidate.resolve(strict=True)
    if not resolved.is_file():
        raise ValueError(f"executable is not a file: {candidate}")
    return candidate


def safe_archive_name(name: str) -> PurePosixPath:
    if not name or "\x00" in name or "\\" in name:
        raise ValueError(f"unsafe archive member: {name!r}")
    posix = PurePosixPath(name)
    windows = PureWindowsPath(name)
    if (
        posix.is_absolute()
        or windows.is_absolute()
        or windows.drive
        or ".." in posix.parts
        or "." in posix.parts
    ):
        raise ValueError(f"unsafe archive member: {name!r}")
    return posix


def find_runtime_archive(root: Path, suffix: str) -> Path:
    archives = sorted(
        path
        for path in root.rglob("*")
        if path.is_file() and path.name.endswith(suffix)
    )
    if len(archives) != 1:
        raise ValueError(
            f"expected exactly one {suffix} runtime archive, found {len(archives)}"
        )
    archive = archives[0]
    checksum = archive.with_name(archive.name + ".sha256")
    fields = checksum.read_text(encoding="utf-8").strip().split()
    if (
        len(fields) != 2
        or fields[1].lstrip("*") != archive.name
        or not re.fullmatch(r"[0-9a-fA-F]{64}", fields[0])
        or fields[0].lower() != sha256(archive)
    ):
        raise ValueError(f"runtime archive checksum mismatch: {archive}")
    return archive


def copy_runtime_libraries(
    archive: Path, target_id: str, destination: Path
) -> tuple[str, ...]:
    target = TARGETS[target_id]
    libraries = tuple(target["libraries"])
    destination.mkdir(parents=True, exist_ok=False)
    if target["platform"] == "windows":
        with zipfile.ZipFile(archive) as bundle:
            entries = {
                safe_archive_name(info.filename): info
                for info in bundle.infolist()
                if not info.is_dir()
            }
            roots = {name.parts[0] for name in entries}
            if len(roots) != 1:
                raise ValueError("runtime ZIP must have exactly one top-level directory")
            root = next(iter(roots))
            for library in libraries:
                member = PurePosixPath(root, "bin", library)
                if member not in entries:
                    raise ValueError(f"runtime ZIP is missing {member}")
                with bundle.open(entries[member]) as source, (
                    destination / library
                ).open("wb") as output:
                    shutil.copyfileobj(source, output)
    else:
        with tarfile.open(archive, "r:gz") as bundle:
            members: dict[PurePosixPath, tarfile.TarInfo] = {}
            for member in bundle.getmembers():
                name = safe_archive_name(member.name)
                if member.issym() or member.islnk():
                    raise ValueError(f"runtime tar contains a link: {member.name}")
                if member.isfile():
                    members[name] = member
            roots = {name.parts[0] for name in members}
            if len(roots) != 1:
                raise ValueError("runtime tar must have exactly one top-level directory")
            root = next(iter(roots))
            for library in libraries:
                member_name = PurePosixPath(root, "bin", library)
                member = members.get(member_name)
                if member is None:
                    raise ValueError(f"runtime tar is missing {member_name}")
                source = bundle.extractfile(member)
                if source is None:
                    raise ValueError(f"cannot read runtime tar member: {member_name}")
                with source, (destination / library).open("wb") as output:
                    shutil.copyfileobj(source, output)
    return libraries


def validate_source(source: Path, revision: str) -> None:
    actual = subprocess.run(
        ["git", "-C", str(source), "rev-parse", "HEAD"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    ).stdout.strip()
    if actual != revision:
        raise ValueError(f"py-darkpanda revision mismatch: {actual} != {revision}")
    status = subprocess.run(
        ["git", "-C", str(source), "status", "--porcelain=v1", "--untracked-files=all"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    ).stdout.strip()
    if status:
        raise ValueError("py-darkpanda source checkout is dirty")
    policy = load_json(source / "source-policy.json")
    if (
        policy.get("schema") != "darkpanda-source-policy/v1"
        or policy.get("component") != "py-darkpanda"
        or policy.get("build_owner") != "AeroidesLab/darkpanda"
        or policy.get("selection_policy") != "latest-main-at-build-start"
        or policy.get("artifacts") != "source-only"
        or policy.get("dependency_lockfile") != "Cargo.lock"
    ):
        raise ValueError("py-darkpanda source policy is invalid")
    if (source / ".github" / "workflows").is_dir():
        raise ValueError("py-darkpanda must not own a GitHub Actions build")


def tool_path(root: Path, record: object, name: str) -> Path:
    if not isinstance(record, dict):
        raise ValueError(f"invalid Chromium tool record: {name}")
    relative = record.get("path")
    if not isinstance(relative, str) or "\\" in relative:
        raise ValueError(f"invalid Chromium tool path: {name}")
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts:
        raise ValueError(f"unsafe Chromium tool path: {name}")
    path = root.joinpath(*pure.parts)
    resolved = path.resolve(strict=True)
    resolved.relative_to(root)
    if not path.is_file() or record.get("sha256") != sha256(path):
        raise ValueError(f"Chromium tool digest mismatch: {name}")
    return path


def load_toolchain(
    root: Path, target_id: str, profile_sha256: str
) -> tuple[dict[str, Path], str]:
    root = root.resolve(strict=True)
    manifest_path = root / "metadata" / "toolchain.json"
    manifest = load_json(manifest_path)
    if (
        manifest.get("schema") != "darkpanda-chromium-toolchain/v2"
        or manifest.get("target") != target_id
        or manifest.get("profile_sha256") != profile_sha256
        or manifest.get("rust_target") != TARGETS[target_id]["rust_target"]
    ):
        raise ValueError("Chromium toolchain manifest does not match the wheel target")
    records = manifest.get("tools")
    if not isinstance(records, dict):
        raise ValueError("Chromium toolchain manifest has no tools")
    tools = {
        name: tool_path(root, records.get(name), name)
        for name in ("cargo", "rustc", "cc", "cxx", "linker")
    }
    sysroot = manifest.get("sysroot")
    if target_id.startswith("linux-"):
        if not isinstance(sysroot, str):
            raise ValueError("Linux Chromium toolchain has no sysroot")
        pure = PurePosixPath(sysroot)
        if pure.is_absolute() or ".." in pure.parts:
            raise ValueError("unsafe Chromium sysroot path")
        path = root.joinpath(*pure.parts).resolve(strict=True)
        path.relative_to(root)
        if not path.is_dir():
            raise ValueError("Chromium sysroot is not a directory")
        tools["sysroot"] = path
    return tools, sha256(manifest_path)


def build_environment(
    tools: dict[str, Path], target_id: str, cargo_target: Path, jobs: int
) -> dict[str, str]:
    target = str(TARGETS[target_id]["rust_target"])
    key = target.upper().replace("-", "_")
    environment = os.environ.copy()
    environment["CARGO"] = str(tools["cargo"])
    environment["RUSTC"] = str(tools["rustc"])
    environment["CC"] = str(tools["cc"])
    environment["CXX"] = str(tools["cxx"])
    environment["CARGO_TARGET_DIR"] = str(cargo_target)
    environment["CARGO_BUILD_JOBS"] = str(jobs)
    environment["PYTHONIOENCODING"] = "utf-8"
    environment["PYTHONUTF8"] = "1"
    environment.pop("RUSTC_WRAPPER", None)
    environment.pop("RUSTC_WORKSPACE_WRAPPER", None)
    environment["PATH"] = os.pathsep.join(
        (
            str(tools["cargo"].parent),
            str(tools["cc"].parent),
            environment.get("PATH", ""),
        )
    )
    if target_id.startswith("windows-"):
        environment[f"CARGO_TARGET_{key}_LINKER"] = str(tools["linker"])
    elif target_id.startswith("linux-"):
        environment[f"CARGO_TARGET_{key}_LINKER"] = str(tools["cc"])
        environment[f"CARGO_TARGET_{key}_RUSTFLAGS"] = " ".join(
            (
                "-Clink-arg=-fuse-ld=lld",
                f"-Clink-arg=--ld-path={tools['linker']}",
                f"-Clink-arg=--sysroot={tools['sysroot']}",
            )
        )
    else:
        sdk = subprocess.run(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        ).stdout.strip()
        environment["SDKROOT"] = sdk
        environment["MACOSX_DEPLOYMENT_TARGET"] = "12.0"
        environment[f"CARGO_TARGET_{key}_LINKER"] = str(tools["cc"])
        environment[f"CARGO_TARGET_{key}_RUSTFLAGS"] = " ".join(
            (
                "-Clink-arg=-fuse-ld=lld",
                f"-Clink-arg=--ld-path={tools['linker']}",
                "-Clink-arg=-isysroot",
                f"-Clink-arg={sdk}",
                "-Clink-arg=-mmacosx-version-min=12.0",
            )
        )
    return environment


def rust_test_environment(
    environment: dict[str, str], target_id: str
) -> dict[str, str]:
    result = environment.copy()
    if target_id.startswith("linux-"):
        target = str(TARGETS[target_id]["rust_target"])
        key = target.upper().replace("-", "_")
        name = f"CARGO_TARGET_{key}_RUSTFLAGS"
        result[name] = " ".join(
            flag
            for flag in result[name].split()
            if "--sysroot=" not in flag
        )
    return result


def console_text(value: str) -> str:
    encoding = getattr(sys.stdout, "encoding", None) or "utf-8"
    return value.encode(encoding, errors="backslashreplace").decode(encoding)


def run_step(
    name: str,
    command: list[str],
    *,
    cwd: Path,
    environment: dict[str, str],
    steps: dict[str, object],
) -> None:
    print("+", subprocess.list2cmdline(command), flush=True)
    started = time.perf_counter()
    result = subprocess.run(
        command,
        cwd=cwd,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if result.stdout:
        print(console_text(result.stdout.rstrip()), flush=True)
    steps[name] = {
        "status": "passed" if result.returncode == 0 else "failed",
        "exitCode": result.returncode,
        "durationMs": round((time.perf_counter() - started) * 1000),
    }
    if result.returncode != 0:
        raise RuntimeError(f"{name} failed with exit code {result.returncode}")


def validate_wheel(wheel: Path, libraries: tuple[str, ...]) -> None:
    with zipfile.ZipFile(wheel) as bundle:
        names = [safe_archive_name(info.filename) for info in bundle.infolist()]
    rendered = {name.as_posix() for name in names}
    required = {
        "darkpanda/__init__.py",
        "darkpanda/_api.py",
        "darkpanda/_cdp.py",
        "darkpanda/_native.pyi",
        "darkpanda/py.typed",
        *(f"darkpanda/_native_libs/{name}" for name in libraries),
    }
    missing = sorted(required - rendered)
    if missing:
        raise ValueError("wheel is missing required files: " + ", ".join(missing))
    extensions = [
        name
        for name in rendered
        if name.startswith("darkpanda/_native.")
        and name.endswith((".pyd", ".so", ".dylib"))
    ]
    if len(extensions) != 1 or "darkpanda/_native.py" in rendered:
        raise ValueError("wheel does not contain exactly one PyO3 extension")


def write_report(path: Path, report: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def build(args: argparse.Namespace) -> int:
    target = TARGETS[args.target]
    output = args.output_dir.resolve()
    report_path = args.report.resolve()
    steps: dict[str, object] = {}
    report: dict[str, object] = {
        "schema": SCHEMA,
        "status": "failed",
        "target": args.target,
        "platform": target["platform"],
        "sourceRevision": args.source_revision,
        "browserRevision": args.browser_revision,
        "chromiumProfileSha256": args.profile_sha256,
        "steps": steps,
    }
    try:
        source = args.source.resolve(strict=True)
        runtime_results = args.runtime_results.resolve(strict=True)
        validate_source(source, args.source_revision)
        archive = find_runtime_archive(
            runtime_results, str(target["archive_suffix"])
        )
        tools, manifest_sha256 = load_toolchain(
            args.toolchain_dir, args.target, args.profile_sha256
        )
        if output.exists() and any(output.iterdir()):
            raise ValueError(f"wheel output directory is not empty: {output}")
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix=".py-darkpanda-", dir=output.parent
        ) as temporary:
            temporary_root = Path(temporary)
            stage = temporary_root / "source"
            shutil.copytree(
                source,
                stage,
                ignore=shutil.ignore_patterns(
                    ".git", "target", "__pycache__", ".pytest_cache", "*.pyc"
                ),
            )
            libraries = copy_runtime_libraries(
                archive,
                args.target,
                stage / "python" / "darkpanda" / "_native_libs",
            )
            environment = build_environment(
                tools, args.target, temporary_root / "cargo-target", args.jobs
            )
            python = str(executable_path(args.python))
            rust_target = str(target["rust_target"])
            run_step(
                "rustTest",
                [
                    str(tools["cargo"]),
                    "test",
                    "--locked",
                    "--target",
                    rust_target,
                    "--jobs",
                    str(args.jobs),
                ],
                cwd=stage,
                environment=rust_test_environment(environment, args.target),
                steps=steps,
            )
            wheel_build = temporary_root / "wheel"
            wheel_build.mkdir()
            run_step(
                "wheelBuild",
                [
                    python,
                    "-m",
                    "maturin",
                    "build",
                    "--release",
                    "--locked",
                    "--target",
                    rust_target,
                    "--jobs",
                    str(args.jobs),
                    "--interpreter",
                    python,
                    "--out",
                    str(wheel_build),
                ],
                cwd=stage,
                environment=environment,
                steps=steps,
            )
            wheels = sorted(wheel_build.glob("*.whl"))
            if len(wheels) != 1:
                raise ValueError(f"expected one wheel, found {len(wheels)}")
            validate_wheel(wheels[0], libraries)
            run_step(
                "wheelInstall",
                [
                    python,
                    "-m",
                    "pip",
                    "install",
                    "--disable-pip-version-check",
                    "--force-reinstall",
                    "--no-deps",
                    str(wheels[0]),
                ],
                cwd=stage,
                environment=environment,
                steps=steps,
            )
            test_environment = environment.copy()
            test_environment.pop("DARKPANDA_BIN_DIR", None)
            test_environment.pop("DARKPANDA_LIBRARY", None)
            run_step(
                "pythonTest",
                [python, "-m", "pytest", "-q"],
                cwd=stage,
                environment=test_environment,
                steps=steps,
            )
            wheel = output / wheels[0].name
            shutil.copy2(wheels[0], wheel)
            wheel_sha = sha256(wheel)
            wheel.with_name(wheel.name + ".sha256").write_text(
                f"{wheel_sha}  {wheel.name}\n",
                encoding="utf-8",
                newline="\n",
            )
        report.update(
            {
                "status": "passed",
                "runtimeArchive": {
                    "name": archive.name,
                    "sha256": sha256(archive),
                },
                "bundledLibraries": list(libraries),
                "toolchainManifestSha256": manifest_sha256,
                "wheel": {
                    "name": wheel.name,
                    "sha256": wheel_sha,
                    "size": wheel.stat().st_size,
                },
            }
        )
        write_report(report_path, report)
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        write_report(report_path, report)
        print(f"error: {error}", file=sys.stderr)
        return 1


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--source", required=True, type=Path)
    result.add_argument("--source-revision", required=True)
    result.add_argument("--browser-revision", required=True)
    result.add_argument("--runtime-results", required=True, type=Path)
    result.add_argument("--toolchain-dir", required=True, type=Path)
    result.add_argument("--profile-sha256", required=True)
    result.add_argument("--target", required=True, choices=sorted(TARGETS))
    result.add_argument("--python", required=True, type=Path)
    result.add_argument("--jobs", required=True, type=int)
    result.add_argument("--output-dir", required=True, type=Path)
    result.add_argument("--report", required=True, type=Path)
    return result


def main() -> int:
    return build(parser().parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
