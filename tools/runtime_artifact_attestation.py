"""Attest that one DarkPanda runtime artifact set can be loaded."""

from __future__ import annotations

import argparse
import ctypes
import json
from pathlib import Path


def absolute_file(value: str) -> Path:
    path = Path(value).resolve(strict=True)
    if not path.is_file() or not path.is_absolute():
        raise argparse.ArgumentTypeError(f"not an absolute file: {path}")
    return path


def exported_identity(
    path: Path, abi_symbol: str, version_symbol: str
) -> tuple[int, str]:
    library = ctypes.CDLL(str(path))
    abi = getattr(library, abi_symbol)
    abi.argtypes = []
    abi.restype = ctypes.c_uint32
    version = getattr(library, version_symbol)
    version.argtypes = []
    version.restype = ctypes.c_char_p
    value = version()
    if value is None:
        raise RuntimeError(f"{version_symbol} returned null for {path}")
    return int(abi()), value.decode("utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--python-root", required=True, type=Path)
    parser.add_argument("--library", required=True, type=absolute_file)
    parser.add_argument("--wreq", required=True, type=absolute_file)
    parser.add_argument("--canvas", required=True, type=absolute_file)
    parser.add_argument("--html5ever", required=True, type=absolute_file)
    args = parser.parse_args()

    args.python_root.resolve(strict=True)
    ffi_abi, ffi_version = exported_identity(
        args.library, "dp_abi_version", "dp_version"
    )
    wreq_abi, wreq_version = exported_identity(
        args.wreq,
        "wreq_transport_abi_version",
        "wreq_transport_version",
    )
    canvas_abi, canvas_version = exported_identity(
        args.canvas,
        "cs_canvas_backend_abi_version",
        "cs_canvas_backend_version",
    )
    html5ever_library = ctypes.CDLL(str(args.html5ever))

    if (
        ffi_abi < 1
        or not ffi_version.strip()
        or wreq_abi < 1
        or not wreq_version.strip()
        or canvas_abi != 5
        or not canvas_version.strip()
    ):
        raise AssertionError(
            "invalid runtime library identity: "
            f"ffi={ffi_abi}/{ffi_version!r}, "
            f"wreq={wreq_abi}/{wreq_version!r}, "
            f"canvas={canvas_abi}/{canvas_version!r}"
        )

    paths = {
        "ffi": str(args.library),
        "wreq": str(args.wreq),
        "canvas": str(args.canvas),
        "html5ever": str(args.html5ever),
    }
    print(
        json.dumps(
            {
                "schema": "darkpanda-runtime-load-attestation/v1",
                "status": "PASS",
                "ffiAbiVersion": ffi_abi,
                "ffiVersion": ffi_version,
                "wreqAbiVersion": wreq_abi,
                "wreqVersion": wreq_version,
                "canvasAbiVersion": canvas_abi,
                "canvasVersion": canvas_version,
                "loadedLibraries": list(paths.values()),
                "paths": paths,
            },
            separators=(",", ":"),
        )
    )
    del html5ever_library


if __name__ == "__main__":
    main()
