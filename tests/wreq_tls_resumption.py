"""Deterministic local Chrome149 trust_anchors + TLS 1.3 PSK test.

The fixture keeps one wreq transport/client alive while a local TLS server
closes each HTTP/1.1 connection.  This forces two TCP/TLS handshakes without
discarding wreq's session cache.  The server peeks at both ClientHellos before
letting OpenSSL complete the handshakes and issue/redeem a session ticket.
"""

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import ipaddress
import json
import socket
import ssl
import tempfile
import threading
import time
from pathlib import Path
from typing import Any

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


ABI_VERSION = 5
TRANSPORT_OK = 0
TRANSPORT_EMPTY = 1
INSECURE_SKIP_TLS_VERIFY = 1 << 0
PROFILE_CHROME149 = 149
EVENT_HEADERS = 1
EVENT_DATA = 2
EVENT_DONE = 3
EVENT_ERROR = 4
EVENT_CANCELLED = 5
TRUST_ANCHORS_EXTENSION = 0xCA34
PRE_SHARED_KEY_EXTENSION = 41


class WreqSlice(ctypes.Structure):
    _fields_ = [("ptr", ctypes.POINTER(ctypes.c_uint8)), ("len", ctypes.c_size_t)]


class WreqHeader(ctypes.Structure):
    _fields_ = [("name", WreqSlice), ("value", WreqSlice)]


class WreqTransportOptions(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("flags", ctypes.c_uint64),
        ("proxy_url", WreqSlice),
        ("event_capacity", ctypes.c_uint32),
        ("profile_id", ctypes.c_uint32),
        ("reserved32", ctypes.c_uint32),
        ("dns_nameservers", WreqSlice),
    ]


class WreqRequest(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("method", WreqSlice),
        ("url", WreqSlice),
        ("headers", ctypes.POINTER(WreqHeader)),
        ("header_count", ctypes.c_size_t),
        ("body", WreqSlice),
        ("timeout_ms", ctypes.c_uint64),
        ("flags", ctypes.c_uint64),
        ("proxy_url", WreqSlice),
    ]


class WreqEvent(ctypes.Structure):
    _fields_ = [
        ("kind", ctypes.c_uint32),
        ("http_version", ctypes.c_uint32),
        ("request_id", ctypes.c_uint64),
        ("status_code", ctypes.c_uint16),
        ("reserved16", ctypes.c_uint16),
        ("reserved32", ctypes.c_uint32),
        ("encoded_body_size", ctypes.c_uint64),
        ("decoded_body_size", ctypes.c_uint64),
        ("headers", ctypes.POINTER(WreqHeader)),
        ("header_count", ctypes.c_size_t),
        ("data", WreqSlice),
    ]


def empty_slice() -> WreqSlice:
    return WreqSlice(None, 0)


def byte_slice(value: bytes) -> tuple[WreqSlice, Any]:
    storage = (ctypes.c_uint8 * len(value)).from_buffer_copy(value)
    view = WreqSlice(
        ctypes.cast(storage, ctypes.POINTER(ctypes.c_uint8)), len(value)
    )
    return view, storage


def configure_library(path: Path) -> ctypes.CDLL:
    library = ctypes.CDLL(str(path.resolve()))
    library.wreq_transport_create_with_options.argtypes = [
        ctypes.POINTER(WreqTransportOptions),
        ctypes.POINTER(ctypes.c_void_p),
    ]
    library.wreq_transport_create_with_options.restype = ctypes.c_int32
    library.wreq_transport_submit.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(WreqRequest),
        ctypes.POINTER(ctypes.c_uint64),
    ]
    library.wreq_transport_submit.restype = ctypes.c_int32
    library.wreq_transport_poll_event.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.POINTER(ctypes.POINTER(WreqEvent)),
    ]
    library.wreq_transport_poll_event.restype = ctypes.c_int32
    library.wreq_transport_headers_ack.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
    library.wreq_transport_headers_ack.restype = ctypes.c_int32
    library.wreq_transport_event_free.argtypes = [ctypes.POINTER(WreqEvent)]
    library.wreq_transport_event_free.restype = None
    library.wreq_transport_free.argtypes = [ctypes.c_void_p]
    library.wreq_transport_free.restype = None
    return library


def make_certificate(directory: Path) -> tuple[Path, Path]:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "127.0.0.1")])
    now = dt.datetime.now(dt.timezone.utc)
    certificate = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(minutes=1))
        .not_valid_after(now + dt.timedelta(days=1))
        .add_extension(
            x509.SubjectAlternativeName(
                [x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]
            ),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )
    certificate_path = directory / "server-cert.pem"
    key_path = directory / "server-key.pem"
    certificate_path.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    return certificate_path, key_path


def peek_tls_record(sock: socket.socket) -> bytes:
    deadline = time.monotonic() + 5.0
    expected = 5
    while time.monotonic() < deadline:
        data = sock.recv(expected, socket.MSG_PEEK)
        if len(data) >= 5:
            expected = 5 + int.from_bytes(data[3:5], "big")
            if len(data) >= expected:
                return data[:expected]
        time.sleep(0.005)
    raise TimeoutError(
        f"incomplete ClientHello: received={len(data)} expected={expected}"
    )


def read_http_request(sock: ssl.SSLSocket) -> None:
    request = bytearray()
    while b"\r\n\r\n" not in request:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("client closed before sending HTTP headers")
        request.extend(chunk)


def serve_two_connections(
    listener: socket.socket,
    context: ssl.SSLContext,
    client_hellos: list[bytes],
    reused: list[bool],
    errors: list[BaseException],
) -> None:
    # pip may globally inject truststore and wrap ssl.SSLContext. Its wrapper
    # verifies peer certificates even for server-side sockets on macOS. The
    # local fixture needs the configured stdlib context, which truststore keeps
    # in _ctx; ordinary Python environments use the context unchanged.
    server_context = getattr(context, "_ctx", context)
    try:
        for _ in range(2):
            raw, _ = listener.accept()
            raw.settimeout(5.0)
            client_hellos.append(peek_tls_record(raw))
            with server_context.wrap_socket(raw, server_side=True) as secured:
                reused.append(secured.session_reused)
                read_http_request(secured)
                secured.sendall(
                    b"HTTP/1.1 200 OK\r\n"
                    b"Content-Length: 2\r\n"
                    b"Connection: close\r\n"
                    b"\r\n"
                    b"ok"
                )
    except BaseException as error:  # surfaced on the main test thread
        errors.append(error)
    finally:
        listener.close()


def parse_client_hello_extensions(record: bytes) -> list[tuple[int, bytes]]:
    assert record[0] == 22, record[:5].hex()
    payload = record[5 : 5 + int.from_bytes(record[3:5], "big")]
    assert payload[0] == 1, payload[:4].hex()
    hello = payload[4 : 4 + int.from_bytes(payload[1:4], "big")]
    offset = 2 + 32
    session_id_length = hello[offset]
    offset += 1 + session_id_length
    cipher_length = int.from_bytes(hello[offset : offset + 2], "big")
    offset += 2 + cipher_length
    compression_length = hello[offset]
    offset += 1 + compression_length
    extensions_length = int.from_bytes(hello[offset : offset + 2], "big")
    offset += 2
    end = offset + extensions_length
    extensions: list[tuple[int, bytes]] = []
    while offset < end:
        extension_type = int.from_bytes(hello[offset : offset + 2], "big")
        extension_length = int.from_bytes(hello[offset + 2 : offset + 4], "big")
        offset += 4
        extensions.append(
            (extension_type, hello[offset : offset + extension_length])
        )
        offset += extension_length
    assert offset == end
    return extensions


def extension_payload(
    extensions: list[tuple[int, bytes]], extension_type: int
) -> bytes | None:
    """Return the first payload for an extension type."""

    return next(
        (payload for number, payload in extensions if number == extension_type),
        None,
    )


def ordered_extension_types(extensions: list[tuple[int, bytes]]) -> list[int | str]:
    """Preserve extension positions while normalizing GREASE values."""

    return ["GREASE" if is_grease(number) else number for number, _ in extensions]


def is_grease(value: int) -> bool:
    high, low = divmod(value, 0x100)
    return high == low and low & 0x0F == 0x0A


def send_request(library: ctypes.CDLL, transport: ctypes.c_void_p, url: str) -> None:
    method, method_storage = byte_slice(b"GET")
    url_view, url_storage = byte_slice(url.encode("ascii"))
    request = WreqRequest(
        ctypes.sizeof(WreqRequest),
        ABI_VERSION,
        method,
        url_view,
        None,
        0,
        empty_slice(),
        5_000,
        0,
        empty_slice(),
    )
    request_id = ctypes.c_uint64()
    status = library.wreq_transport_submit(
        transport, ctypes.byref(request), ctypes.byref(request_id)
    )
    assert status == TRANSPORT_OK, status
    del method_storage, url_storage

    while True:
        event = ctypes.POINTER(WreqEvent)()
        status = library.wreq_transport_poll_event(
            transport, 5_000, ctypes.byref(event)
        )
        if status == TRANSPORT_EMPTY:
            continue
        assert status == TRANSPORT_OK and bool(event), status
        try:
            assert event.contents.request_id == request_id.value
            kind = event.contents.kind
            if kind == EVENT_HEADERS:
                assert event.contents.status_code == 200
                assert (
                    library.wreq_transport_headers_ack(transport, request_id.value)
                    == TRANSPORT_OK
                )
            elif kind == EVENT_DATA:
                pass
            elif kind == EVENT_DONE:
                return
            elif kind == EVENT_ERROR:
                data = event.contents.data
                message = ctypes.string_at(data.ptr, data.len).decode(
                    "utf-8", "replace"
                )
                raise AssertionError(f"wreq request failed: {message}")
            elif kind == EVENT_CANCELLED:
                raise AssertionError("wreq request was cancelled")
            else:
                raise AssertionError(f"unexpected event kind {kind}")
        finally:
            library.wreq_transport_event_free(event)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--wreq", required=True, type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    assert ctypes.sizeof(WreqTransportOptions) == 64
    assert ctypes.sizeof(WreqRequest) == 104
    assert ctypes.sizeof(WreqEvent) == 72

    with tempfile.TemporaryDirectory(prefix="darkpanda-wreq-tls-") as temporary:
        certificate_path, key_path = make_certificate(Path(temporary))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_3
        context.maximum_version = ssl.TLSVersion.TLSv1_3
        context.load_cert_chain(certificate_path, key_path)
        context.set_alpn_protocols(["http/1.1"])
        context.num_tickets = 2

        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(2)
        port = listener.getsockname()[1]

        client_hellos: list[bytes] = []
        reused: list[bool] = []
        server_errors: list[BaseException] = []
        server = threading.Thread(
            target=serve_two_connections,
            args=(listener, context, client_hellos, reused, server_errors),
            daemon=True,
        )
        server.start()

        library = configure_library(args.wreq)
        options = WreqTransportOptions(
            ctypes.sizeof(WreqTransportOptions),
            ABI_VERSION,
            INSECURE_SKIP_TLS_VERIFY,
            empty_slice(),
            32,
            PROFILE_CHROME149,
            0,
            empty_slice(),
        )
        transport = ctypes.c_void_p()
        status = library.wreq_transport_create_with_options(
            ctypes.byref(options), ctypes.byref(transport)
        )
        assert status == TRANSPORT_OK and transport.value, status
        request_error: BaseException | None = None
        try:
            url = f"https://127.0.0.1:{port}/session"
            send_request(library, transport, url)
            send_request(library, transport, url)
        except BaseException as error:
            request_error = error
        finally:
            library.wreq_transport_free(transport)

        server.join(timeout=10.0)
        assert not server.is_alive(), "local TLS server did not finish"
        if server_errors:
            raise server_errors[0]
        if request_error is not None:
            raise request_error
        assert len(client_hellos) == 2, len(client_hellos)
        assert reused == [False, True], reused

        cold = parse_client_hello_extensions(client_hellos[0])
        resumed = parse_client_hello_extensions(client_hellos[1])
        cold_trust_anchors = extension_payload(cold, TRUST_ANCHORS_EXTENSION)
        resumed_trust_anchors = extension_payload(resumed, TRUST_ANCHORS_EXTENSION)
        cold_types = ordered_extension_types(cold)
        resumed_types = ordered_extension_types(resumed)
        assert cold_trust_anchors == b"\x00\x00", cold
        assert resumed_trust_anchors == b"\x00\x00", resumed
        assert PRE_SHARED_KEY_EXTENSION not in cold_types, cold_types
        assert PRE_SHARED_KEY_EXTENSION in resumed_types, resumed_types

        evidence = {
            "serverSessionReused": reused,
            "cold": {
                "orderedExtensions": cold_types,
                "trustAnchorsData": cold_trust_anchors.hex(),
                "preSharedKey": PRE_SHARED_KEY_EXTENSION in cold_types,
            },
            "resumed": {
                "orderedExtensions": resumed_types,
                "trustAnchorsData": resumed_trust_anchors.hex(),
                "preSharedKey": PRE_SHARED_KEY_EXTENSION in resumed_types,
            },
        }
        if args.out is not None:
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
        print(json.dumps(evidence, separators=(",", ":")))
        print("wreq Chrome149 local TLS trust_anchors + PSK resumption: PASS")


if __name__ == "__main__":
    main()
