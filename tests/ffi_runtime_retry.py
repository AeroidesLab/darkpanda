"""Direct C ABI regression for pre-V8 dependency failure and adjacent retry."""

from __future__ import annotations

import argparse
import ctypes
import os
from pathlib import Path
import sys


STATUS_OK = 0
STATUS_INITIALIZATION_FAILED = 6
CLIENT_PROFILE_CHROME149 = 149


class Slice(ctypes.Structure):
    _fields_ = [("ptr", ctypes.POINTER(ctypes.c_uint8)), ("len", ctypes.c_size_t)]


class Bytes(ctypes.Structure):
    _fields_ = [("ptr", ctypes.POINTER(ctypes.c_uint8)), ("len", ctypes.c_size_t)]


class Error(ctypes.Structure):
    _fields_ = [("code", ctypes.c_int32), ("message", Bytes)]


class RuntimeOptions(ctypes.Structure):
    _fields_ = [
        ("abi_version", ctypes.c_uint32),
        ("struct_size", ctypes.c_uint32),
        ("wreq_transport_path", Slice),
        ("navigation_timeout_ms", ctypes.c_uint32),
        ("reserved", ctypes.c_uint8 * 28),
        ("application_locale", Slice),
        ("timezone", Slice),
        ("client_profile", ctypes.c_uint32),
        ("reserved_tail", ctypes.c_uint32),
        ("fingerprint_profile_json", Slice),
        ("wreq_dns_nameservers", Slice),
        ("canvas_backend_path", Slice),
        ("canvas_driver", ctypes.c_uint32),
        ("canvas_fallback", ctypes.c_uint32),
    ]


def owned_slice(value: str) -> tuple[Slice, object | None]:
    encoded = value.encode("utf-8")
    if not encoded:
        return Slice(None, 0), None
    storage = (ctypes.c_uint8 * len(encoded)).from_buffer_copy(encoded)
    return (
        Slice(ctypes.cast(storage, ctypes.POINTER(ctypes.c_uint8)), len(encoded)),
        storage,
    )


def read_bytes(value: Bytes) -> bytes:
    if not value.ptr or value.len == 0:
        return b""
    return ctypes.string_at(value.ptr, value.len)


class Library:
    def __init__(self, path: Path) -> None:
        self.dll_directory = None
        if os.name == "nt":
            self.dll_directory = os.add_dll_directory(str(path.parent))
        self.dll = ctypes.CDLL(str(path))
        self.dll.dp_runtime_options_init_sized.argtypes = [
            ctypes.c_void_p,
            ctypes.c_size_t,
        ]
        self.dll.dp_runtime_options_init_sized.restype = ctypes.c_int32
        self.dll.dp_runtime_create.argtypes = [
            ctypes.POINTER(RuntimeOptions),
            ctypes.POINTER(ctypes.c_uint64),
            ctypes.POINTER(Error),
        ]
        self.dll.dp_runtime_create.restype = ctypes.c_int32
        self.dll.dp_runtime_destroy.argtypes = [
            ctypes.c_uint64,
            ctypes.POINTER(Error),
        ]
        self.dll.dp_runtime_destroy.restype = ctypes.c_int32
        self.dll.dp_error_free.argtypes = [ctypes.POINTER(Error)]
        self.dll.dp_error_free.restype = None


def initialized_options(library: Library) -> RuntimeOptions:
    options = RuntimeOptions()
    status = int(
        library.dll.dp_runtime_options_init_sized(
            ctypes.byref(options), ctypes.sizeof(options)
        )
    )
    if status != STATUS_OK:
        raise AssertionError(f"RuntimeOptions initialization failed: {status}")
    options.client_profile = CLIENT_PROFILE_CHROME149
    return options


def library_name(stem: str) -> str:
    if os.name == "nt":
        return f"{stem}.dll"
    if sys.platform == "darwin":
        return f"lib{stem}.dylib"
    return f"lib{stem}.so"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    args = parser.parse_args()

    library_path = Path(args.library).resolve(strict=True)
    expected_wreq = library_path.with_name(library_name("wreq"))
    expected_canvas = library_path.with_name(library_name("canvas"))
    for dependency in (expected_wreq, expected_canvas):
        if not dependency.is_file():
            raise FileNotFoundError(dependency)

    library = Library(library_path)

    bad_options = initialized_options(library)
    bad_options.wreq_transport_path, bad_storage = owned_slice(
        str(expected_wreq.with_name("missing-" + expected_wreq.name))
    )
    bad_handle = ctypes.c_uint64(0)
    bad_error = Error()
    bad_status = int(
        library.dll.dp_runtime_create(
            ctypes.byref(bad_options),
            ctypes.byref(bad_handle),
            ctypes.byref(bad_error),
        )
    )
    _ = bad_storage
    try:
        if bad_status != STATUS_INITIALIZATION_FAILED:
            detail = read_bytes(bad_error.message).decode("utf-8", "replace")
            raise AssertionError(f"bad wreq path returned {bad_status}: {detail}")
        if bad_handle.value != 0:
            raise AssertionError("failed runtime creation returned a live handle")
    finally:
        library.dll.dp_error_free(ctypes.byref(bad_error))

    bad_canvas_options = initialized_options(library)
    bad_canvas_options.canvas_backend_path, bad_canvas_storage = owned_slice(
        str(expected_canvas.with_name("missing-" + expected_canvas.name))
    )
    bad_canvas_handle = ctypes.c_uint64(0)
    bad_canvas_error = Error()
    bad_canvas_status = int(
        library.dll.dp_runtime_create(
            ctypes.byref(bad_canvas_options),
            ctypes.byref(bad_canvas_handle),
            ctypes.byref(bad_canvas_error),
        )
    )
    _ = bad_canvas_storage
    try:
        if bad_canvas_status != STATUS_INITIALIZATION_FAILED:
            detail = read_bytes(bad_canvas_error.message).decode("utf-8", "replace")
            raise AssertionError(
                f"bad Canvas path returned {bad_canvas_status}: {detail}"
            )
        if bad_canvas_handle.value != 0:
            raise AssertionError("failed Canvas preflight returned a live handle")
    finally:
        library.dll.dp_error_free(ctypes.byref(bad_canvas_error))

    good_options = initialized_options(library)
    good_handle = ctypes.c_uint64(0)
    good_error = Error()
    good_status = int(
        library.dll.dp_runtime_create(
            ctypes.byref(good_options),
            ctypes.byref(good_handle),
            ctypes.byref(good_error),
        )
    )
    if good_status != STATUS_OK:
        try:
            detail = read_bytes(good_error.message).decode("utf-8", "replace")
            raise AssertionError(
                f"corrected runtime creation returned {good_status}: {detail}"
            )
        finally:
            library.dll.dp_error_free(ctypes.byref(good_error))

    destroy_error = Error()
    destroy_status = int(
        library.dll.dp_runtime_destroy(good_handle, ctypes.byref(destroy_error))
    )
    try:
        if destroy_status != STATUS_OK:
            detail = read_bytes(destroy_error.message).decode("utf-8", "replace")
            raise AssertionError(f"runtime destroy returned {destroy_status}: {detail}")
    finally:
        library.dll.dp_error_free(ctypes.byref(destroy_error))

    print("darkpanda native bad-wreq -> bad-Canvas -> adjacent retry: PASS")


if __name__ == "__main__":
    main()
