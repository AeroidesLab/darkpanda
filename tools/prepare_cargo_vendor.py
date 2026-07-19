#!/usr/bin/env python3
"""Apply DarkPanda's deterministic fixes to a copied Cargo vendor tree."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


OLD_SKIA_LINUX_FONTS = """    // Use pkg-config for system libraries when available
    add_pkg_config_libs(&mut libs, "freetype2", &["freetype"]);
    add_pkg_config_libs(&mut libs, "fontconfig", &["fontconfig"]);
"""

NEW_SKIA_LINUX_FONTS = """    // embed-freetype builds the required FreeType objects into Skia. In that
    // mode DarkPanda also disables fontconfig in GN, so adding host link
    // libraries here would reintroduce an unnecessary system dependency.
    if !features[feature::EMBED_FREETYPE] {
        add_pkg_config_libs(&mut libs, "freetype2", &["freetype"]);
        add_pkg_config_libs(&mut libs, "fontconfig", &["fontconfig"]);
    }
"""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("vendor_root", type=Path)
    args = parser.parse_args()

    root = args.vendor_root.resolve(strict=True)
    package = root / "skia-bindings-0.99.0"
    source = package / "build_support/platform/linux.rs"
    checksum_file = package / ".cargo-checksum.json"
    if not source.is_file() or not checksum_file.is_file():
        raise SystemExit("vendored skia-bindings 0.99.0 is incomplete")

    original_bytes = source.read_bytes()
    original = original_bytes.decode("utf-8")
    if NEW_SKIA_LINUX_FONTS in original:
        status = "already-prepared"
    else:
        count = original.count(OLD_SKIA_LINUX_FONTS)
        if count != 1:
            raise SystemExit(
                f"expected one skia-bindings Linux font-link block, found {count}"
            )
        source.write_text(
            original.replace(OLD_SKIA_LINUX_FONTS, NEW_SKIA_LINUX_FONTS),
            encoding="utf-8",
            newline="\n",
        )
        status = "patched"

    checksum = json.loads(checksum_file.read_text(encoding="utf-8"))
    relative = source.relative_to(package).as_posix()
    if relative not in checksum.get("files", {}):
        raise SystemExit(f"Cargo checksum does not list {relative}")
    checksum["files"][relative] = sha256(source)
    checksum_file.write_text(
        json.dumps(checksum, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
        newline="\n",
    )

    print(
        json.dumps(
            {
                "schema": "darkpanda-cargo-vendor-preparation/v1",
                "status": status,
                "package": "skia-bindings-0.99.0",
                "file": relative,
                "beforeSha256": hashlib.sha256(original_bytes).hexdigest(),
                "afterSha256": sha256(source),
                "cargoChecksumSha256": sha256(checksum_file),
                "reason": "avoid Linux system freetype/fontconfig links when embed-freetype is enabled",
            },
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()
