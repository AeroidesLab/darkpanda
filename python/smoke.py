"""Native ABI smoke test; intentionally has no CDP/subprocess fallback."""

from __future__ import annotations

import argparse
import ctypes
import gc
import json
import os
from pathlib import Path
import weakref

from darkpanda import CanvasDriver, ClientProfile, DarkPandaError, Runtime
from darkpanda._native import _Error, _read_bytes


def _bind_lifetime_calls(dll: ctypes.CDLL) -> None:
    dll.dp_page_close.argtypes = [ctypes.c_uint64, ctypes.POINTER(_Error)]
    dll.dp_page_close.restype = ctypes.c_int32
    dll.dp_error_free.argtypes = [ctypes.POINTER(_Error)]
    dll.dp_error_free.restype = None


def _expect_invalid_page_handle(dll: ctypes.CDLL, handle: int) -> None:
    error = _Error()
    status = int(dll.dp_page_close(ctypes.c_uint64(handle), ctypes.byref(error)))
    try:
        message = _read_bytes(error.message).decode("utf-8", "replace")
        assert status == 2, (status, message)
        assert message, "invalid-handle diagnostic was empty"
    finally:
        dll.dp_error_free(ctypes.byref(error))
    assert not error.message.ptr and error.message.len == 0


def _invalid_handle_as_first_call(
    library_path: str,
) -> tuple[ctypes.CDLL, object | None]:
    """Load the DLL and make an allocating error path its first ABI call."""
    path = Path(library_path).resolve(strict=True)
    dll_directory = None
    if os.name == "nt" and hasattr(os, "add_dll_directory"):
        dll_directory = os.add_dll_directory(str(path.parent))
    dll = ctypes.CDLL(str(path))
    _bind_lifetime_calls(dll)
    _expect_invalid_page_handle(dll, 1)
    return dll, dll_directory


def _runtime_kwargs(args: argparse.Namespace) -> dict[str, object]:
    kwargs: dict[str, object] = {
        "library_path": args.library,
        "locale": "en-US",
        "timezone": "UTC",
        "profile": ClientProfile.CHROME149,
    }
    if args.wreq:
        kwargs["wreq_library_path"] = args.wreq
    if args.canvas:
        kwargs["canvas_library_path"] = args.canvas
        kwargs["canvas_driver"] = CanvasDriver.DYNAMIC
    return kwargs


def _exercise_page(runtime: Runtime) -> None:
    with runtime.new_page() as page:
        page.navigate("data:text/html,<title>native</title><main id='ok'>ready</main>")
        result = page.evaluate(
            "({title: document.title, text: document.querySelector('#ok').textContent, "
            "locale: navigator.language, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone})"
        )
        assert json.loads(result) == {
            "title": "native",
            "text": "ready",
            "locale": "en-US",
            "timezone": "UTC",
        }, result
        page.close()
        try:
            page.evaluate("1 + 1")
        except DarkPandaError:
            pass
        else:
            raise AssertionError("closed/generation-invalid page handle was accepted")


def _drop_unclosed_cycle(
    kwargs: dict[str, object],
) -> tuple[weakref.ReferenceType[Runtime], weakref.ReferenceType[object], int]:
    runtime = Runtime(**kwargs)
    page = runtime.new_page()
    page.navigate("data:text/html,<title>gc-finalizer</title>")
    assert page.evaluate("document.title") == "gc-finalizer"

    # Force cyclic-GC rather than CPython reference-count cleanup. The native
    # finalizers must not capture either object strongly.
    runtime._smoke_cycle = page
    return weakref.ref(runtime), weakref.ref(page), int(page._handle.value)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq")
    parser.add_argument("--canvas")
    args = parser.parse_args()

    if not args.wreq:
        parser.error("--wreq is required on every platform")
    if not args.canvas:
        parser.error("--canvas is required on every platform")

    # This must precede Runtime/_Library construction: dp_page_close's error
    # allocation and dp_error_free are the first exported calls after load.
    preflight_dll, dll_directory = _invalid_handle_as_first_call(args.library)
    kwargs = _runtime_kwargs(args)

    # V8 cannot be initialized again after DisposePlatform. The ABI therefore
    # keeps one physical engine for the process and gives each logical Runtime
    # a fresh generation handle; exercise that contract explicitly.
    for _ in range(2):
        with Runtime(**kwargs) as runtime:
            _exercise_page(runtime)

    runtime_ref, page_ref, abandoned_page_handle = _drop_unclosed_cycle(kwargs)
    for _ in range(5):
        gc.collect()
        if runtime_ref() is None and page_ref() is None:
            break
    assert page_ref() is None, "unclosed Page was retained by its finalizer"
    assert runtime_ref() is None, "unclosed Runtime was retained by its finalizer"
    _expect_invalid_page_handle(preflight_dll, abandoned_page_handle)

    # Finalizers must release both the page registry slot and the exclusive
    # logical runtime reservation so another generation can start immediately.
    with Runtime(**kwargs) as runtime:
        _exercise_page(runtime)

    # Keep the raw CDLL and Windows search-directory cookie alive through all
    # finalizer/reopen checks.
    _ = (preflight_dll, dll_directory)
    print("darkpanda native ctypes smoke: PASS")


if __name__ == "__main__":
    main()
