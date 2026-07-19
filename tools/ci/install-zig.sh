#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: install-zig.sh VERSION ARCHITECTURE SHA256 INSTALL_ROOT" >&2
  exit 2
}

[[ $# -eq 4 ]] || usage
version=$1
architecture=$2
expected_sha=$3
install_root=$4
case "$(uname -s)" in
  Linux) platform=linux ;;
  Darwin) platform=macos ;;
  *) echo "unsupported host: $(uname -s)" >&2; exit 2 ;;
esac

archive="$RUNNER_TEMP/zig-${architecture}-${platform}-${version}.tar.xz"
url="https://ziglang.org/download/${version}/zig-${architecture}-${platform}-${version}.tar.xz"
rm -rf -- "$install_root"
mkdir -p -- "$install_root"
curl --fail --location --retry 5 --retry-all-errors --output "$archive" "$url"
actual_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
[[ $actual_sha == "$expected_sha" ]] || {
  echo "Zig archive SHA-256 mismatch: expected $expected_sha, got $actual_sha" >&2
  exit 1
}
tar -xJf "$archive" --strip-components=1 -C "$install_root"
reported=$("$install_root/zig" version)
[[ $reported == "$version" ]] || {
  echo "Zig version mismatch: expected $version, got $reported" >&2
  exit 1
}
printf '%s\n' "$install_root" >> "$GITHUB_PATH"
printf 'zig=%s\n' "$install_root/zig" >> "$GITHUB_OUTPUT"
echo "Installed Zig $reported at $install_root/zig"
