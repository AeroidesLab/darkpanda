"""Attest one already-hashed DarkPanda runtime artifact set."""

from __future__ import annotations

import argparse
import ctypes
import json
import sys
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
    args = parser.parse_args()

    python_root = args.python_root.resolve(strict=True)
    sys.path.insert(0, str(python_root))

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
        "dp_canvas_backend_abi_version",
        "dp_canvas_backend_version",
    )

    from darkpanda import CanvasDriver, ClientProfile, Runtime

    with Runtime(
        library_path=args.library,
        wreq_library_path=args.wreq,
        canvas_library_path=args.canvas,
        canvas_driver=CanvasDriver.DYNAMIC,
        navigation_timeout_ms=30_000,
        locale="en-US",
        timezone="UTC",
        profile=ClientProfile.CHROME149,
    ) as runtime:
        identity = runtime.identity_manifest()
        with runtime.new_page() as page:
            page.navigate("data:text/html,<canvas id='c' width='1' height='1'></canvas>")
            pixels = json.loads(
                page.evaluate(
                    """
                    (() => {
                      const c = document.querySelector('#c');
                      const x = c.getContext('2d');
                      x.fillStyle = 'rgb(17,99,201)';
                      x.fillRect(0, 0, 1, 1);
                      return Array.from(x.getImageData(0, 0, 1, 1).data);
                    })()
                    """
                )
            )

    expected_pixels = [17, 99, 201, 255]
    if pixels != expected_pixels:
        raise AssertionError(f"unexpected Skia pixels: {pixels!r}")
    if canvas_abi != 2 or "rust-skia/0.99.0" not in canvas_version:
        raise AssertionError(
            f"unexpected Canvas backend identity: ABI={canvas_abi}, {canvas_version!r}"
        )

    print(
        json.dumps(
            {
                "status": "PASS",
                "ffiAbiVersion": ffi_abi,
                "ffiVersion": ffi_version,
                "wreqAbiVersion": wreq_abi,
                "wreqVersion": wreq_version,
                "canvasAbiVersion": canvas_abi,
                "canvasVersion": canvas_version,
                "canvasPixels": pixels,
                "identity": identity,
                "paths": {
                    "ffi": str(args.library),
                    "wreq": str(args.wreq),
                    "canvas": str(args.canvas),
                },
            },
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()
