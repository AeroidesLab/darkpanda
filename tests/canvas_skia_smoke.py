"""Exercise the real dynamically loaded ABI-v5 Canvas backend through FFI."""

from __future__ import annotations

import argparse
import ctypes
import json
from pathlib import Path

from darkpanda import CanvasDriver, CanvasFallback, ClientProfile, Runtime


def native_backend_identity(path: Path) -> tuple[int, str]:
    library = ctypes.CDLL(str(path))
    library.cs_canvas_backend_abi_version.argtypes = []
    library.cs_canvas_backend_abi_version.restype = ctypes.c_uint32
    library.cs_canvas_backend_version.argtypes = []
    library.cs_canvas_backend_version.restype = ctypes.c_char_p
    version = library.cs_canvas_backend_version()
    if version is None:
        raise AssertionError("Canvas backend returned a null version string")
    return int(library.cs_canvas_backend_abi_version()), version.decode("utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq", required=True)
    parser.add_argument("--canvas", required=True)
    args = parser.parse_args()

    library = Path(args.library).resolve(strict=True)
    wreq = Path(args.wreq).resolve(strict=True)
    canvas = Path(args.canvas).resolve(strict=True)
    for path in (library, wreq, canvas):
        if not path.is_absolute():
            raise AssertionError(f"runtime input is not absolute: {path}")

    with Runtime(
        library_path=library,
        wreq_library_path=wreq,
        canvas_library_path=canvas,
        canvas_driver=CanvasDriver.DYNAMIC,
        canvas_fallback=CanvasFallback.DISABLED,
        profile=ClientProfile.CHROME149,
        locale="en-US",
        timezone="UTC",
    ) as runtime:
        with runtime.new_page() as page:
            page.navigate("data:text/html,<title>dynamic-skia</title>")
            result = json.loads(
                page.evaluate(
                    """
                    (() => {
                      const canvas = document.createElement('canvas');
                      canvas.width = 2;
                      canvas.height = 1;
                      const context = canvas.getContext('2d');
                      const initial = Array.from(context.getImageData(0, 0, 2, 1).data);

                      const source = context.createImageData(1, 1);
                      source.data.set([254, 128, 1, 128]);
                      context.putImageData(source, 0, 0);
                      const roundTrip = Array.from(context.getImageData(0, 0, 1, 1).data);

                      context.reset();
                      context.fillStyle = 'rgba(255, 0, 0, 0.5)';
                      context.fillRect(0, 0, 1, 1);
                      context.fillStyle = 'rgb(0, 0, 255)';
                      context.globalAlpha = 0.5;
                      context.fillRect(1, 0, 1, 1);
                      const blended = Array.from(context.getImageData(0, 0, 2, 1).data);

                      canvas.width = 1;
                      const resized = Array.from(context.getImageData(0, 0, 1, 1).data);
                      return { initial, roundTrip, blended, resized };
                    })()
                    """
                )
            )

    assert result == {
        "initial": [0, 0, 0, 0, 0, 0, 0, 0],
        "roundTrip": [253, 128, 2, 128],
        "blended": [255, 0, 0, 128, 0, 0, 255, 128],
        "resized": [0, 0, 0, 0],
    }, result

    abi, version = native_backend_identity(canvas)
    assert abi == 5, abi
    assert version.strip(), version
    print(
        json.dumps(
            {
                "status": "PASS",
                "driver": "dynamic",
                "fallback": "disabled",
                "backend": "skia",
                "backendAbi": abi,
                "backendVersion": version,
                "canvasLibrary": str(canvas),
                "pixels": result,
            },
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()
