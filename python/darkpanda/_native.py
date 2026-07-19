"""ctypes binding for the direct DarkPanda embedding ABI.

The binding talks to ``darkpanda.dll`` in-process. It deliberately contains no
CDP client, localhost transport, or subprocess fallback.
"""

from __future__ import annotations

import ctypes
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from collections.abc import Sequence
from typing import Final, Mapping, Any
import weakref


ABI_VERSION: Final = 1


class Status:
    OK = 0
    INVALID_ARGUMENT = 1
    INVALID_HANDLE = 2
    CLOSED = 3
    BUSY = 4
    OUT_OF_MEMORY = 5
    INITIALIZATION_FAILED = 6
    NAVIGATION_FAILED = 7
    EVALUATION_FAILED = 8
    CANCELLED = 9
    TIMEOUT = 10
    INTERNAL_ERROR = 11


class ClientProfile:
    DARKPANDA = "darkpanda"
    CHROME149 = "chrome149"

    _NATIVE_IDS: Final = {DARKPANDA: 1, CHROME149: 149}


class CanvasDriver:
    ENVIRONMENT = "environment"
    SOFTWARE = "software"
    DYNAMIC = "dynamic"

    _NATIVE_IDS: Final = {ENVIRONMENT: 0, SOFTWARE: 1, DYNAMIC: 2}


class CanvasFallback:
    DISABLED = "disabled"
    SOFTWARE = "software"

    _NATIVE_IDS: Final = {DISABLED: 0, SOFTWARE: 1}


class DarkPandaError(RuntimeError):
    def __init__(self, status: int, message: str) -> None:
        self.status = status
        super().__init__(message or f"DarkPanda native error {status}")


class JavaScriptError(DarkPandaError):
    pass


class _Slice(ctypes.Structure):
    _fields_ = [("ptr", ctypes.POINTER(ctypes.c_uint8)), ("len", ctypes.c_size_t)]


class _Bytes(ctypes.Structure):
    _fields_ = [("ptr", ctypes.POINTER(ctypes.c_uint8)), ("len", ctypes.c_size_t)]


class _Error(ctypes.Structure):
    _fields_ = [("code", ctypes.c_int32), ("message", _Bytes)]


class _RuntimeOptions(ctypes.Structure):
    _fields_ = [
        ("abi_version", ctypes.c_uint32),
        ("struct_size", ctypes.c_uint32),
        ("wreq_transport_path", _Slice),
        ("navigation_timeout_ms", ctypes.c_uint32),
        ("reserved", ctypes.c_uint8 * 28),
        ("application_locale", _Slice),
        ("timezone", _Slice),
        ("client_profile", ctypes.c_uint32),
        ("reserved_tail", ctypes.c_uint32),
        ("fingerprint_profile_json", _Slice),
        ("wreq_dns_nameservers", _Slice),
        ("canvas_backend_path", _Slice),
        ("canvas_driver", ctypes.c_uint32),
        ("canvas_fallback", ctypes.c_uint32),
    ]


class _NavigationOptions(ctypes.Structure):
    _fields_ = [
        ("abi_version", ctypes.c_uint32),
        ("struct_size", ctypes.c_uint32),
        ("timeout_ms", ctypes.c_uint32),
        ("reserved", ctypes.c_uint8 * 20),
    ]


class _EvaluateOptions(ctypes.Structure):
    _fields_ = [
        ("abi_version", ctypes.c_uint32),
        ("struct_size", ctypes.c_uint32),
        ("promise_timeout_ms", ctypes.c_uint32),
        ("reserved", ctypes.c_uint8 * 20),
    ]


class _ClickOptions(ctypes.Structure):
    _fields_ = [
        ("abi_version", ctypes.c_uint32),
        ("struct_size", ctypes.c_uint32),
        ("frame_id", ctypes.c_uint32),
        ("timeout_ms", ctypes.c_uint32),
        ("pierce_shadow", ctypes.c_uint8),
        ("reserved0", ctypes.c_uint8 * 3),
        ("move_delay_ms", ctypes.c_uint32),
        ("press_delay_ms", ctypes.c_uint32),
        ("reserved", ctypes.c_uint8 * 4),
    ]


class _EvaluateResult(ctypes.Structure):
    _fields_ = [("value", _Bytes), ("is_error", ctypes.c_uint8), ("reserved", ctypes.c_uint8 * 7)]


def _assert_abi_layout() -> None:
    if ctypes.sizeof(ctypes.c_void_p) != 8:
        raise RuntimeError("the packaged DarkPanda ctypes ABI requires a 64-bit Python")

    sizes = {
        _Slice: 16,
        _Bytes: 16,
        _Error: 24,
        _RuntimeOptions: 152,
        _NavigationOptions: 32,
        _EvaluateOptions: 32,
        _ClickOptions: 32,
        _EvaluateResult: 24,
    }
    for structure, expected in sizes.items():
        actual = ctypes.sizeof(structure)
        if actual != expected:
            raise RuntimeError(f"{structure.__name__} ABI size mismatch: expected {expected}, got {actual}")

    offsets = {
        (_Slice, "ptr"): 0,
        (_Slice, "len"): 8,
        (_Error, "code"): 0,
        (_Error, "message"): 8,
        (_RuntimeOptions, "abi_version"): 0,
        (_RuntimeOptions, "struct_size"): 4,
        (_RuntimeOptions, "wreq_transport_path"): 8,
        (_RuntimeOptions, "navigation_timeout_ms"): 24,
        (_RuntimeOptions, "reserved"): 28,
        (_RuntimeOptions, "application_locale"): 56,
        (_RuntimeOptions, "timezone"): 72,
        (_RuntimeOptions, "client_profile"): 88,
        (_RuntimeOptions, "reserved_tail"): 92,
        (_RuntimeOptions, "fingerprint_profile_json"): 96,
        (_RuntimeOptions, "wreq_dns_nameservers"): 112,
        (_RuntimeOptions, "canvas_backend_path"): 128,
        (_RuntimeOptions, "canvas_driver"): 144,
        (_RuntimeOptions, "canvas_fallback"): 148,
        (_NavigationOptions, "timeout_ms"): 8,
        (_EvaluateOptions, "promise_timeout_ms"): 8,
        (_ClickOptions, "frame_id"): 8,
        (_ClickOptions, "timeout_ms"): 12,
        (_ClickOptions, "pierce_shadow"): 16,
        (_ClickOptions, "move_delay_ms"): 20,
        (_ClickOptions, "press_delay_ms"): 24,
        (_EvaluateResult, "value"): 0,
        (_EvaluateResult, "is_error"): 16,
    }
    for (structure, field), expected in offsets.items():
        actual = getattr(structure, field).offset
        if actual != expected:
            raise RuntimeError(
                f"{structure.__name__}.{field} ABI offset mismatch: expected {expected}, got {actual}"
            )


_assert_abi_layout()


def _owned_slice(value: str) -> tuple[_Slice, object]:
    encoded = value.encode("utf-8")
    if not encoded:
        return _Slice(None, 0), None
    storage = (ctypes.c_uint8 * len(encoded)).from_buffer_copy(encoded)
    return _Slice(ctypes.cast(storage, ctypes.POINTER(ctypes.c_uint8)), len(encoded)), storage


def _read_bytes(value: _Bytes) -> bytes:
    if not value.ptr or value.len == 0:
        return b""
    return ctypes.string_at(value.ptr, value.len)


def _discard_native_error(library: "_Library", error: _Error) -> None:
    """Release a finalizer diagnostic without raising from GC/interpreter exit."""
    try:
        library.dll.dp_error_free(ctypes.byref(error))
    except Exception:
        # weakref.finalize must never surface an unraisable exception. The DLL
        # remains process-loaded during normal GC; this only protects partial
        # interpreter/module teardown and foreign-loader failures.
        pass


def _finalize_runtime(library: "_Library", handle: int) -> None:
    error = _Error()
    try:
        library.dll.dp_runtime_destroy(ctypes.c_uint64(handle), ctypes.byref(error))
    except Exception:
        pass
    finally:
        _discard_native_error(library, error)


def _finalize_page(library: "_Library", handle: int) -> None:
    error = _Error()
    try:
        library.dll.dp_page_close(ctypes.c_uint64(handle), ctypes.byref(error))
    except Exception:
        pass
    finally:
        _discard_native_error(library, error)


class _Library:
    def __init__(self, path: Path) -> None:
        self.path = path.resolve(strict=True)
        self._dll_directory = None
        if os.name == "nt" and hasattr(os, "add_dll_directory"):
            self._dll_directory = os.add_dll_directory(str(self.path.parent))
        self.dll = ctypes.CDLL(str(self.path))
        self._bind()
        actual = int(self.dll.dp_abi_version())
        if actual != ABI_VERSION:
            raise RuntimeError(f"darkpanda ABI mismatch: Python={ABI_VERSION}, DLL={actual}")

    def _bind(self) -> None:
        d = self.dll
        d.dp_abi_version.argtypes = []
        d.dp_abi_version.restype = ctypes.c_uint32
        d.dp_version.argtypes = []
        d.dp_version.restype = ctypes.c_char_p
        d.dp_runtime_options_init.argtypes = [ctypes.POINTER(_RuntimeOptions)]
        d.dp_runtime_options_init.restype = None
        d.dp_runtime_options_init_sized.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        d.dp_runtime_options_init_sized.restype = ctypes.c_int32
        d.dp_navigation_options_init.argtypes = [ctypes.POINTER(_NavigationOptions)]
        d.dp_navigation_options_init.restype = None
        d.dp_evaluate_options_init.argtypes = [ctypes.POINTER(_EvaluateOptions)]
        d.dp_evaluate_options_init.restype = None
        d.dp_click_options_init.argtypes = [ctypes.POINTER(_ClickOptions)]
        d.dp_click_options_init.restype = None
        d.dp_bytes_free.argtypes = [ctypes.POINTER(_Bytes)]
        d.dp_bytes_free.restype = None
        d.dp_error_free.argtypes = [ctypes.POINTER(_Error)]
        d.dp_error_free.restype = None
        d.dp_evaluate_result_free.argtypes = [ctypes.POINTER(_EvaluateResult)]
        d.dp_evaluate_result_free.restype = None

        d.dp_runtime_create.argtypes = [
            ctypes.POINTER(_RuntimeOptions),
            ctypes.POINTER(ctypes.c_uint64),
            ctypes.POINTER(_Error),
        ]
        d.dp_runtime_create.restype = ctypes.c_int32
        d.dp_runtime_destroy.argtypes = [ctypes.c_uint64, ctypes.POINTER(_Error)]
        d.dp_runtime_destroy.restype = ctypes.c_int32
        d.dp_runtime_identity_manifest.argtypes = [
            ctypes.c_uint64,
            ctypes.POINTER(_Bytes),
            ctypes.POINTER(_Error),
        ]
        d.dp_runtime_identity_manifest.restype = ctypes.c_int32
        d.dp_page_create.argtypes = [ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(_Error)]
        d.dp_page_create.restype = ctypes.c_int32
        d.dp_page_close.argtypes = [ctypes.c_uint64, ctypes.POINTER(_Error)]
        d.dp_page_close.restype = ctypes.c_int32
        d.dp_page_cancel.argtypes = [ctypes.c_uint64]
        d.dp_page_cancel.restype = ctypes.c_int32
        d.dp_page_navigate.argtypes = [
            ctypes.c_uint64,
            _Slice,
            ctypes.POINTER(_NavigationOptions),
            ctypes.POINTER(_Error),
        ]
        d.dp_page_navigate.restype = ctypes.c_int32
        d.dp_page_evaluate.argtypes = [
            ctypes.c_uint64,
            _Slice,
            ctypes.POINTER(_EvaluateOptions),
            ctypes.POINTER(_EvaluateResult),
            ctypes.POINTER(_Error),
        ]
        d.dp_page_evaluate.restype = ctypes.c_int32
        d.dp_page_frames.argtypes = [
            ctypes.c_uint64,
            ctypes.POINTER(_Bytes),
            ctypes.POINTER(_Error),
        ]
        d.dp_page_frames.restype = ctypes.c_int32
        d.dp_page_network_observations.argtypes = [
            ctypes.c_uint64,
            ctypes.c_uint64,
            ctypes.POINTER(_Bytes),
            ctypes.POINTER(_Error),
        ]
        d.dp_page_network_observations.restype = ctypes.c_int32
        d.dp_page_click.argtypes = [
            ctypes.c_uint64,
            _Slice,
            ctypes.POINTER(_ClickOptions),
            ctypes.POINTER(_Error),
        ]
        d.dp_page_click.restype = ctypes.c_int32

    def checked(self, status: int, error: _Error) -> None:
        if status == Status.OK:
            return
        try:
            message = _read_bytes(error.message).decode("utf-8", "replace")
        finally:
            self.dll.dp_error_free(ctypes.byref(error))
        raise DarkPandaError(status, message)


def _default_library_path() -> Path:
    package_dir = Path(__file__).resolve().parent
    name = "darkpanda.dll" if os.name == "nt" else ("libdarkpanda.dylib" if os.name == "posix" and os.uname().sysname == "Darwin" else "libdarkpanda.so")
    packaged = package_dir / name
    if packaged.exists():
        return packaged
    # Source-tree developer layout: python/darkpanda/_native.py -> zig-out/bin.
    developer = package_dir.parents[1] / "zig-out" / "bin" / name
    if developer.exists():
        return developer
    raise FileNotFoundError(f"cannot find {name}; pass library_path explicitly")


def _resolve_wreq_transport_path(
    library_path: Path,
    requested_path: str | os.PathLike[str] | None,
) -> Path:
    if os.name == "nt":
        name = "wreq.dll"
    elif sys.platform == "darwin":
        name = "libwreq.dylib"
    else:
        name = "libwreq.so"

    if requested_path is None:
        candidate = library_path.with_name(name)
    else:
        candidate = Path(requested_path)
        if not candidate.is_absolute():
            raise ValueError("wreq library path must be absolute")
    resolved = candidate.resolve(strict=True)
    if not resolved.is_absolute():
        raise ValueError("wreq library path must be absolute")
    return resolved


def _resolve_canvas_backend_path(
    library_path: Path,
    requested_path: str | os.PathLike[str] | None,
) -> Path:
    if os.name == "nt":
        name = "darkpanda_canvas_backend.dll"
    elif sys.platform == "darwin":
        name = "libdarkpanda_canvas_backend.dylib"
    else:
        name = "libdarkpanda_canvas_backend.so"

    candidate = library_path.with_name(name) if requested_path is None else Path(requested_path)
    if not candidate.is_absolute():
        raise ValueError("Canvas backend library path must be absolute")
    resolved = candidate.resolve(strict=True)
    if not resolved.is_absolute():
        raise ValueError("Canvas backend library path must be absolute")
    return resolved


def _normalize_dns_nameservers(value: str | Sequence[str] | None) -> str:
    """Serialize explicit IP-literal resolver endpoints for the native ABI.

    Each item is either an IP literal (port 53) or an explicit socket address,
    for example ``1.1.1.1:5353`` or ``[2606:4700:4700::1111]:53``. Native
    preflight performs the authoritative syntax and IP-literal validation.
    """

    if value is None:
        return ""
    endpoints = [value] if isinstance(value, str) else list(value)
    normalized: list[str] = []
    for endpoint in endpoints:
        if not isinstance(endpoint, str):
            raise TypeError("dns_nameservers must contain only strings")
        item = endpoint.strip()
        if not item:
            raise ValueError("dns_nameservers cannot contain an empty endpoint")
        if any(character in item for character in ("\x00", "\r", "\n")):
            raise ValueError("dns_nameservers endpoints cannot contain NUL or newlines")
        normalized.append(item)
    if len(normalized) > 8:
        raise ValueError("dns_nameservers accepts at most 8 endpoints")
    return "\n".join(normalized)


@dataclass(frozen=True)
class Evaluation:
    value: str
    is_error: bool


@dataclass(frozen=True)
class FrameRect:
    x: float
    y: float
    width: float
    height: float


@dataclass(frozen=True)
class FrameInfo:
    frame_id: int
    parent_frame_id: int | None
    url: str
    name: str
    is_root: bool
    attached: bool
    visible: bool
    owner_rect: FrameRect | None
    child_count: int

    # Source-compatible aliases for the first unreleased draft of the API.
    @property
    def id(self) -> int:
        return self.frame_id

    @property
    def parent_id(self) -> int | None:
        return self.parent_frame_id

    @property
    def is_visible(self) -> bool:
        return self.visible


@dataclass(frozen=True)
class NetworkObservation:
    sequence: int
    request_id: int
    phase: str
    frame_id: int
    root_frame_id: int
    resource_type: str
    status: int | None
    monotonic_time_us: int
    host: str
    path_category: str
    initiator_context: str
    failure_kind: str | None = None


_NETWORK_FAILURE_KINDS = frozenset({
    "timeout",
    "dns",
    "connect",
    "tls",
    "http2",
    "cancelled",
    "transport",
})


def _parse_network_failure_kind(value: object) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or value not in _NETWORK_FAILURE_KINDS:
        raise RuntimeError("native network observation has an invalid failureKind")
    return value


@dataclass(frozen=True)
class NetworkObservationBatch:
    """A cursor batch from :meth:`Page.network_observations`.

    ``dropped_count`` is cumulative capacity eviction since Page creation.
    Supplying the previous ``latest_sequence`` acknowledges all records at or
    below it, allowing native bounded storage to discard them without a drop.
    """

    observations: tuple[NetworkObservation, ...]
    dropped_count: int
    latest_sequence: int


class Runtime:
    """One in-process DarkPanda runtime backed by a dedicated native thread."""

    def __init__(
        self,
        *,
        library_path: str | os.PathLike[str] | None = None,
        wreq_library_path: str | os.PathLike[str] | None = None,
        wreq_transport_path: str | os.PathLike[str] | None = None,
        canvas_library_path: str | os.PathLike[str] | None = None,
        canvas_driver: str = CanvasDriver.DYNAMIC,
        canvas_fallback: str = CanvasFallback.DISABLED,
        navigation_timeout_ms: int = 30_000,
        locale: str | None = None,
        timezone: str | None = None,
        profile: str = ClientProfile.CHROME149,
        fingerprint_profile_json: str | bytes | Mapping[str, Any] | None = None,
        dns_nameservers: str | Sequence[str] | None = None,
    ) -> None:
        dll_path = Path(library_path) if library_path is not None else _default_library_path()
        if wreq_library_path is not None and wreq_transport_path is not None:
            raise ValueError("pass only one of wreq_library_path and the legacy wreq_transport_path")
        wreq_path = _resolve_wreq_transport_path(
            dll_path,
            wreq_library_path if wreq_library_path is not None else wreq_transport_path,
        )
        try:
            canvas_driver_id = CanvasDriver._NATIVE_IDS[canvas_driver]
        except KeyError as exc:
            choices = ", ".join(sorted(CanvasDriver._NATIVE_IDS))
            raise ValueError(f"unknown Canvas driver {canvas_driver!r}; expected one of: {choices}") from exc
        try:
            canvas_fallback_id = CanvasFallback._NATIVE_IDS[canvas_fallback]
        except KeyError as exc:
            choices = ", ".join(sorted(CanvasFallback._NATIVE_IDS))
            raise ValueError(f"unknown Canvas fallback {canvas_fallback!r}; expected one of: {choices}") from exc
        if canvas_driver == CanvasDriver.DYNAMIC:
            canvas_path = _resolve_canvas_backend_path(dll_path, canvas_library_path)
        else:
            if canvas_library_path is not None:
                raise ValueError("canvas_library_path requires canvas_driver='dynamic'")
            if canvas_fallback != CanvasFallback.DISABLED:
                raise ValueError("canvas_fallback is only valid with canvas_driver='dynamic'")
            canvas_path = None
        self._library = _Library(dll_path)

        options = _RuntimeOptions()
        status = int(
            self._library.dll.dp_runtime_options_init_sized(
                ctypes.byref(options), ctypes.sizeof(options)
            )
        )
        if status != Status.OK:
            raise RuntimeError(f"failed to initialize RuntimeOptions: native status {status}")
        path_slice, path_storage = _owned_slice(str(wreq_path) if wreq_path is not None else "")
        options.wreq_transport_path = path_slice
        options.navigation_timeout_ms = int(navigation_timeout_ms)
        locale_slice, locale_storage = _owned_slice(locale or "")
        timezone_slice, timezone_storage = _owned_slice(timezone or "")
        options.application_locale = locale_slice
        options.timezone = timezone_slice
        try:
            options.client_profile = ClientProfile._NATIVE_IDS[profile]
        except KeyError as exc:
            choices = ", ".join(sorted(ClientProfile._NATIVE_IDS))
            raise ValueError(f"unknown client profile {profile!r}; expected one of: {choices}") from exc

        if isinstance(fingerprint_profile_json, Mapping):
            profile_json_value = json.dumps(
                fingerprint_profile_json,
                ensure_ascii=False,
                separators=(",", ":"),
            )
        elif isinstance(fingerprint_profile_json, bytes):
            profile_json_value = fingerprint_profile_json.decode("utf-8", "strict")
        elif isinstance(fingerprint_profile_json, str):
            profile_json_value = fingerprint_profile_json
        elif fingerprint_profile_json is None:
            profile_json_value = ""
        else:
            raise TypeError(
                "fingerprint_profile_json must be str, UTF-8 bytes, a mapping, or None"
            )
        profile_json_slice, profile_json_storage = _owned_slice(profile_json_value)
        options.fingerprint_profile_json = profile_json_slice
        dns_nameserver_value = _normalize_dns_nameservers(dns_nameservers)
        dns_field_end = _RuntimeOptions.wreq_dns_nameservers.offset + ctypes.sizeof(_Slice)
        if dns_nameserver_value and int(options.struct_size) < dns_field_end:
            raise RuntimeError("the loaded DarkPanda library does not support custom DNS")
        dns_nameserver_slice, dns_nameserver_storage = _owned_slice(dns_nameserver_value)
        options.wreq_dns_nameservers = dns_nameserver_slice
        canvas_field_end = _RuntimeOptions.canvas_fallback.offset + ctypes.sizeof(ctypes.c_uint32)
        if int(options.struct_size) < canvas_field_end:
            raise RuntimeError("the loaded DarkPanda library does not support Canvas backend selection")
        canvas_path_slice, canvas_path_storage = _owned_slice(
            str(canvas_path) if canvas_path is not None else ""
        )
        options.canvas_backend_path = canvas_path_slice
        options.canvas_driver = canvas_driver_id
        options.canvas_fallback = canvas_fallback_id
        self._handle = ctypes.c_uint64(0)
        error = _Error()
        status = self._library.dll.dp_runtime_create(ctypes.byref(options), ctypes.byref(self._handle), ctypes.byref(error))
        # Keep all borrowed UTF-8 buffers alive through the synchronous call;
        # the DLL deep-copies them before its worker starts.
        _ = (
            path_storage,
            locale_storage,
            timezone_storage,
            profile_json_storage,
            dns_nameserver_storage,
            canvas_path_storage,
        )
        self._library.checked(status, error)
        self._pages: weakref.WeakSet[Page] = weakref.WeakSet()
        self._finalizer = weakref.finalize(
            self, _finalize_runtime, self._library, int(self._handle.value)
        )
        self._finalizer.atexit = False

    @property
    def closed(self) -> bool:
        return self._handle.value == 0

    def new_page(self) -> "Page":
        if self.closed:
            raise DarkPandaError(Status.CLOSED, "runtime is closed")
        handle = ctypes.c_uint64(0)
        error = _Error()
        status = self._library.dll.dp_page_create(self._handle, ctypes.byref(handle), ctypes.byref(error))
        self._library.checked(status, error)
        page = Page(self, handle.value)
        self._pages.add(page)
        return page

    def identity_manifest(self) -> dict[str, Any]:
        """Return the resolved profile/runtime/transport consistency report.

        The transport section distinguishes fields wreq consumes directly
        from catalog fields DarkPanda validates before selecting its numeric
        emulation preset. TLS backend data is explicitly non-attested.
        """
        if self.closed:
            raise DarkPandaError(Status.CLOSED, "runtime is closed")
        output = _Bytes()
        error = _Error()
        status = self._library.dll.dp_runtime_identity_manifest(
            self._handle, ctypes.byref(output), ctypes.byref(error)
        )
        self._library.checked(status, error)
        try:
            return json.loads(_read_bytes(output).decode("utf-8", "strict"))
        finally:
            self._library.dll.dp_bytes_free(ctypes.byref(output))

    def close(self) -> None:
        if self.closed:
            return
        for page in list(self._pages):
            page.close()
        error = _Error()
        handle = self._handle
        status = self._library.dll.dp_runtime_destroy(handle, ctypes.byref(error))
        # A valid native destroy consumes the public handle before it resets
        # the persistent worker.  Reset can still report an error, so publish
        # the consumed state before checked() raises that diagnostic.
        self._handle = ctypes.c_uint64(0)
        self._finalizer.detach()
        self._library.checked(status, error)

    def __enter__(self) -> "Runtime":
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        self.close()


class Page:
    def __init__(self, runtime: Runtime, handle: int) -> None:
        self._runtime = runtime
        self._handle = ctypes.c_uint64(handle)
        self._finalizer = weakref.finalize(
            self, _finalize_page, runtime._library, int(handle)
        )
        self._finalizer.atexit = False

    @property
    def closed(self) -> bool:
        return self._handle.value == 0

    def navigate(self, url: str, *, timeout_ms: int = 0) -> None:
        self._require_open()
        options = _NavigationOptions()
        self._runtime._library.dll.dp_navigation_options_init(ctypes.byref(options))
        options.timeout_ms = int(timeout_ms)
        value, storage = _owned_slice(url)
        error = _Error()
        status = self._runtime._library.dll.dp_page_navigate(self._handle, value, ctypes.byref(options), ctypes.byref(error))
        _ = storage
        self._runtime._library.checked(status, error)

    def raw_evaluate(self, script: str, *, promise_timeout_ms: int = 0) -> Evaluation:
        self._require_open()
        options = _EvaluateOptions()
        self._runtime._library.dll.dp_evaluate_options_init(ctypes.byref(options))
        options.promise_timeout_ms = int(promise_timeout_ms)
        value, storage = _owned_slice(script)
        result = _EvaluateResult()
        error = _Error()
        status = self._runtime._library.dll.dp_page_evaluate(
            self._handle, value, ctypes.byref(options), ctypes.byref(result), ctypes.byref(error)
        )
        _ = storage
        self._runtime._library.checked(status, error)
        try:
            text = _read_bytes(result.value).decode("utf-8", "replace")
            return Evaluation(text, bool(result.is_error))
        finally:
            self._runtime._library.dll.dp_evaluate_result_free(ctypes.byref(result))

    def evaluate(self, script: str, *, promise_timeout_ms: int = 0) -> str:
        result = self.raw_evaluate(script, promise_timeout_ms=promise_timeout_ms)
        if result.is_error:
            raise JavaScriptError(Status.EVALUATION_FAILED, result.value)
        return result.value

    def frames(
        self,
        *,
        visible: bool | None = None,
        attached: bool | None = None,
    ) -> list[FrameInfo]:
        """Return a stable snapshot of root/child frames.

        ``visible=True`` is the generic way to exclude hidden retry/challenge
        frames without relying on a URL, site key, or DOM implementation detail.
        """
        self._require_open()
        if visible is not None and not isinstance(visible, bool):
            raise TypeError("visible must be bool or None")
        if attached is not None and not isinstance(attached, bool):
            raise TypeError("attached must be bool or None")
        output = _Bytes()
        error = _Error()
        status = self._runtime._library.dll.dp_page_frames(
            self._handle, ctypes.byref(output), ctypes.byref(error)
        )
        self._runtime._library.checked(status, error)
        try:
            raw_frames = json.loads(_read_bytes(output).decode("utf-8"))
        finally:
            self._runtime._library.dll.dp_bytes_free(ctypes.byref(output))
        if not isinstance(raw_frames, list):
            raise RuntimeError("native frame report is not a JSON array")

        result: list[FrameInfo] = []
        for raw in raw_frames:
            if not isinstance(raw, dict):
                raise RuntimeError("native frame report contains a non-object entry")
            raw_rect = raw.get("ownerRect")
            rect = None if raw_rect is None else FrameRect(
                x=float(raw_rect["x"]),
                y=float(raw_rect["y"]),
                width=float(raw_rect["width"]),
                height=float(raw_rect["height"]),
            )
            info = FrameInfo(
                frame_id=int(raw.get("frameId", raw.get("id"))),
                parent_frame_id=(
                    None
                    if raw.get("parentFrameId", raw.get("parentId")) is None
                    else int(raw.get("parentFrameId", raw.get("parentId")))
                ),
                url=str(raw.get("url", "")),
                name=str(raw.get("name", "")),
                is_root=bool(raw.get("isRoot", False)),
                attached=bool(raw.get("attached", True)),
                visible=bool(raw.get("visible", raw.get("isVisible", False))),
                owner_rect=rect,
                child_count=int(raw.get("childCount", 0)),
            )
            if visible is not None and info.visible is not visible:
                continue
            if attached is not None and info.attached is not attached:
                continue
            result.append(info)
        return result

    def network_observations(
        self,
        *,
        since_sequence: int = 0,
    ) -> NetworkObservationBatch:
        """Return query-free network metadata across this Page's frame tree.

        Dedicated Worker traffic is included and marked with
        ``initiator_context == "worker"``. Bodies, headers, cookies, query
        strings, fragments, opaque URL payloads and raw transport diagnostics
        are never collected. ``failure_kind`` is one of seven coarse categories
        for failed requests and ``None`` for successful lifecycle phases.
        """
        self._require_open()
        if (
            not isinstance(since_sequence, int)
            or isinstance(since_sequence, bool)
            or not 0 <= since_sequence <= 0xFFFFFFFFFFFFFFFF
        ):
            raise ValueError("since_sequence must be an unsigned 64-bit integer")

        output = _Bytes()
        error = _Error()
        status = self._runtime._library.dll.dp_page_network_observations(
            self._handle,
            ctypes.c_uint64(since_sequence),
            ctypes.byref(output),
            ctypes.byref(error),
        )
        self._runtime._library.checked(status, error)
        try:
            raw = json.loads(_read_bytes(output).decode("utf-8", "strict"))
        finally:
            self._runtime._library.dll.dp_bytes_free(ctypes.byref(output))
        if not isinstance(raw, dict) or not isinstance(raw.get("observations"), list):
            raise RuntimeError("native network observation report has an invalid shape")

        observations: list[NetworkObservation] = []
        for item in raw["observations"]:
            if not isinstance(item, dict):
                raise RuntimeError("native network observation report contains a non-object entry")
            raw_status = item.get("status")
            observations.append(NetworkObservation(
                sequence=int(item["sequence"]),
                request_id=int(item["requestId"]),
                phase=str(item["phase"]),
                frame_id=int(item["frameId"]),
                root_frame_id=int(item["rootFrameId"]),
                resource_type=str(item["resourceType"]),
                status=None if raw_status is None else int(raw_status),
                monotonic_time_us=int(item["monotonicTimeUs"]),
                host=str(item["host"]),
                path_category=str(item["pathCategory"]),
                initiator_context=str(item["initiatorContext"]),
                failure_kind=_parse_network_failure_kind(item.get("failureKind")),
            ))
        return NetworkObservationBatch(
            observations=tuple(observations),
            dropped_count=int(raw.get("droppedCount", 0)),
            latest_sequence=int(raw.get("latestSequence", 0)),
        )

    def click(
        self,
        selector: str,
        frame_id: int | None = None,
        pierce: bool = False,
        timeout_ms: int = 0,
        move_delay_ms: int = 16,
        press_delay_ms: int = 60,
    ) -> None:
        """Click via browser-owned trusted hover, press and release tasks."""
        self._require_open()
        for field, value in (
            ("frame_id", 0 if frame_id is None else frame_id),
            ("timeout_ms", timeout_ms),
            ("move_delay_ms", move_delay_ms),
            ("press_delay_ms", press_delay_ms),
        ):
            if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 0xFFFFFFFF:
                raise ValueError(f"{field} must be an unsigned 32-bit integer")
        if move_delay_ms > 60_000 or press_delay_ms > 60_000:
            raise ValueError("phase delays must not exceed 60000 ms")
        if not isinstance(pierce, bool):
            raise TypeError("pierce must be bool")

        options = _ClickOptions()
        self._runtime._library.dll.dp_click_options_init(ctypes.byref(options))
        options.frame_id = 0 if frame_id is None else frame_id
        options.timeout_ms = timeout_ms
        options.pierce_shadow = int(pierce)
        options.move_delay_ms = move_delay_ms
        options.press_delay_ms = press_delay_ms
        value, storage = _owned_slice(selector)
        error = _Error()
        status = self._runtime._library.dll.dp_page_click(
            self._handle, value, ctypes.byref(options), ctypes.byref(error)
        )
        _ = storage
        self._runtime._library.checked(status, error)

    def cancel(self) -> None:
        self._require_open()
        status = int(self._runtime._library.dll.dp_page_cancel(self._handle))
        if status != Status.OK:
            raise DarkPandaError(status, "page cancellation failed")

    def close(self) -> None:
        if self.closed:
            return
        error = _Error()
        handle = self._handle
        status = self._runtime._library.dll.dp_page_close(handle, ctypes.byref(error))
        # dp_page_close unregisters a valid handle before worker-side cleanup.
        # Keep Python's state consumed even if that cleanup reports an error.
        self._handle = ctypes.c_uint64(0)
        self._finalizer.detach()
        self._runtime._pages.discard(self)
        self._runtime._library.checked(status, error)

    def _require_open(self) -> None:
        if self.closed or self._runtime.closed:
            raise DarkPandaError(Status.CLOSED, "page is closed")

    def __enter__(self) -> "Page":
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        self.close()
