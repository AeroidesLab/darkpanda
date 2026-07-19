"""Direct ABI regression for pre-V8 wreq/Canvas failure and adjacent retry."""

from __future__ import annotations

import argparse
import ctypes
from pathlib import Path

from darkpanda import _native


def initialized_options(library: _native._Library) -> _native._RuntimeOptions:
    options = _native._RuntimeOptions()
    status = int(
        library.dll.dp_runtime_options_init_sized(
            ctypes.byref(options), ctypes.sizeof(options)
        )
    )
    if status != _native.Status.OK:
        raise AssertionError(f"RuntimeOptions initialization failed: {status}")
    options.client_profile = _native.ClientProfile._NATIVE_IDS[
        _native.ClientProfile.CHROME149
    ]
    return options


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    args = parser.parse_args()

    library_path = Path(args.library).resolve(strict=True)
    expected_wreq = library_path.with_name("wreq.dll")
    if not expected_wreq.is_file():
        raise FileNotFoundError(expected_wreq)
    expected_canvas = library_path.with_name("darkpanda_canvas_backend.dll")
    if not expected_canvas.is_file():
        raise FileNotFoundError(expected_canvas)

    library = _native._Library(library_path)

    # The first call reaches the native ABI with an absolute but nonexistent
    # transport path. It must fail without initializing and disposing V8.
    bad_options = initialized_options(library)
    missing_path = expected_wreq.with_name("missing-wreq.dll")
    bad_slice, bad_storage = _native._owned_slice(str(missing_path))
    bad_options.wreq_transport_path = bad_slice
    bad_handle = ctypes.c_uint64(0)
    bad_error = _native._Error()
    bad_status = int(
        library.dll.dp_runtime_create(
            ctypes.byref(bad_options),
            ctypes.byref(bad_handle),
            ctypes.byref(bad_error),
        )
    )
    _ = bad_storage
    try:
        if bad_status != _native.Status.INITIALIZATION_FAILED:
            detail = _native._read_bytes(bad_error.message).decode("utf-8", "replace")
            raise AssertionError(f"bad wreq path returned {bad_status}: {detail}")
        if bad_handle.value != 0:
            raise AssertionError("failed runtime creation returned a live handle")
    finally:
        library.dll.dp_error_free(ctypes.byref(bad_error))

    # wreq now resolves correctly, but an explicit nonexistent Canvas module
    # must also fail during App preflight, before V8 owns process-global state.
    bad_canvas_options = initialized_options(library)
    missing_canvas = expected_canvas.with_name("missing-darkpanda-canvas-backend.dll")
    bad_canvas_slice, bad_canvas_storage = _native._owned_slice(str(missing_canvas))
    bad_canvas_options.canvas_backend_path = bad_canvas_slice
    bad_canvas_handle = ctypes.c_uint64(0)
    bad_canvas_error = _native._Error()
    bad_canvas_status = int(
        library.dll.dp_runtime_create(
            ctypes.byref(bad_canvas_options),
            ctypes.byref(bad_canvas_handle),
            ctypes.byref(bad_canvas_error),
        )
    )
    _ = bad_canvas_storage
    try:
        if bad_canvas_status != _native.Status.INITIALIZATION_FAILED:
            detail = _native._read_bytes(bad_canvas_error.message).decode("utf-8", "replace")
            raise AssertionError(f"bad Canvas path returned {bad_canvas_status}: {detail}")
        if bad_canvas_handle.value != 0:
            raise AssertionError("failed Canvas preflight returned a live handle")
    finally:
        library.dll.dp_error_free(ctypes.byref(bad_canvas_error))

    # Retry in the same process with an empty path. This simultaneously proves
    # that V8 remained untouched by the failure and that a C embedder locates
    # wreq.dll beside darkpanda.dll rather than beside python.exe.
    good_options = initialized_options(library)
    good_handle = ctypes.c_uint64(0)
    good_error = _native._Error()
    good_status = int(
        library.dll.dp_runtime_create(
            ctypes.byref(good_options),
            ctypes.byref(good_handle),
            ctypes.byref(good_error),
        )
    )
    if good_status != _native.Status.OK:
        try:
            detail = _native._read_bytes(good_error.message).decode("utf-8", "replace")
            raise AssertionError(f"corrected runtime creation returned {good_status}: {detail}")
        finally:
            library.dll.dp_error_free(ctypes.byref(good_error))

    destroy_error = _native._Error()
    destroy_status = int(
        library.dll.dp_runtime_destroy(good_handle, ctypes.byref(destroy_error))
    )
    try:
        if destroy_status != _native.Status.OK:
            detail = _native._read_bytes(destroy_error.message).decode("utf-8", "replace")
            raise AssertionError(f"runtime destroy returned {destroy_status}: {detail}")
    finally:
        library.dll.dp_error_free(ctypes.byref(destroy_error))

    print("darkpanda native bad-wreq -> bad-Canvas -> adjacent runtime retry: PASS")


if __name__ == "__main__":
    main()
