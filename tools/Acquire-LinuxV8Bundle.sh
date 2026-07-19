#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/Acquire-LinuxV8Bundle.sh \
  --zig /absolute/path/to/zig \
  --zig-package-cache /absolute/path/to/zig/p \
  [--v8-git-seed /absolute/path/to/source-only-v8-git] \
  [--depot-tools-seed /absolute/path/to/bootstrapped-depot-tools] \
  [--dependency-git-seed-root /absolute/path/to/materialized-v8-tree] \
  [--materialized-toolchain-seed /absolute/path/to/materialized-v8-tree] \
  [--resume-root /absolute/path/to/interrupted-bundle-root] \
  [--repair-compiler-failure] \
  [--repair-shared-link-failure /absolute/path/to/downstream-build.log] \
  [--native-cache-root /absolute/path] \
  [--output-root /absolute/path] [--jobs N]

ONLINE PROVISIONING STEP. Materializes the V8 14.9.207.35 / Chromium 149
Linux dependency tree and builds the matching zig-v8-fork archive in a unique
root. The manifest identifies a dependency bundle, not a complete DarkPanda
artifact. Formal builds must consume the completed bundle offline and must
never invoke this acquisition step.
EOF
}

zig=""
zig_package_cache=""
v8_git_seed=""
depot_tools_seed=""
dependency_git_seed_root=""
materialized_toolchain_seed=""
resume_root=""
repair_compiler_failure=0
shared_link_failure=""
prior_completed_manifest=""
native_cache_parent="${DARKPANDA_LINUX_NATIVE_CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/darkpanda/native-zig}"
default_output_root="${HOME}/darkpanda-v8-bundles"
output_root="${DARKPANDA_LINUX_V8_ROOT:-$default_output_root}"
jobs=2

while (($#)); do
  case "$1" in
    --zig) zig=${2:?}; shift 2 ;;
    --zig-package-cache) zig_package_cache=${2:?}; shift 2 ;;
    --v8-git-seed) v8_git_seed=${2:?}; shift 2 ;;
    --depot-tools-seed) depot_tools_seed=${2:?}; shift 2 ;;
    --dependency-git-seed-root) dependency_git_seed_root=${2:?}; shift 2 ;;
    --materialized-toolchain-seed) materialized_toolchain_seed=${2:?}; shift 2 ;;
    --resume-root) resume_root=${2:?}; shift 2 ;;
    --repair-compiler-failure) repair_compiler_failure=1; shift ;;
    --repair-shared-link-failure)
      shared_link_failure=${2:?}
      repair_compiler_failure=1
      shift 2
      ;;
    --native-cache-root) native_cache_parent=${2:?}; shift 2 ;;
    --output-root) output_root=${2:?}; shift 2 ;;
    --jobs) jobs=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n $zig && -n $zig_package_cache ]] || { usage >&2; exit 2; }
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo "--jobs must be a positive integer" >&2; exit 2; }
if ((repair_compiler_failure)) && [[ -z $resume_root ]]; then
  echo "--repair-compiler-failure requires --resume-root" >&2
  exit 2
fi
if [[ -n $shared_link_failure ]]; then
  shared_link_failure=$(realpath -e -- "$shared_link_failure")
  [[ -f $shared_link_failure ]] || {
    echo "shared-link failure proof is not a file: $shared_link_failure" >&2
    exit 2
  }
fi

real_command_file() {
  local path=$1 directory base
  [[ $path == /* ]] || path=$PWD/$path
  directory=$(realpath -e -- "$(dirname -- "$path")")
  base=$(basename -- "$path")
  path=$directory/$base
  [[ -f $path && -x $path ]] || { echo "not an executable file: $path" >&2; exit 2; }
  printf '%s' "$path"
}
real_dir() {
  local path
  path=$(realpath -e -- "$1")
  [[ -d $path ]] || { echo "not a directory: $path" >&2; exit 2; }
  printf '%s' "$path"
}

zig=$(real_command_file "$zig")
zig_package_cache=$(real_dir "$zig_package_cache")
if [[ -n $v8_git_seed ]]; then
  v8_git_seed=$(real_dir "$v8_git_seed")
  [[ -d $v8_git_seed/.git ]] || { echo "V8 Git seed has no .git directory: $v8_git_seed" >&2; exit 2; }
  git -C "$v8_git_seed" cat-file -e 933ce636c562cd54d68e7f7c93ab5cdffd685fca^{commit}
  git -C "$v8_git_seed" fsck --connectivity-only --no-dangling \
    933ce636c562cd54d68e7f7c93ab5cdffd685fca >/dev/null
fi
if [[ -n $depot_tools_seed ]]; then
  depot_tools_seed=$(real_dir "$depot_tools_seed")
  for required in .bootstrap-complete gclient python-bin/python3; do
    [[ -e $depot_tools_seed/$required ]] || {
      echo "bootstrapped depot_tools seed is missing $required: $depot_tools_seed" >&2
      exit 2
    }
  done
  [[ -x $depot_tools_seed/gclient && -x $depot_tools_seed/python-bin/python3 ]] || {
    echo "bootstrapped depot_tools seed has non-executable tools: $depot_tools_seed" >&2
    exit 2
  }
fi
if [[ -n $dependency_git_seed_root ]]; then
  dependency_git_seed_root=$(real_dir "$dependency_git_seed_root")
fi
if [[ -n $materialized_toolchain_seed ]]; then
  materialized_toolchain_seed=$(real_dir "$materialized_toolchain_seed")
  for required in \
    third_party/llvm-build/Release+Asserts \
    third_party/rust-toolchain; do
    [[ -d $materialized_toolchain_seed/$required ]] || {
      echo "materialized toolchain seed is missing $required: $materialized_toolchain_seed" >&2
      exit 2
    }
  done
fi
output_root=$(realpath -m -- "$output_root")
native_cache_parent=$(realpath -m -- "$native_cache_parent")
[[ $native_cache_parent == /* && $native_cache_parent != / ]] || {
  echo "unsafe native cache parent: $native_cache_parent" >&2
  exit 2
}
repo_root=$(realpath -e -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
v8_repo=$(realpath -e -- "$repo_root/../zig-v8-fork")
python=${PYTHON:-$(command -v python3)}
proof_tool="$repo_root/tools/tree_digest.py"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
nonce=$("$python" -c 'import secrets; print(secrets.token_hex(4))')
resume_mode=0
if [[ -n $resume_root ]]; then
  resume_mode=1
  resume_root=$(real_dir "$resume_root")
  bundle_root=$resume_root
  bundle_id=$(basename -- "$bundle_root")
  [[ $bundle_id == linux-x64-v8-14.9.207.35-* ]] || {
    echo "resume root has an unexpected bundle id: $bundle_root" >&2
    exit 2
  }
  if [[ -e $bundle_root/manifest.json ]]; then
    [[ -n $shared_link_failure ]] || {
      echo "refusing to resume a completed bundle: $bundle_root" >&2
      exit 2
    }
    prior_completed_manifest="$bundle_root/manifest.before-shared-link-repair-${stamp}-${nonce}.json"
    cp -- "$bundle_root/manifest.json" "$prior_completed_manifest"
  fi
  if [[ -n $v8_git_seed || -n $depot_tools_seed || -n $dependency_git_seed_root || -n $materialized_toolchain_seed ]]; then
    echo "seed options cannot be changed while resuming an existing bundle" >&2
    exit 2
  fi
  native_cache_root="$native_cache_parent/${bundle_id}-resume-${stamp}-${nonce}"
else
  bundle_id="linux-x64-v8-14.9.207.35-${stamp}-${nonce}"
  bundle_root="$output_root/$bundle_id"
  native_cache_root="$native_cache_parent/$bundle_id"
  [[ ! -e $bundle_root ]] || { echo "unique bundle root exists: $bundle_root" >&2; exit 2; }
fi
[[ ! -e $native_cache_root ]] || {
  echo "unique native cache root exists: $native_cache_root" >&2
  exit 2
}
case "$native_cache_root" in
  "$native_cache_parent"/"$bundle_id"|"$native_cache_parent"/"${bundle_id}"-resume-*) ;;
  *) echo "native cache escaped its parent: $native_cache_root" >&2; exit 2 ;;
esac
mkdir -p "$bundle_root/cache" "$native_cache_root"/{c,g}
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
  if (( ${resume_mode:-0} )) && [[ -n ${resume_lock_file:-} ]]; then
    rm -f -- "$resume_lock_file"
  fi
}
trap cleanup_native_cache EXIT INT TERM

"$python" - "$bundle_root/native-zig-cache.json" "$native_cache_root" "$native_cache_fs" <<'PY'
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

if ((resume_mode)); then
  command -v flock >/dev/null || { echo "resume requires flock" >&2; exit 2; }
  resume_lock_file="$bundle_root/.resume.lock"
  exec 9>"$resume_lock_file"
  flock -n 9 || { echo "bundle already has an active resume: $bundle_root" >&2; exit 2; }

  required_resume_files=(
    acquire-build.log
    zig-v8-source-before.json
    zig-package-cache-input.json
    materialized-toolchain-seed.json
    dependency-git-seeds.json
    dependency-git-seeds.tsv
    depot-tools-seed.json
    v8-git-seed.json
  )
  for required in "${required_resume_files[@]}"; do
    [[ -f $bundle_root/$required ]] || {
      echo "resume root is missing proof input $required: $bundle_root" >&2
      exit 2
    }
  done
  if ((repair_compiler_failure)); then
    repairable_failure=0
    if grep -q '^FAILED:' "$bundle_root/acquire-build.log" &&
      grep -Fq 'ninja: build stopped: subcommand failed.' "$bundle_root/acquire-build.log"; then
      repairable_failure=1
    fi
    if grep -Fq 'error: ld.lld: undefined symbol: temporal_rs_' "$bundle_root/acquire-build.log" &&
      grep -Fq 'build-v8 success' "$bundle_root/acquire-build.log"; then
      repairable_failure=1
    fi
    if grep -Fq 'error: ld.lld: undefined symbol: __isoc23_' "$bundle_root/acquire-build.log" &&
      grep -Fq 'build-v8 success' "$bundle_root/acquire-build.log"; then
      repairable_failure=1
    fi
    if [[ -n $shared_link_failure ]] &&
      grep -Fq 'relocation R_X86_64_TPOFF32' "$shared_link_failure" &&
      grep -Fq 'cannot be used with -shared' "$shared_link_failure" &&
      grep -Fq '/libc_v8.a' "$shared_link_failure"; then
      repairable_failure=1
    fi
    if ((repairable_failure == 0)); then
      echo "compiler-failure repair requires a proven Ninja compile or V8 standalone link-closure failure" >&2
      exit 2
    fi
  else
    grep -Fqx 'ninja: build stopped: interrupted by user.' "$bundle_root/acquire-build.log" || {
      echo "resume is allowed only for a user-interrupted Ninja build" >&2
      exit 2
    }
    if grep -q '^FAILED:' "$bundle_root/acquire-build.log"; then
      echo "refusing to resume a compiler failure without --repair-compiler-failure" >&2
      exit 2
    fi
  fi

  v8_source="$bundle_root/cache/v8-14.9.207.35"
  depot_tools="$bundle_root/cache/depot_tools-14.9.207.35"
  required_checkout_files=(
    "$v8_source/.bootstrap-complete"
    "$v8_source/build/util/LASTCHANGE.committime"
    "$v8_source/third_party/googletest/src/googletest/include/gtest/gtest_prod.h"
    "$v8_source/out/linux/release_8989575/args.gn"
    "$v8_source/out/linux/release_8989575/build.ninja"
    "$depot_tools/gclient"
    "$depot_tools/python-bin/python3"
  )
  for required in "${required_checkout_files[@]}"; do
    [[ -e $required ]] || { echo "resume checkout is missing $required" >&2; exit 2; }
  done
  [[ $(git -C "$v8_source" rev-parse HEAD) == 933ce636c562cd54d68e7f7c93ab5cdffd685fca ]] || {
    echo "resume V8 revision mismatch" >&2
    exit 2
  }
  [[ $(git -C "$v8_source/third_party/icu" rev-parse HEAD) == 3859e64eed5d34544b27fbcab0ac1685ce83df3c ]] || {
    echo "resume ICU revision mismatch" >&2
    exit 2
  }
  googletest="$v8_source/third_party/googletest/src"
  [[ $(git -C "$googletest" rev-parse HEAD) == 4fe3307fb2d9f86d19777c7eb0e4809e9694dde7 ]] || {
    echo "resume googletest revision mismatch" >&2
    exit 2
  }
  [[ $(git -C "$googletest" config --get remote.origin.url) == \
    https://chromium.googlesource.com/external/github.com/google/googletest.git ]] || {
    echo "resume googletest origin is not canonical" >&2
    exit 2
  }
  git -C "$v8_source" fsck --connectivity-only --no-dangling HEAD >/dev/null
  git -C "$v8_source/third_party/icu" fsck --connectivity-only --no-dangling HEAD >/dev/null
  git -C "$googletest" fsck --connectivity-only --no-dangling HEAD >/dev/null
  for required_arg in use_glib use_siso v8_enable_sandbox; do
    grep -Eq "^[[:space:]]*${required_arg}[[:space:]]*=[[:space:]]*false[[:space:]]*$" \
      "$v8_source/out/linux/release_8989575/args.gn" || {
      echo "resume GN args do not set $required_arg=false" >&2
      exit 2
    }
  done

  if [[ -n $shared_link_failure ]]; then
    previous_log="$bundle_root/acquire-build.before-shared-link-repair-${stamp}-${nonce}.log"
  elif ((repair_compiler_failure)); then
    previous_log="$bundle_root/acquire-build.failed-${stamp}-${nonce}.log"
  else
    previous_log="$bundle_root/acquire-build.interrupted-${stamp}-${nonce}.log"
  fi
  cp -- "$bundle_root/acquire-build.log" "$previous_log"
  "$python" "$proof_tool" "$v8_repo" --source-tree > "$bundle_root/zig-v8-source-resume-${stamp}-${nonce}.json"
  "$python" "$proof_tool" "$zig_package_cache" > "$bundle_root/zig-package-cache-resume-${stamp}-${nonce}.json"

  materialized_toolchain_seed=$("$python" - "$bundle_root/materialized-toolchain-seed.json" <<'PY'
import json, sys
from pathlib import Path
record = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(record, dict) or not record.get("path"):
    raise SystemExit("resume requires the original materialized toolchain seed record")
print(record["path"])
PY
  )
  materialized_toolchain_seed=$(real_dir "$materialized_toolchain_seed")
  "$python" "$proof_tool" "$v8_source/third_party/llvm-build/Release+Asserts" \
    > "$bundle_root/clang-toolchain-resume-${stamp}-${nonce}.json"
  "$python" "$proof_tool" "$v8_source/third_party/rust-toolchain" \
    > "$bundle_root/rust-toolchain-resume-${stamp}-${nonce}.json"

  cp -a -- "$zig_package_cache" "$native_cache_root/g/p"
  "$python" "$proof_tool" "$native_cache_root/g/p" > "$bundle_root/zig-package-cache-copy.json"
  resume_record="$bundle_root/resume-${stamp}-${nonce}.json"
  "$python" - "$bundle_root" "$stamp" "$nonce" "$previous_log" "$resume_record" \
    "$repair_compiler_failure" "$v8_repo" "$proof_tool" \
    "$shared_link_failure" "$prior_completed_manifest" <<'PY'
from __future__ import annotations
import hashlib, importlib.util, json, os, shutil, sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1]).resolve()
stamp, nonce = sys.argv[2:4]
previous_log = Path(sys.argv[4]).resolve(strict=True)
output = Path(sys.argv[5])
repair_mode = sys.argv[6] == "1"
source_root = Path(sys.argv[7]).resolve(strict=True)
proof_tool = Path(sys.argv[8]).resolve(strict=True)
shared_link_failure_arg = sys.argv[9]
prior_completed_manifest_arg = sys.argv[10]
shared_link_failure = (
    Path(shared_link_failure_arg).resolve(strict=True)
    if shared_link_failure_arg
    else None
)
prior_completed_manifest = (
    Path(prior_completed_manifest_arg).resolve(strict=True)
    if prior_completed_manifest_arg
    else None
)
keys = ("digest", "fileCount", "symlinkCount", "byteCount")

def load(name: str):
    return json.loads((root / name).read_text(encoding="utf-8"))

def same(left, right) -> bool:
    return tuple(left[key] for key in keys) == tuple(right[key] for key in keys)

source_before = load("zig-v8-source-before.json")
source_resume = load(f"zig-v8-source-resume-{stamp}-{nonce}.json")

source_repair = None
if repair_mode:
    spec = importlib.util.spec_from_file_location("darkpanda_tree_digest", proof_tool)
    if spec is None or spec.loader is None:
        raise SystemExit("cannot load the tree proof implementation")
    tree_digest = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tree_digest)

    metadata_policy = None
    if source_before["digest"] == "e16a16691aed8ddcc1581216ae74fcba3cc9b3a57e29ca6041306fddeddde56f":
        metadata_policy = {
            Path("build.zig"): {
                "operation": "bundle the Linux V8 Temporal Rust closure into the standalone archive",
                "beforeSize": 42810,
                "beforeSha256": "9eabcc0384021d6cccc5954df24d1f09d17e4a1c4b2251bc1e89711409fcba1f",
                "afterSize": 45909,
                "afterSha256": "1352ba18262f20554b6c172421f7e9825581c1f6eedd7ea592730a2b820f6f2a",
                "added": False,
            },
            Path("build-tools/merge_archives.py"): {
                "operation": "add the deterministic LLVM ar MRI archive merger",
                "afterSize": 1717,
                "afterSha256": "43cf925efb38283dc0124053374a9d4692fa3c15801229c8e579767103400e67",
                "added": True,
            },
        }
    elif source_before["digest"] == "71fffe80efde1c1dd140ebae5f76725da4e1e0f5af555a7b8d04fb9db54b7b38":
        metadata_policy = {
            Path("build.zig"): {
                "operation": "compile Linux V8 against Chromium's pinned Bullseye sysroot",
                "beforeSize": 45909,
                "beforeSha256": "1352ba18262f20554b6c172421f7e9825581c1f6eedd7ea592730a2b820f6f2a",
                "afterSize": 46270,
                "afterSha256": "3769bb28e4df95a263fcc8994a03fde8cda2017a8a7feb6159beac2555f630d5",
                "added": False,
            },
        }
    elif source_before["digest"] == "1b30260f388a06ac99f57dba36be9eedaeb6973ab25aaea702a1efce24cab882":
        metadata_policy = {
            Path("build.zig"): {
                "operation": "build Linux V8 for shared-library TLS and add a shared-link smoke step",
                "beforeSize": 46270,
                "beforeSha256": "3769bb28e4df95a263fcc8994a03fde8cda2017a8a7feb6159beac2555f630d5",
                "afterSize": 47838,
                "afterSha256": "26ae61e549b7e84fd95003296b14d03b30f283c3941c3ff05784442fb985fc75",
                "added": False,
            },
            Path("src/shared_link_smoke.zig"): {
                "operation": "add a deterministic Linux shared-library link probe",
                "afterSize": 622,
                "afterSha256": "c7ab7a27d6676351cd9b7c9c8dfd69fd45593d34080fb1dbbd6331a956a2d3ad",
                "added": True,
            },
        }

    reconstructed_bytes = {}
    reconstructed_metadata = {}
    added_files = set()
    changes = []
    if metadata_policy is not None:
        for relative, policy in metadata_policy.items():
            current = (source_root / relative).read_bytes()
            current_sha = hashlib.sha256(current).hexdigest()
            if len(current) != policy["afterSize"] or current_sha != policy["afterSha256"]:
                raise SystemExit(f"repair source {relative} does not match its allowlisted result")
            if policy["added"]:
                added_files.add(relative)
                before_sha = None
            else:
                reconstructed_metadata[relative] = (
                    policy["beforeSize"],
                    policy["beforeSha256"],
                )
                before_sha = policy["beforeSha256"]
            changes.append({
                "path": relative.as_posix(),
                "operation": policy["operation"],
                "added": policy["added"],
                "beforeSha256": before_sha,
                "afterSha256": current_sha,
            })
    else:
        expected_replacements = {
            Path("src/binding.cpp"): 3,
            Path("src/binding.h"): 2,
        }
        for relative, expected_count in expected_replacements.items():
            path = source_root / relative
            current = path.read_bytes()
            actual_count = current.count(b"timezone_id")
            if actual_count != expected_count:
                raise SystemExit(
                    f"repair source {relative} has {actual_count} timezone_id tokens; "
                    f"expected {expected_count}"
                )
            previous = current.replace(b"timezone_id", b"timezone")
            reconstructed_bytes[relative] = previous
            changes.append({
                "path": relative.as_posix(),
                "operation": "rename the C/C++ parameter timezone to timezone_id",
                "replacementCount": actual_count,
                "beforeSha256": hashlib.sha256(previous).hexdigest(),
                "afterSha256": hashlib.sha256(current).hexdigest(),
            })

    records = []
    file_count = 0
    symlink_count = 0
    byte_count = 0
    for directory, directory_names, file_names in os.walk(source_root, followlinks=False):
        directory_path = Path(directory)
        relative_directory = directory_path.relative_to(source_root)
        directory_names[:] = sorted(
            name
            for name in directory_names
            if not tree_digest.excluded(relative_directory / name, True)
        )
        for name in sorted(file_names):
            path = directory_path / name
            relative = path.relative_to(source_root)
            if tree_digest.excluded(relative, True):
                continue
            relative_text = relative.as_posix()
            if path.is_symlink():
                records.append(f"L\t{relative_text}\t{os.readlink(path)}")
                symlink_count += 1
                continue
            if relative in added_files:
                continue
            if relative in reconstructed_metadata:
                size, digest = reconstructed_metadata[relative]
            else:
                data = reconstructed_bytes.get(relative, path.read_bytes())
                size = len(data)
                digest = hashlib.sha256(data).hexdigest()
            records.append(f"F\t{relative_text}\t{size}\t{digest}")
            file_count += 1
            byte_count += size
    canonical = ("\n".join(records) + "\n").encode("utf-8")
    reconstructed = {
        "schema": "darkpanda-tree-proof/v1",
        "root": str(source_root),
        "digest": hashlib.sha256(canonical).hexdigest(),
        "fileCount": file_count,
        "symlinkCount": symlink_count,
        "byteCount": byte_count,
    }
    if not same(source_before, reconstructed):
        raise SystemExit(
            "repair source differs from the original proof beyond the allowlisted changes"
        )
    if same(source_before, source_resume):
        raise SystemExit("compiler-failure repair did not change the source proof")
    source_repair = {
        "policy": "exact reverse reconstruction of the original source-tree proof",
        "originalProof": source_before,
        "currentProof": source_resume,
        "reconstructedOriginalProof": reconstructed,
        "allowlistedChanges": changes,
    }
else:
    if not same(source_before, source_resume):
        raise SystemExit("zig-v8-fork source differs from the interrupted build proof")

package_input = load("zig-package-cache-input.json")
package_resume = load(f"zig-package-cache-resume-{stamp}-{nonce}.json")
package_copy = load("zig-package-cache-copy.json")
if not same(package_input, package_resume) or not same(package_input, package_copy):
    raise SystemExit("resume Zig package cache differs from the original input proof")

toolchain = load("materialized-toolchain-seed.json")
for label in ("clang-toolchain", "rust-toolchain"):
    original = toolchain["components"][label]["copiedProofBeforeUse"]
    current = load(f"{label}-resume-{stamp}-{nonce}.json")
    if not same(original, current):
        raise SystemExit(f"resume {label} differs from the original copied proof")

def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

record = {
    "resumedAtUtc": datetime.now(timezone.utc).isoformat(),
    "reason": (
        "allowlisted downstream shared-link repair with exact source reconstruction"
        if shared_link_failure is not None
        else "allowlisted compiler-failure repair with exact source reconstruction"
        if repair_mode
        else "ninja interrupted by user without a compiler failure"
    ),
    "sameBundleRoot": True,
    "incrementalCompilerOutputsReusedWithinSameBuildRoot": True,
    "previousBuildLog": {
        "path": str(previous_log),
        "size": previous_log.stat().st_size,
        "sha256": sha(previous_log),
    },
    "zigV8SourceProof": source_resume,
    "zigPackageCacheInputProof": package_resume,
    "clangToolchainProof": load(f"clang-toolchain-resume-{stamp}-{nonce}.json"),
    "rustToolchainProof": load(f"rust-toolchain-resume-{stamp}-{nonce}.json"),
}
if shared_link_failure is not None:
    record["downstreamSharedLinkFailure"] = {
        "path": str(shared_link_failure),
        "size": shared_link_failure.stat().st_size,
        "sha256": sha(shared_link_failure),
        "requiredEvidence": [
            "relocation R_X86_64_TPOFF32",
            "cannot be used with -shared",
            "/libc_v8.a",
        ],
    }
if prior_completed_manifest is not None:
    record["priorCompletedManifest"] = {
        "path": str(prior_completed_manifest),
        "size": prior_completed_manifest.stat().st_size,
        "sha256": sha(prior_completed_manifest),
    }
if source_repair is not None:
    original_proof = root / f"zig-v8-source-before.original-{stamp}-{nonce}.json"
    shutil.copyfile(root / "zig-v8-source-before.json", original_proof)
    (root / "zig-v8-source-before.json").write_text(
        json.dumps(source_resume, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    source_repair["originalProofFile"] = {
        "path": str(original_proof),
        "sha256": sha(original_proof),
    }
    source_repair["canonicalProofUpdatedForPostRepairBuild"] = True
    record["sourceRepair"] = source_repair

output.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
PY
else
if [[ -n $materialized_toolchain_seed ]]; then
  target_v8_root="$bundle_root/cache/v8-14.9.207.35"
  mkdir -p "$target_v8_root/third_party/llvm-build" "$target_v8_root/third_party"
  "$python" "$proof_tool" \
    "$materialized_toolchain_seed/third_party/llvm-build/Release+Asserts" \
    > "$bundle_root/clang-toolchain-seed-input.json"
  "$python" "$proof_tool" \
    "$materialized_toolchain_seed/third_party/rust-toolchain" \
    > "$bundle_root/rust-toolchain-seed-input.json"
  cp -a -- \
    "$materialized_toolchain_seed/third_party/llvm-build/Release+Asserts" \
    "$target_v8_root/third_party/llvm-build/Release+Asserts"
  cp -a -- \
    "$materialized_toolchain_seed/third_party/rust-toolchain" \
    "$target_v8_root/third_party/rust-toolchain"
  "$python" "$proof_tool" "$target_v8_root/third_party/llvm-build/Release+Asserts" \
    > "$bundle_root/clang-toolchain-seed-copy.json"
  "$python" "$proof_tool" "$target_v8_root/third_party/rust-toolchain" \
    > "$bundle_root/rust-toolchain-seed-copy.json"
  "$python" - "$bundle_root" "$materialized_toolchain_seed" <<'PY'
import json, sys
from pathlib import Path

root = Path(sys.argv[1])
seed = Path(sys.argv[2]).resolve()
keys = ("digest", "fileCount", "symlinkCount", "byteCount")
components = {}
for label in ("clang-toolchain", "rust-toolchain"):
    source = json.loads((root / f"{label}-seed-input.json").read_text())
    copied = json.loads((root / f"{label}-seed-copy.json").read_text())
    if tuple(source[key] for key in keys) != tuple(copied[key] for key in keys):
        raise SystemExit(f"{label} copy differs from its seed proof")
    components[label] = {"sourceProof": source, "copiedProofBeforeUse": copied}
(root / "materialized-toolchain-seed.json").write_text(json.dumps({
    "path": str(seed),
    "compilerObjectsImported": False,
    "installTreeImported": False,
    "pinnedDownloadedToolchainsOnly": True,
    "components": components,
}, indent=2) + "\n", encoding="utf-8")
PY
else
  printf 'null\n' > "$bundle_root/materialized-toolchain-seed.json"
fi

"$python" "$proof_tool" "$v8_repo" --source-tree > "$bundle_root/zig-v8-source-before.json"
# Reuse only immutable, content-addressed Zig dependency sources. No compiler
# objects, generated metadata, or an earlier V8 output directory is imported.
"$python" "$proof_tool" "$zig_package_cache" > "$bundle_root/zig-package-cache-input.json"
cp -a -- "$zig_package_cache" "$native_cache_root/g/p"
"$python" "$proof_tool" "$native_cache_root/g/p" > "$bundle_root/zig-package-cache-copy.json"
"$python" - "$bundle_root" <<'PY'
import json, sys
from pathlib import Path

root = Path(sys.argv[1])
source = json.loads((root / "zig-package-cache-input.json").read_text())
copied = json.loads((root / "zig-package-cache-copy.json").read_text())
keys = ("digest", "fileCount", "symlinkCount", "byteCount")
if tuple(source[key] for key in keys) != tuple(copied[key] for key in keys):
    raise SystemExit("Zig package source copy differs from its input proof")
PY

if [[ -n $depot_tools_seed ]]; then
  "$python" "$proof_tool" "$depot_tools_seed" > "$bundle_root/depot-tools-seed-input.json"
  cp -a -- "$depot_tools_seed" "$bundle_root/cache/depot_tools-14.9.207.35"
  "$python" "$proof_tool" "$bundle_root/cache/depot_tools-14.9.207.35" \
    > "$bundle_root/depot-tools-seed-copy.json"
  "$python" - "$bundle_root" "$depot_tools_seed" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path

root = Path(sys.argv[1])
seed = Path(sys.argv[2]).resolve()
source = json.loads((root / "depot-tools-seed-input.json").read_text())
copied = json.loads((root / "depot-tools-seed-copy.json").read_text())
keys = ("digest", "fileCount", "symlinkCount", "byteCount")
if tuple(source[key] for key in keys) != tuple(copied[key] for key in keys):
    raise SystemExit("bootstrapped depot_tools copy differs from its seed proof")

python = root / "cache/depot_tools-14.9.207.35/python-bin/python3"
digest = hashlib.sha256(python.read_bytes()).hexdigest()
record = {
    "path": str(seed),
    "bootstrapped": True,
    "sourceProof": source,
    "copiedProofBeforeUse": copied,
    "pythonPath": str(python),
    "pythonSha256": digest,
    "pythonVersion": subprocess.check_output(
        [str(python), "--version"], text=True, stderr=subprocess.STDOUT
    ).strip(),
}
(root / "depot-tools-seed.json").write_text(
    json.dumps(record, indent=2) + "\n", encoding="utf-8"
)
PY
else
  printf 'null\n' > "$bundle_root/depot-tools-seed.json"
fi

if [[ -n $v8_git_seed ]]; then
  seed_head=$(git -C "$v8_git_seed" rev-parse HEAD)
  seed_tree=$(git -C "$v8_git_seed" rev-parse 933ce636c562cd54d68e7f7c93ab5cdffd685fca^{tree})
  "$python" - "$bundle_root/v8-git-seed.json" "$v8_git_seed" "$seed_head" "$seed_tree" <<'PY'
import json, sys
from pathlib import Path

output, seed, head, tree = sys.argv[1:]
Path(output).write_text(json.dumps({
    "path": seed,
    "sourceOnly": True,
    "connectivityVerified": True,
    "head": head,
    "requiredCommit": "933ce636c562cd54d68e7f7c93ab5cdffd685fca",
    "requiredTree": tree,
}, indent=2) + "\n", encoding="utf-8")
PY
else
  printf 'null\n' > "$bundle_root/v8-git-seed.json"
fi

if [[ -n $dependency_git_seed_root ]]; then
  "$python" - "$dependency_git_seed_root" \
    "$bundle_root/dependency-git-seeds.json" \
    "$bundle_root/dependency-git-seeds.tsv" <<'PY'
import json, os, subprocess, sys
from pathlib import Path

seed_root = Path(sys.argv[1]).resolve()
json_path = Path(sys.argv[2])
tsv_path = Path(sys.argv[3])
records = []
seen_origins = set()

for current, directories, _ in os.walk(seed_root):
    directories.sort()
    if ".git" not in directories:
        continue
    directories.remove(".git")
    repository = Path(current).resolve()
    try:
        origin = subprocess.check_output(
            ["git", "-C", str(repository), "remote", "get-url", "origin"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        head = subprocess.check_output(
            ["git", "-C", str(repository), "rev-parse", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        tree = subprocess.check_output(
            ["git", "-C", str(repository), "rev-parse", "HEAD^{tree}"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        subprocess.run(
            [
                "git", "-C", str(repository), "fsck", "--full",
                "--connectivity-only", "--no-dangling",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        continue
    if not origin.startswith(("https://", "http://")) or origin in seen_origins:
        continue
    seen_origins.add(origin)
    records.append({
        "origin": origin,
        "path": str(repository),
        "head": head,
        "tree": tree,
        "sourceOnly": True,
        "connectivityVerified": True,
    })

records.sort(key=lambda item: item["origin"])
json_path.write_text(json.dumps({
    "root": str(seed_root),
    "sourceOnly": True,
    "repositories": records,
}, indent=2) + "\n", encoding="utf-8")
with tsv_path.open("w", encoding="utf-8", newline="\n") as stream:
    for record in records:
        stream.write(f'{record["origin"]}\t{record["path"]}\n')
PY
else
  printf '{"root":null,"sourceOnly":true,"repositories":[]}\n' \
    > "$bundle_root/dependency-git-seeds.json"
  : > "$bundle_root/dependency-git-seeds.tsv"
fi
fi

set +e
(
  cd "$v8_repo"
  git_config_index=0
  export "GIT_CONFIG_KEY_${git_config_index}=uploadpack.allowAnySHA1InWant"
  export "GIT_CONFIG_VALUE_${git_config_index}=true"
  ((git_config_index+=1))
  export "GIT_CONFIG_KEY_${git_config_index}=uploadpack.allowReachableSHA1InWant"
  export "GIT_CONFIG_VALUE_${git_config_index}=true"
  ((git_config_index+=1))
  if [[ -n $v8_git_seed ]]; then
    # The failed acquisition contributed only Git objects. Rewrite only the V8
    # origin to that local object database; every dependency still follows the
    # pinned DEPS URLs. All compiler/output directories remain unique.
    export "GIT_CONFIG_KEY_${git_config_index}=url.${v8_git_seed%/}/.insteadOf"
    export "GIT_CONFIG_VALUE_${git_config_index}=https://chromium.googlesource.com/v8/v8.git"
    ((git_config_index+=1))
  fi
  while IFS=$'\t' read -r origin repository; do
    [[ -n $origin && $origin != "https://chromium.googlesource.com/v8/v8.git" ]] || continue
    export "GIT_CONFIG_KEY_${git_config_index}=url.${repository%/}/.insteadOf"
    export "GIT_CONFIG_VALUE_${git_config_index}=${origin}"
    ((git_config_index+=1))
  done < "$bundle_root/dependency-git-seeds.tsv"
  export GIT_CONFIG_COUNT=$git_config_index
  export GIT_ALLOW_PROTOCOL="file:https:http"
  # `zig build -jN` limits Zig's own scheduler, but Chromium's autoninja
  # otherwise expands back to logical-CPU-count + 2.  Derive autoninja's
  # addition so the public --jobs value is also the exact V8 compiler limit.
  ninja_cpu_count=$(getconf _NPROCESSORS_ONLN)
  export NINJA_CORE_ADDITION=$((jobs - ninja_cpu_count))
  export NINJA_SUMMARIZE_BUILD=1
  "$zig" build build-v8 shared-link-smoke sab-smoke callback-smoke access-check-smoke \
    "-j${jobs}" \
    -Dtarget=x86_64-linux-gnu \
    -Doptimize=ReleaseFast \
    -Dv8_enable_sandbox=false \
    "-Dcache_root=$bundle_root/cache" \
    --cache-dir "$native_cache_root/c" \
    --global-cache-dir "$native_cache_root/g" \
    --summary all
) > "$bundle_root/acquire-build.log" 2>&1
build_exit=$?
set -e
if ((build_exit != 0)); then
  printf 'Linux V8 acquisition/build failed (%d); log=%s\n' "$build_exit" "$bundle_root/acquire-build.log" >&2
  tail -160 "$bundle_root/acquire-build.log" >&2
  exit "$build_exit"
fi

v8_source="$bundle_root/cache/v8-14.9.207.35"
depot_tools="$bundle_root/cache/depot_tools-14.9.207.35"
[[ -d $v8_source && -d $depot_tools ]] || { echo "materialized V8 bundle is incomplete" >&2; exit 1; }

mapfile -t archives < <(
  find "$v8_source/out/linux" -type f -path '*/obj/zig/libc_v8_standalone.a' -print | sort |
    while IFS= read -r candidate; do
      candidate_profile=${candidate%/obj/zig/libc_v8_standalone.a}
      candidate_args="$candidate_profile/args.gn"
      if [[ -f $candidate_args ]] &&
        grep -Eq '^[[:space:]]*use_sysroot[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$candidate_args" &&
        grep -Eq '^[[:space:]]*v8_monolithic[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$candidate_args" &&
        grep -Eq '^[[:space:]]*v8_monolithic_for_shared_library[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$candidate_args"; then
        printf '%s\n' "$candidate"
      fi
    done
)
(( ${#archives[@]} == 1 )) || {
  printf 'expected exactly one sysroot/PIC-built Linux libc_v8_standalone.a, found %d\n' "${#archives[@]}" >&2
  printf '%s\n' "${archives[@]}" >&2
  exit 1
}
archive=${archives[0]}
profile_dir=${archive%/obj/zig/libc_v8_standalone.a}
profile_args="$profile_dir/args.gn"

required_symbols=(
  v8__ForegroundWake__Acquire
  v8__ForegroundWake__Post
  v8__Platform__NotifyIsolateShutdown
  v8__Isolate__SetFailedAccessCheckCallbackFunction
  v8__ArrayBuffer__Detach
  v8__Value__StrictEquals
  v8__WasmStreaming__Finish
  temporal_rs_Instant_from_utf8
)
nm_output="$bundle_root/libc_v8.defined-symbols.txt"
nm -g --defined-only "$archive" > "$nm_output"
for symbol in "${required_symbols[@]}"; do
  grep -Eq "[[:space:]]${symbol}$" "$nm_output" || {
    echo "built V8 archive is missing required symbol: $symbol" >&2
    exit 1
  }
done
undefined_nm_output="$bundle_root/libc_v8.undefined-symbols.txt"
nm -u "$archive" > "$undefined_nm_output"
if grep -Fq '__isoc23_' "$undefined_nm_output"; then
  echo "built V8 archive still depends on host-glibc C23 symbols" >&2
  grep -F '__isoc23_' "$undefined_nm_output" | sort -u >&2
  exit 1
fi

v8_head=$(git -C "$v8_source" rev-parse HEAD)
[[ $v8_head == 933ce636c562cd54d68e7f7c93ab5cdffd685fca ]] || {
  echo "unexpected V8 revision: $v8_head" >&2
  exit 1
}
"$python" "$proof_tool" "$v8_repo" --source-tree > "$bundle_root/zig-v8-source-after.json"
"$python" "$proof_tool" "$v8_source" --source-tree > "$bundle_root/v8-source-proof.json"
"$python" "$proof_tool" "$depot_tools" --source-tree > "$bundle_root/depot-tools-proof.json"
"$python" "$proof_tool" "$native_cache_root/g/p" > "$bundle_root/zig-package-cache-copy-after.json"
if [[ -n $materialized_toolchain_seed ]]; then
  "$python" "$proof_tool" "$v8_source/third_party/llvm-build/Release+Asserts" \
    > "$bundle_root/clang-toolchain-seed-copy-after.json"
  "$python" "$proof_tool" "$v8_source/third_party/rust-toolchain" \
    > "$bundle_root/rust-toolchain-seed-copy-after.json"
fi

"$python" - "$bundle_root" "$bundle_id" "$zig" "$archive" "$profile_args" "$v8_head" \
  "$repo_root/tools/Acquire-LinuxV8Bundle.sh" <<'PY'
from __future__ import annotations
import hashlib, json, sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1]).resolve()
bundle_id, zig, archive_arg, profile_args_arg, v8_head, acquisition_script_arg = sys.argv[2:]
archive = Path(archive_arg).resolve(strict=True)
profile_args = Path(profile_args_arg).resolve(strict=True)
acquisition_script = Path(acquisition_script_arg).resolve(strict=True)

def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

before = json.loads((root / "zig-v8-source-before.json").read_text())
after = json.loads((root / "zig-v8-source-after.json").read_text())
keys = ("digest", "fileCount", "symlinkCount", "byteCount")
if tuple(before[key] for key in keys) != tuple(after[key] for key in keys):
    raise SystemExit("zig-v8-fork source changed during acquisition")
package_input = json.loads((root / "zig-package-cache-input.json").read_text())
package_after = json.loads((root / "zig-package-cache-copy-after.json").read_text())
if tuple(package_input[key] for key in keys) != tuple(package_after[key] for key in keys):
    raise SystemExit("Zig package source copy changed during acquisition")
toolchain_seed = json.loads((root / "materialized-toolchain-seed.json").read_text())
if toolchain_seed is not None:
    for label in ("clang-toolchain", "rust-toolchain"):
        before_use = toolchain_seed["components"][label]["copiedProofBeforeUse"]
        after_use = json.loads((root / f"{label}-seed-copy-after.json").read_text())
        if tuple(before_use[key] for key in keys) != tuple(after_use[key] for key in keys):
            raise SystemExit(f"{label} dependency changed during acquisition")
        toolchain_seed["components"][label]["copiedProofAfterUse"] = after_use
resume_attempts = [
    json.loads(path.read_text(encoding="utf-8"))
    for path in sorted(root.glob("resume-*.json"))
]

manifest = {
    "schema": "darkpanda-dependency-bundle/v1",
    "component": "zig-v8-linux-x64",
    "completeAcceptanceArtifact": False,
    "networkAcquisition": True,
    "bundleId": bundle_id,
    "createdAtUtc": datetime.now(timezone.utc).isoformat(),
    "target": "x86_64-linux-gnu",
    "v8Version": "14.9.207.35",
    "v8Revision": v8_head,
    "chromiumMajor": 149,
    "buildRoot": str(root),
    "acquisitionScript": {
        "path": str(acquisition_script),
        "sha256": sha(acquisition_script),
    },
    "toolchain": {"zig": {"path": zig, "sha256": sha(Path(zig))}},
    "sourceSeed": json.loads((root / "v8-git-seed.json").read_text()),
    "depotToolsSeed": json.loads((root / "depot-tools-seed.json").read_text()),
    "dependencyGitSeeds": json.loads((root / "dependency-git-seeds.json").read_text()),
    "materializedToolchainSeed": toolchain_seed,
    "resumeAttempts": resume_attempts,
    "nativeZigCache": json.loads((root / "native-zig-cache.json").read_text()),
    "zigPackageCacheInputProof": json.loads((root / "zig-package-cache-input.json").read_text()),
    "zigPackageCacheCopyProof": package_after,
    "zigV8SourceProof": after,
    "v8SourceProof": json.loads((root / "v8-source-proof.json").read_text()),
    "depotToolsProof": json.loads((root / "depot-tools-proof.json").read_text()),
    "archive": {
        "path": str(archive),
        "size": archive.stat().st_size,
        "sha256": sha(archive),
        "linuxPicRequired": True,
    },
    "gnArgs": {
        "path": str(profile_args),
        "size": profile_args.stat().st_size,
        "sha256": sha(profile_args),
        "useChromiumPinnedSysroot": True,
        "v8Monolithic": True,
        "v8MonolithicForSharedLibrary": True,
    },
    "sharedLibraryLinkProof": {
        "buildStep": "shared-link-smoke",
        "v8TlsMode": "local-dynamic",
        "result": "linked Linux shared library successfully",
        "buildLogPath": str(root / "acquire-build.log"),
    },
    "requiredSymbolProof": {
        "path": str(root / "libc_v8.defined-symbols.txt"),
        "sha256": sha(root / "libc_v8.defined-symbols.txt"),
    },
    "undefinedSymbolProof": {
        "path": str(root / "libc_v8.undefined-symbols.txt"),
        "sha256": sha(root / "libc_v8.undefined-symbols.txt"),
        "forbiddenHostGlibcC23References": "none",
    },
    "buildLog": {
        "path": str(root / "acquire-build.log"),
        "sha256": sha(root / "acquire-build.log"),
    },
}
(root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print(f"LINUX_V8_BUNDLE={root / 'manifest.json'}")
print(f"LINUX_V8_BUNDLE_SHA256={sha(root / 'manifest.json')}")
PY
