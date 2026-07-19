#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/Build-LinuxCanvasSmoke.sh \
  --zig /absolute/path/to/zig \
  --cargo /absolute/path/to/cargo \
  --rustc /absolute/path/to/rustc \
  --cargo-vendor /absolute/path/to/vendor \
  --skia-source /absolute/path/to/skia \
  --skia-gn /absolute/path/to/gn \
  --skia-ninja /absolute/path/to/ninja \
  --zig-package-cache /absolute/path/to/zig/p \
  [--native-cache-root /absolute/path] \
  [--output-root /absolute/path] [--jobs N]

Builds and executes only the real rust-skia Canvas ABI smoke test. This
produces component evidence, not a complete DarkPanda acceptance artifact set.
The command is network-offline and never imports an old compiler target tree.
EOF
}

zig=""
cargo=""
rustc=""
cargo_vendor=""
skia_source=""
skia_gn=""
skia_ninja=""
zig_package_cache=""
native_cache_parent="${DARKPANDA_LINUX_NATIVE_CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/darkpanda/native-zig}"
default_output_root="${HOME}/darkpanda-canvas-smoke"
output_root="${DARKPANDA_LINUX_CANVAS_ROOT:-$default_output_root}"
jobs=2

while (($#)); do
  case "$1" in
    --zig) zig=${2:?}; shift 2 ;;
    --cargo) cargo=${2:?}; shift 2 ;;
    --rustc) rustc=${2:?}; shift 2 ;;
    --cargo-vendor) cargo_vendor=${2:?}; shift 2 ;;
    --skia-source) skia_source=${2:?}; shift 2 ;;
    --skia-gn) skia_gn=${2:?}; shift 2 ;;
    --skia-ninja) skia_ninja=${2:?}; shift 2 ;;
    --zig-package-cache) zig_package_cache=${2:?}; shift 2 ;;
    --native-cache-root) native_cache_parent=${2:?}; shift 2 ;;
    --output-root) output_root=${2:?}; shift 2 ;;
    --jobs) jobs=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for name in zig cargo rustc cargo_vendor skia_source skia_gn skia_ninja zig_package_cache; do
  if [[ -z ${!name} ]]; then
    echo "missing required --${name//_/-}" >&2
    exit 2
  fi
done
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo "--jobs must be a positive integer" >&2; exit 2; }

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
# Keep rustup proxy basenames intact so argv[0] selects Cargo/Rustc.
cargo=$(real_command_file "$cargo")
rustc=$(real_command_file "$rustc")
cargo_vendor=$(real_dir "$cargo_vendor")
skia_source=$(real_dir "$skia_source")
skia_gn=$(real_command_file "$skia_gn")
skia_ninja=$(real_command_file "$skia_ninja")
zig_package_cache=$(real_dir "$zig_package_cache")
output_root=$(realpath -m -- "$output_root")
native_cache_parent=$(realpath -m -- "$native_cache_parent")
[[ $native_cache_parent == /* && $native_cache_parent != / ]] || {
  echo "unsafe native cache parent: $native_cache_parent" >&2
  exit 2
}
require_elf_command "$skia_gn"
require_elf_command "$skia_ninja"

repo_root=$(realpath -e -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
python=${PYTHON:-$(command -v python3)}
proof_tool="$repo_root/tools/tree_digest.py"
[[ -f $proof_tool ]] || { echo "missing tree proof tool: $proof_tool" >&2; exit 2; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
nonce=$("$python" -c 'import secrets; print(secrets.token_hex(4))')
build_id="linux-x64-canvas-${stamp}-${nonce}"
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
mkdir -p "$build_root"/{i,ch,canvas-target,deps/tools} "$native_cache_root"/{c,g}
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

"$python" "$proof_tool" "$repo_root" --source-tree > "$build_root/source-before.json"
"$python" "$proof_tool" "$cargo_vendor" > "$build_root/cargo-vendor-input.json"
"$python" "$proof_tool" "$skia_source" > "$build_root/skia-source-input.json"
"$python" "$proof_tool" "$zig_package_cache" > "$build_root/zig-package-cache-input.json"
cp -a -- "$cargo_vendor" "$build_root/deps/cargo-vendor"
cp -a -- "$skia_source" "$build_root/deps/skia"
cp -a -- "$zig_package_cache" "$native_cache_root/g/p"
cp -a -- "$skia_gn" "$build_root/deps/tools/gn"
cp -a -- "$skia_ninja" "$build_root/deps/tools/ninja"
chmod 0755 "$build_root/deps/tools/gn" "$build_root/deps/tools/ninja"
require_elf_command "$build_root/deps/tools/gn"
require_elf_command "$build_root/deps/tools/ninja"

"$python" "$proof_tool" "$build_root/deps/cargo-vendor" > "$build_root/cargo-vendor-copy-before.json"
"$python" "$proof_tool" "$build_root/deps/skia" > "$build_root/skia-source-copy-before.json"
"$python" "$proof_tool" "$native_cache_root/g/p" > "$build_root/zig-package-cache-copy-before.json"
"$python" - "$build_root" <<'PY'
import json, sys
from pathlib import Path

root = Path(sys.argv[1])
for label in ("cargo-vendor", "skia-source", "zig-package-cache"):
    source = json.loads((root / f"{label}-input.json").read_text())
    copied = json.loads((root / f"{label}-copy-before.json").read_text())
    keys = ("digest", "fileCount", "symlinkCount", "byteCount")
    if tuple(source[key] for key in keys) != tuple(copied[key] for key in keys):
        raise SystemExit(f"{label} copy does not match its input proof")
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
export RUSTC="$rustc"
unset CARGO_TARGET_DIR RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER RUSTFLAGS CARGO_ENCODED_RUSTFLAGS
export SKIA_SOURCE_DIR="$build_root/deps/skia"
export SKIA_GN_COMMAND="$build_root/deps/tools/gn"
export SKIA_NINJA_COMMAND="$build_root/deps/tools/ninja"
# FreeType is embedded from the pinned Skia source. Font discovery is outside
# the current pixel-surface ABI, so keep fontconfig disabled and non-system.
export SKIA_GN_ARGS="skia_use_fontconfig=false"
export FORCE_SKIA_BUILD=1
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
  "$zig" build canvas-backend-smoke \
    "-j${jobs}" \
    -Dtarget=x86_64-linux-gnu \
    -Doptimize=ReleaseFast \
    -Dcanvas_only=true \
    "-Dcanvas_backend_target_dir=$build_root/canvas-target" \
    "-Dcargo_path=$cargo" \
    -p "$build_root/i" \
    --cache-dir "$native_cache_root/c" \
    --global-cache-dir "$native_cache_root/g" \
    --summary all
) > "$build_root/smoke.log" 2>&1
build_exit=$?
set -e
if ((build_exit != 0)); then
  printf 'Linux Canvas smoke failed (%d); log=%s\n' "$build_exit" "$build_root/smoke.log" >&2
  tail -120 "$build_root/smoke.log" >&2
  exit "$build_exit"
fi

canvas_library="$build_root/i/bin/libdarkpanda_canvas_backend.so"
[[ -f $canvas_library ]] || { echo "missing Canvas backend: $canvas_library" >&2; exit 1; }
grep -Fq 'canvas backend ABI smoke: PASS' "$build_root/smoke.log" || {
  echo "Canvas smoke did not emit its PASS attestation" >&2
  exit 1
}
if grep -Fq '.lp-cache' "$build_root/smoke.log"; then
  echo "Canvas-only build unexpectedly inspected the legacy .lp-cache" >&2
  exit 1
fi

"$python" "$proof_tool" "$repo_root" --source-tree > "$build_root/source-after.json"
"$python" "$proof_tool" "$build_root/deps/cargo-vendor" > "$build_root/cargo-vendor-prepared-after.json"
"$python" "$proof_tool" "$build_root/deps/skia" > "$build_root/skia-source-copy-after.json"
"$python" "$proof_tool" "$native_cache_root/g/p" > "$build_root/zig-package-cache-copy-after.json"
"$python" - "$build_root" "$build_id" "$zig" "$cargo" "$rustc" <<'PY'
from __future__ import annotations
import hashlib, json, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1]).resolve()
build_id, zig, cargo, rustc = sys.argv[2:]

def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

before = json.loads((root / "source-before.json").read_text())
after = json.loads((root / "source-after.json").read_text())
keys = ("digest", "fileCount", "symlinkCount", "byteCount")
if tuple(before[key] for key in keys) != tuple(after[key] for key in keys):
    raise SystemExit("source tree changed during the Canvas smoke build")
cargo_before = json.loads((root / "cargo-vendor-prepared-before.json").read_text())
cargo_after = json.loads((root / "cargo-vendor-prepared-after.json").read_text())
if tuple(cargo_before[key] for key in keys) != tuple(cargo_after[key] for key in keys):
    raise SystemExit("prepared Cargo vendor tree changed during the Canvas smoke build")
skia_before = json.loads((root / "skia-source-copy-before.json").read_text())
skia_after = json.loads((root / "skia-source-copy-after.json").read_text())
if tuple(skia_before[key] for key in keys) != tuple(skia_after[key] for key in keys):
    raise SystemExit("Skia source copy changed during the Canvas smoke build")
zig_package_before = json.loads((root / "zig-package-cache-copy-before.json").read_text())
zig_package_after = json.loads((root / "zig-package-cache-copy-after.json").read_text())
if tuple(zig_package_before[key] for key in keys) != tuple(zig_package_after[key] for key in keys):
    raise SystemExit("Zig package source copy changed during the Canvas smoke build")

canvas = root / "i/bin/libdarkpanda_canvas_backend.so"
gn = root / "deps/tools/gn"
ninja = root / "deps/tools/ninja"
manifest = {
    "schema": "darkpanda-component-evidence/v1",
    "component": "canvas-rust-skia",
    "completeAcceptanceArtifact": False,
    "buildId": build_id,
    "createdAtUtc": datetime.now(timezone.utc).isoformat(),
    "target": "x86_64-linux-gnu",
    "buildRoot": str(root),
    "attestation": {
        "status": "PASS",
        "driver": "dynamic-rust-skia",
        "legacyCacheInspected": False,
        "backendAbi": 2,
        "backendVersionContains": "rust-skia/0.99.0",
        "skiaFeatures": ["binary-cache", "embed-freetype"],
        "skiaGnArgs": "skia_use_fontconfig=false",
        "operations": ["create", "clear", "fillRect", "clearRect", "readPixels", "writePixels", "resize"],
    },
    "toolchain": {
        "zig": {"path": zig, "sha256": sha(Path(zig))},
        "cargo": {"path": cargo, "sha256": sha(Path(cargo))},
        "rustc": {"path": rustc, "sha256": sha(Path(rustc))},
        "gn": {
            "path": str(gn),
            "sha256": sha(gn),
            "version": subprocess.check_output([gn, "--version"], text=True).strip(),
        },
        "ninja": {
            "path": str(ninja),
            "sha256": sha(ninja),
            "version": subprocess.check_output([ninja, "--version"], text=True).strip(),
        },
    },
    "sourceProof": after,
    "cargoVendorInputProof": json.loads((root / "cargo-vendor-input.json").read_text()),
    "cargoVendorPreparation": json.loads((root / "cargo-vendor-preparation.json").read_text()),
    "cargoVendorPreparedProof": cargo_after,
    "skiaSourceInputProof": json.loads((root / "skia-source-input.json").read_text()),
    "zigPackageCacheInputProof": json.loads((root / "zig-package-cache-input.json").read_text()),
    "zigPackageCacheCopyProof": zig_package_after,
    "nativeZigCache": json.loads((root / "native-zig-cache.json").read_text()),
    "smokeLog": {"path": str(root / "smoke.log"), "sha256": sha(root / "smoke.log")},
    "artifact": {"path": str(canvas), "size": canvas.stat().st_size, "sha256": sha(canvas)},
}
(root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print(f"LINUX_CANVAS_EVIDENCE={root / 'manifest.json'}")
print(f"LINUX_CANVAS_MANIFEST_SHA256={sha(root / 'manifest.json')}")
PY
