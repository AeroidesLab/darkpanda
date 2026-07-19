#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/Build-LinuxArtifactSet.sh \
  --zig /absolute/path/to/zig \
  --cargo /absolute/path/to/cargo \
  --rustc /absolute/path/to/rustc \
  --v8-bundle-manifest /absolute/path/to/manifest.json \
  --cargo-vendor /absolute/path/to/vendor \
  --skia-source /absolute/path/to/skia \
  --skia-gn /absolute/path/to/gn \
  --skia-ninja /absolute/path/to/ninja \
  --cmake-root /absolute/path/to/cmake-root \
  --zig-package-cache /absolute/path/to/zig/p \
  [--native-cache-root /absolute/path] \
  [--output-root /absolute/path] [--version VERSION] [--jobs N]

The build is network-offline. Dependency source trees and tools are copied
into a unique build root; compiler objects and old install directories are
never imported.
EOF
}

zig=""
cargo=""
rustc=""
v8_bundle_manifest=""
v8=""
cargo_vendor=""
skia_source=""
skia_gn=""
skia_ninja=""
cmake_root=""
zig_package_cache=""
native_cache_parent="${DARKPANDA_LINUX_NATIVE_CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/darkpanda/native-zig}"
default_output_root="${HOME}/darkpanda-builds"
output_root="${DARKPANDA_LINUX_BUILD_ROOT:-$default_output_root}"
version=""
jobs=2

while (($#)); do
  case "$1" in
    --zig) zig=${2:?}; shift 2 ;;
    --cargo) cargo=${2:?}; shift 2 ;;
    --rustc) rustc=${2:?}; shift 2 ;;
    --v8-bundle-manifest) v8_bundle_manifest=${2:?}; shift 2 ;;
    --cargo-vendor) cargo_vendor=${2:?}; shift 2 ;;
    --skia-source) skia_source=${2:?}; shift 2 ;;
    --skia-gn) skia_gn=${2:?}; shift 2 ;;
    --skia-ninja) skia_ninja=${2:?}; shift 2 ;;
    --cmake-root) cmake_root=${2:?}; shift 2 ;;
    --zig-package-cache) zig_package_cache=${2:?}; shift 2 ;;
    --native-cache-root) native_cache_parent=${2:?}; shift 2 ;;
    --output-root) output_root=${2:?}; shift 2 ;;
    --version) version=${2:?}; shift 2 ;;
    --jobs) jobs=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for name in zig cargo rustc v8_bundle_manifest cargo_vendor skia_source skia_gn skia_ninja cmake_root zig_package_cache; do
  if [[ -z ${!name} ]]; then
    echo "missing required --${name//_/-}" >&2
    exit 2
  fi
done
if [[ ! $jobs =~ ^[1-9][0-9]*$ ]]; then
  echo "--jobs must be a positive integer" >&2
  exit 2
fi

real_file() {
  local path
  path=$(realpath -e -- "$1")
  [[ -f $path ]] || { echo "not a file: $path" >&2; exit 2; }
  printf '%s' "$path"
}
real_command_file() {
  local path=$1 directory base
  if [[ $path != /* ]]; then
    path=$PWD/$path
  fi
  directory=$(realpath -e -- "$(dirname -- "$path")")
  base=$(basename -- "$path")
  path=$directory/$base
  [[ -f $path ]] || { echo "not a command file: $path" >&2; exit 2; }
  printf '%s' "$path"
}
real_dir() {
  local path
  path=$(realpath -e -- "$1")
  [[ -d $path ]] || { echo "not a directory: $path" >&2; exit 2; }
  printf '%s' "$path"
}
require_elf_command() {
  local path=$1 magic
  [[ -x $path ]] || { echo "tool is not executable: $path" >&2; exit 2; }
  magic=$(od -An -tx1 -N4 -- "$path" | tr -d ' \n')
  [[ $magic == 7f454c46 ]] || {
    echo "tool is not a standalone ELF executable: $path" >&2
    exit 2
  }
}

zig=$(real_command_file "$zig")
# Preserve Cargo's rustup proxy path. Resolving the final symlink changes
# argv[0] from `cargo` to `rustup` and breaks proxy dispatch.
cargo=$(real_command_file "$cargo")
rustc=$(real_command_file "$rustc")
v8_bundle_manifest=$(real_file "$v8_bundle_manifest")
cargo_vendor=$(real_dir "$cargo_vendor")
skia_source=$(real_dir "$skia_source")
skia_gn=$(real_file "$skia_gn")
skia_ninja=$(real_file "$skia_ninja")
cmake_root=$(real_dir "$cmake_root")
cmake=$(real_file "$cmake_root/bin/cmake")
zig_package_cache=$(real_dir "$zig_package_cache")
output_root=$(realpath -m -- "$output_root")
native_cache_parent=$(realpath -m -- "$native_cache_parent")
[[ $native_cache_parent == /* && $native_cache_parent != / ]] || {
  echo "unsafe native cache parent: $native_cache_parent" >&2
  exit 2
}
require_elf_command "$skia_gn"
require_elf_command "$skia_ninja"
require_elf_command "$cmake"

repo_root=$(realpath -e -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
python=${PYTHON:-$(command -v python3)}
proof_tool="$repo_root/tools/tree_digest.py"
[[ -f $proof_tool ]] || { echo "missing tree proof tool: $proof_tool" >&2; exit 2; }

# A formal build never accepts a loose V8 archive. The acquisition manifest
# binds the archive to the exact V8 revision, Linux target, build root, size,
# and SHA-256. This rejects an old or manually substituted libc_v8.a before a
# unique artifact root is created.
v8=$(
  "$python" - "$v8_bundle_manifest" <<'PY'
from __future__ import annotations
import hashlib, json, os, sys
from pathlib import Path

manifest_path = Path(sys.argv[1]).resolve(strict=True)
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
expected = {
    "schema": "darkpanda-dependency-bundle/v1",
    "component": "zig-v8-linux-x64",
    "target": "x86_64-linux-gnu",
    "v8Version": "14.9.207.35",
    "v8Revision": "933ce636c562cd54d68e7f7c93ab5cdffd685fca",
}
for key, value in expected.items():
    if manifest.get(key) != value:
        raise SystemExit(f"V8 bundle manifest {key!r} mismatch: {manifest.get(key)!r}")
if manifest.get("completeAcceptanceArtifact") is not False:
    raise SystemExit("V8 bundle manifest must identify a dependency, not an acceptance artifact")
if manifest.get("networkAcquisition") is not True:
    raise SystemExit("V8 bundle manifest is missing its acquisition provenance")

root = Path(manifest["buildRoot"]).resolve(strict=True)
if manifest_path != root / "manifest.json":
    raise SystemExit("V8 bundle manifest is not the manifest owned by buildRoot")
archive_record = manifest.get("archive") or {}
if archive_record.get("linuxPicRequired") is not True:
    raise SystemExit("V8 bundle does not assert the Linux PIC requirement")
archive = Path(archive_record["path"]).resolve(strict=True)
if os.path.commonpath((str(root), str(archive))) != str(root):
    raise SystemExit("V8 archive is outside its declared bundle root")

def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

if archive.stat().st_size != archive_record.get("size"):
    raise SystemExit("V8 archive size does not match its bundle manifest")
if sha(archive) != archive_record.get("sha256"):
    raise SystemExit("V8 archive SHA-256 does not match its bundle manifest")

symbol_record = manifest.get("requiredSymbolProof") or {}
symbol_path = Path(symbol_record["path"]).resolve(strict=True)
if os.path.commonpath((str(root), str(symbol_path))) != str(root):
    raise SystemExit("V8 symbol proof is outside its declared bundle root")
if sha(symbol_path) != symbol_record.get("sha256"):
    raise SystemExit("V8 symbol proof SHA-256 does not match its bundle manifest")
symbols = symbol_path.read_text(encoding="utf-8", errors="replace")
required = (
    "v8__ForegroundWake__Acquire",
    "v8__ForegroundWake__Post",
    "v8__Platform__NotifyIsolateShutdown",
    "v8__Isolate__SetFailedAccessCheckCallbackFunction",
    "v8__ArrayBuffer__Detach",
    "v8__Value__StrictEquals",
    "v8__WasmStreaming__Finish",
)
for symbol in required:
    if not any(line.rstrip().endswith(" " + symbol) for line in symbols.splitlines()):
        raise SystemExit(f"V8 symbol proof is missing {symbol}")
print(archive)
PY
)
v8=$(real_file "$v8")

stamp=$(date -u +%Y%m%dT%H%M%SZ)
nonce=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
build_id="linux-x64-${stamp}-${nonce}"
build_root="$output_root/$build_id"
native_cache_root="$native_cache_parent/$build_id"
[[ ! -e $build_root ]] || { echo "unique build root exists: $build_root" >&2; exit 2; }
[[ ! -e $native_cache_root ]] || {
  echo "unique native cache root exists: $native_cache_root" >&2
  exit 2
}
case "$native_cache_root" in
  "$native_cache_parent"/"$build_id") ;;
  *) echo "native cache escaped its parent: $native_cache_root" >&2; exit 2 ;;
esac
mkdir -p "$build_root"/{i,r,ch,wreq-target,canvas-target,deps/tools} \
  "$native_cache_root"/{c,g}
native_cache_fs=$(stat -f -c %T -- "$native_cache_root")
case "$native_cache_fs" in
  9p|drvfs)
    echo "Zig cache cannot use DrvFS/9p because Windows locks the running build executable: $native_cache_root" >&2
    exit 2
    ;;
esac
cleanup_native_cache() {
  if [[ -n ${native_cache_root:-} && -d $native_cache_root ]]; then
    rm -rf -- "$native_cache_root"
  fi
}
trap cleanup_native_cache EXIT INT TERM

"$python" - "$build_root/native-zig-cache.json" "$native_cache_root" "$native_cache_fs" <<'PY'
import json, sys
from pathlib import Path

output, cache, filesystem = sys.argv[1:]
Path(output).write_text(json.dumps({
    "path": cache,
    "filesystemType": filesystem,
    "ephemeral": True,
    "cleanedOnExit": True,
    "reason": "Zig executes its cache build runner; DrvFS forbids renaming an executing file",
}, indent=2) + "\n", encoding="utf-8")
PY

if [[ -z $version ]]; then
  version="1.0.0-linux.${stamp}"
fi

"$python" "$proof_tool" "$repo_root" --source-tree > "$build_root/source-before.json"
"$python" "$proof_tool" "$cargo_vendor" > "$build_root/cargo-vendor-input.json"
"$python" "$proof_tool" "$skia_source" > "$build_root/skia-source-input.json"
"$python" "$proof_tool" "$cmake_root" > "$build_root/cmake-input.json"
"$python" "$proof_tool" "$zig_package_cache" > "$build_root/zig-package-cache-input.json"

# Source-only imports. Never copy a target directory, object, library, or old
# install tree into this build.
cp -a -- "$cargo_vendor" "$build_root/deps/cargo-vendor"
cp -a -- "$skia_source" "$build_root/deps/skia"
cp -a -- "$cmake_root" "$build_root/deps/tools/cmake"
cp -a -- "$zig_package_cache" "$native_cache_root/g/p"
cp -a -- "$v8" "$build_root/deps/libc_v8.a"
cp -a -- "$v8_bundle_manifest" "$build_root/deps/v8-bundle-manifest.json"
cp -a -- "$skia_gn" "$build_root/deps/tools/gn"
cp -a -- "$skia_ninja" "$build_root/deps/tools/ninja"
chmod +x "$build_root/deps/tools/gn" "$build_root/deps/tools/ninja"

"$zig" version > "$build_root/zig-version.txt"
"$cargo" --version --verbose > "$build_root/cargo-version.txt"
"$rustc" --version --verbose > "$build_root/rustc-version.txt"
"$build_root/deps/tools/gn" --version > "$build_root/gn-version.txt"
"$build_root/deps/tools/ninja" --version > "$build_root/ninja-version.txt"
"$build_root/deps/tools/cmake/bin/cmake" --version > "$build_root/cmake-version.txt"

"$python" "$proof_tool" "$build_root/deps/cargo-vendor" > "$build_root/cargo-vendor-copy-before.json"
"$python" "$proof_tool" "$build_root/deps/skia" > "$build_root/skia-source-copy-before.json"
"$python" "$proof_tool" "$build_root/deps/tools/cmake" > "$build_root/cmake-copy-before.json"
"$python" "$proof_tool" "$native_cache_root/g/p" > "$build_root/zig-package-cache-copy-before.json"
"$python" - "$build_root" <<'PY'
import json, sys
from pathlib import Path

root = Path(sys.argv[1])
for label in ("cargo-vendor", "skia-source", "cmake", "zig-package-cache"):
    source = json.loads((root / f"{label}-input.json").read_text())
    copied = json.loads((root / f"{label}-copy-before.json").read_text())
    keys = ("digest", "fileCount", "symlinkCount", "byteCount")
    if tuple(source[key] for key in keys) != tuple(copied[key] for key in keys):
        raise SystemExit(f"{label} copy does not match its source proof")
PY
"$python" "$repo_root/tools/prepare_cargo_vendor.py" "$build_root/deps/cargo-vendor" \
  > "$build_root/cargo-vendor-preparation.json"
"$python" "$proof_tool" "$build_root/deps/cargo-vendor" \
  > "$build_root/cargo-vendor-prepared-before.json"

cat > "$build_root/ch/config.toml" <<EOF
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$build_root/deps/cargo-vendor"

[net]
offline = true
EOF

export CARGO_HOME="$build_root/ch"
export CARGO_INCREMENTAL=0
export CARGO_NET_OFFLINE=true
export CARGO_BUILD_JOBS="$jobs"
export CMAKE_BUILD_PARALLEL_LEVEL="$jobs"
export RUSTC="$rustc"
unset CARGO_TARGET_DIR RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER RUSTFLAGS CARGO_ENCODED_RUSTFLAGS
export SKIA_SOURCE_DIR="$build_root/deps/skia"
export SKIA_GN_COMMAND="$build_root/deps/tools/gn"
export SKIA_NINJA_COMMAND="$build_root/deps/tools/ninja"
export SKIA_GN_ARGS="skia_use_fontconfig=false"
export FORCE_SKIA_BUILD=1
export CMAKE="$build_root/deps/tools/cmake/bin/cmake"
export CMAKE_GENERATOR="Ninja"
export PATH="$build_root/deps/tools/cmake/bin:$build_root/deps/tools:$PATH"
# Formal compilation must consume only the materialized inputs above. Cargo is
# in native offline mode; the dead proxy also makes accidental Zig/build-script
# downloads fail immediately instead of silently changing the dependency set.
export HTTP_PROXY="http://127.0.0.1:9"
export HTTPS_PROXY="$HTTP_PROXY"
export ALL_PROXY="$HTTP_PROXY"
export http_proxy="$HTTP_PROXY"
export https_proxy="$HTTP_PROXY"
export all_proxy="$HTTP_PROXY"
export NO_PROXY=""
export no_proxy=""
export GIT_TERMINAL_PROMPT=0

set +e
(
  cd "$repo_root"
  "$zig" build install canvas-backend \
    "-j${jobs}" \
    -Dtarget=x86_64-linux-gnu \
    -Doptimize=ReleaseFast \
    "-Dprebuilt_v8_path=$build_root/deps/libc_v8.a" \
    "-Dwreq_transport_target_dir=$build_root/wreq-target" \
    "-Dcanvas_backend_target_dir=$build_root/canvas-target" \
    "-Dcargo_path=$cargo" \
    "-Dversion=$version" \
    -p "$build_root/i" \
    --cache-dir "$native_cache_root/c" \
    --global-cache-dir "$native_cache_root/g" \
    --summary all
) > "$build_root/build.log" 2>&1
build_exit=$?
set -e
if ((build_exit != 0)); then
  printf 'Linux build failed (%d); log=%s\n' "$build_exit" "$build_root/build.log" >&2
  tail -120 "$build_root/build.log" >&2
  exit "$build_exit"
fi

for required in \
  "$build_root/i/bin/darkpanda" \
  "$build_root/i/bin/libdarkpanda.so" \
  "$build_root/i/bin/libwreq.so" \
  "$build_root/i/bin/libdarkpanda_html5ever.so" \
  "$build_root/i/bin/libdarkpanda_canvas_backend.so"; do
  [[ -f $required ]] || { echo "missing runtime output: $required" >&2; exit 1; }
done

# Record and verify the exact candidate artifact set before executing any of
# its binaries. All runtime checks below consume only these absolute paths.
"$python" - "$build_root" "$build_id" "$version" <<'PY'
import hashlib, json, sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
build_id, version = sys.argv[2:]
roles = {
    "browser_exe": root / "i/bin/darkpanda",
    "ffi_library": root / "i/bin/libdarkpanda.so",
    "wreq_library": root / "i/bin/libwreq.so",
    "html_parser_library": root / "i/bin/libdarkpanda_html5ever.so",
    "canvas_backend_library": root / "i/bin/libdarkpanda_canvas_backend.so",
}

def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

record = {
    "schema": "darkpanda-candidate-artifact-set/v1",
    "buildId": build_id,
    "target": "x86_64-linux-gnu",
    "version": version,
    "artifacts": [
        {
            "role": role,
            "path": str(path.resolve(strict=True)),
            "size": path.stat().st_size,
            "sha256": sha(path),
        }
        for role, path in roles.items()
    ],
}
(root / "candidate-artifacts.json").write_text(
    json.dumps(record, indent=2) + "\n", encoding="utf-8"
)
PY

verify_candidate() {
  "$python" - "$build_root/candidate-artifacts.json" <<'PY'
import hashlib, json, sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for artifact in manifest["artifacts"]:
    path = Path(artifact["path"]).resolve(strict=True)
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if path.stat().st_size != artifact["size"] or digest.hexdigest() != artifact["sha256"]:
        raise SystemExit(f"candidate artifact changed: {path}")
print("CANDIDATE_ARTIFACTS_VERIFIED")
PY
}

verify_candidate > "$build_root/candidate-verification-before.log"
pkill -x darkpanda 2>/dev/null || true
mkdir -p "$build_root/test-state"/{home,tmp,xdg-cache,xdg-config,xdg-data}
export HOME="$build_root/test-state/home"
export TMPDIR="$build_root/test-state/tmp"
export XDG_CACHE_HOME="$build_root/test-state/xdg-cache"
export XDG_CONFIG_HOME="$build_root/test-state/xdg-config"
export XDG_DATA_HOME="$build_root/test-state/xdg-data"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$repo_root/python"
unset LD_LIBRARY_PATH

"$build_root/i/bin/darkpanda" version > "$build_root/runtime-cli-version.txt"
"$python" "$repo_root/tools/runtime_artifact_attestation.py" \
  --python-root "$repo_root/python" \
  --library "$build_root/i/bin/libdarkpanda.so" \
  --wreq "$build_root/i/bin/libwreq.so" \
  --canvas "$build_root/i/bin/libdarkpanda_canvas_backend.so" \
  > "$build_root/runtime-attestation.json"
"$python" "$repo_root/tests/canvas_skia_smoke.py" \
  --library "$build_root/i/bin/libdarkpanda.so" \
  --wreq "$build_root/i/bin/libwreq.so" \
  --canvas "$build_root/i/bin/libdarkpanda_canvas_backend.so" \
  > "$build_root/canvas-skia-smoke.json"
verify_candidate > "$build_root/candidate-verification-after.log"

"$python" "$proof_tool" "$repo_root" --source-tree > "$build_root/source-after.json"
"$python" "$proof_tool" "$build_root/deps/cargo-vendor" > "$build_root/cargo-vendor-prepared-after.json"
"$python" "$proof_tool" "$build_root/deps/skia" > "$build_root/skia-source-copy-after.json"
"$python" "$proof_tool" "$build_root/deps/tools/cmake" > "$build_root/cmake-copy-after.json"
"$python" "$proof_tool" "$native_cache_root/g/p" > "$build_root/zig-package-cache-copy-after.json"
"$python" - "$build_root" "$build_id" "$version" "$zig" "$cargo" "$rustc" "$v8_bundle_manifest" "$jobs" <<'PY'
from __future__ import annotations
import hashlib, json, os, sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1]).resolve()
build_id, version, zig, cargo, rustc, v8_bundle_manifest_arg, jobs_arg = sys.argv[2:]
jobs = int(jobs_arg)
if jobs <= 0:
    raise SystemExit("recorded build jobs must be positive")
before = json.loads((root / "source-before.json").read_text())
after = json.loads((root / "source-after.json").read_text())
if (before["digest"], before["fileCount"], before["symlinkCount"]) != (
    after["digest"], after["fileCount"], after["symlinkCount"]
):
    raise SystemExit("source tree changed during the Linux build")
keys = ("digest", "fileCount", "symlinkCount", "byteCount")
cargo_before = json.loads((root / "cargo-vendor-prepared-before.json").read_text())
cargo_after = json.loads((root / "cargo-vendor-prepared-after.json").read_text())
if tuple(cargo_before[key] for key in keys) != tuple(cargo_after[key] for key in keys):
    raise SystemExit("prepared Cargo vendor tree changed during the Linux build")
for label in ("skia-source", "cmake"):
    copied_before = json.loads((root / f"{label}-copy-before.json").read_text())
    copied_after = json.loads((root / f"{label}-copy-after.json").read_text())
    if tuple(copied_before[key] for key in keys) != tuple(copied_after[key] for key in keys):
        raise SystemExit(f"{label} dependency tree changed during the Linux build")
zig_package_before = json.loads((root / "zig-package-cache-copy-before.json").read_text())
zig_package_after = json.loads((root / "zig-package-cache-copy-after.json").read_text())
if tuple(zig_package_before[key] for key in keys) != tuple(zig_package_after[key] for key in keys):
    raise SystemExit("Zig package source copy changed during the Linux build")

def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

v8_bundle = json.loads((root / "deps/v8-bundle-manifest.json").read_text())
v8_archive_record = v8_bundle["archive"]
copied_v8_archive = root / "deps/libc_v8.a"
if copied_v8_archive.stat().st_size != v8_archive_record["size"]:
    raise SystemExit("copied V8 archive size differs from its bundle manifest")
if sha(copied_v8_archive) != v8_archive_record["sha256"]:
    raise SystemExit("copied V8 archive SHA-256 differs from its bundle manifest")

roles = {
    "browser_exe": root / "i/bin/darkpanda",
    "ffi_library": root / "i/bin/libdarkpanda.so",
    "wreq_library": root / "i/bin/libwreq.so",
    "html_parser_library": root / "i/bin/libdarkpanda_html5ever.so",
    "canvas_backend_library": root / "i/bin/libdarkpanda_canvas_backend.so",
}
candidate = json.loads((root / "candidate-artifacts.json").read_text())
artifacts = candidate["artifacts"]
for artifact in artifacts:
    path = roles[artifact["role"]]
    if (
        artifact["path"] != str(path)
        or artifact["size"] != path.stat().st_size
        or artifact["sha256"] != sha(path)
    ):
        raise SystemExit(f"final artifact differs from candidate record: {path}")
manifest = {
    "schema": "darkpanda-portable-artifact-set/v1",
    "buildId": build_id,
    "createdAtUtc": datetime.now(timezone.utc).isoformat(),
    "target": "x86_64-linux-gnu",
    "version": version,
    "buildRoot": str(root),
    "command": [
        zig,
        "build",
        "install",
        "canvas-backend",
        f"-j{jobs}",
        "-Dtarget=x86_64-linux-gnu",
        "-Doptimize=ReleaseFast",
        f"-Dprebuilt_v8_path={root / 'deps/libc_v8.a'}",
        f"-Dwreq_transport_target_dir={root / 'wreq-target'}",
        f"-Dcanvas_backend_target_dir={root / 'canvas-target'}",
        f"-Dcargo_path={cargo}",
        f"-Dversion={version}",
        "-p",
        str(root / "i"),
        "--cache-dir",
        str(Path(json.loads((root / "native-zig-cache.json").read_text())["path"]) / "c"),
        "--global-cache-dir",
        str(Path(json.loads((root / "native-zig-cache.json").read_text())["path"]) / "g"),
        "--summary",
        "all",
    ],
    "buildParallelism": {
        "zigJobs": jobs,
        "cargoBuildJobs": jobs,
        "cmakeBuildParallelLevel": jobs,
    },
    "toolchain": {
        "zigPath": zig,
        "zigSha256": sha(Path(zig)),
        "zigVersion": (root / "zig-version.txt").read_text().strip(),
        "cargoPath": cargo,
        "cargoSha256": sha(Path(cargo)),
        "cargoVersion": (root / "cargo-version.txt").read_text().strip(),
        "rustcPath": rustc,
        "rustcSha256": sha(Path(rustc)),
        "rustcVersion": (root / "rustc-version.txt").read_text().strip(),
        "gnVersion": (root / "gn-version.txt").read_text().strip(),
        "ninjaVersion": (root / "ninja-version.txt").read_text().strip(),
        "cmakeVersion": (root / "cmake-version.txt").read_text().strip(),
    },
    "sourceProof": after,
    "cargoVendorInputProof": json.loads((root / "cargo-vendor-input.json").read_text()),
    "cargoVendorPreparation": json.loads((root / "cargo-vendor-preparation.json").read_text()),
    "skiaSourceInputProof": json.loads((root / "skia-source-input.json").read_text()),
    "cmakeInputProof": json.loads((root / "cmake-input.json").read_text()),
    "zigPackageCacheInputProof": json.loads((root / "zig-package-cache-input.json").read_text()),
    "nativeZigCache": json.loads((root / "native-zig-cache.json").read_text()),
    "copiedDependencyProofs": {
        "cargoVendor": cargo_after,
        "skiaSource": json.loads((root / "skia-source-copy-after.json").read_text()),
        "cmake": json.loads((root / "cmake-copy-after.json").read_text()),
        "zigPackageCache": zig_package_after,
    },
    "pinnedInputs": {
        "v8BundleManifest": {
            "sourcePath": str(Path(v8_bundle_manifest_arg).resolve()),
            "copiedPath": str(root / "deps/v8-bundle-manifest.json"),
            "sha256": sha(root / "deps/v8-bundle-manifest.json"),
            "metadata": v8_bundle,
        },
        "v8Archive": {
            "path": str(root / "deps/libc_v8.a"),
            "size": (root / "deps/libc_v8.a").stat().st_size,
            "sha256": sha(root / "deps/libc_v8.a"),
        },
        "skiaGn": {"path": str(root / "deps/tools/gn"), "sha256": sha(root / "deps/tools/gn")},
        "skiaNinja": {"path": str(root / "deps/tools/ninja"), "sha256": sha(root / "deps/tools/ninja")},
        "cmake": {
            "path": str(root / "deps/tools/cmake/bin/cmake"),
            "sha256": sha(root / "deps/tools/cmake/bin/cmake"),
        },
    },
    "buildLog": {"path": str(root / "build.log"), "sha256": sha(root / "build.log")},
    "candidateArtifactRecord": {
        "path": str(root / "candidate-artifacts.json"),
        "sha256": sha(root / "candidate-artifacts.json"),
    },
    "runtimeAttestation": json.loads((root / "runtime-attestation.json").read_text()),
    "canvasSkiaSmoke": json.loads((root / "canvas-skia-smoke.json").read_text()),
    "runtimeCliVersion": (root / "runtime-cli-version.txt").read_text().strip(),
    "candidateVerification": {
        "before": (root / "candidate-verification-before.log").read_text().strip(),
        "after": (root / "candidate-verification-after.log").read_text().strip(),
    },
    "artifacts": artifacts,
}
(root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print(f"LINUX_ARTIFACT_SET={root / 'manifest.json'}")
print(f"LINUX_MANIFEST_SHA256={sha(root / 'manifest.json')}")
PY
