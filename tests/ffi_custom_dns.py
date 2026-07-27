"""Exercise the native Windows custom-DNS path without external network I/O."""

from __future__ import annotations

import argparse
import contextlib
import http.server
import json
import os
import socket
import socketserver
import struct
import threading
from collections.abc import Iterator
from typing import cast

from darkpanda import ClientProfile, Runtime


FIXTURE_TEXT = "custom DNS IPv6 fixture"
FIXTURE_MARKER = "resolved-via-custom-aaaa"


def _ipv6_loopback_available() -> bool:
    if not socket.has_ipv6:
        return False
    probe = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    try:
        probe.bind(("::1", 0))
    except OSError:
        return False
    finally:
        probe.close()
    return True


def _decode_question(packet: bytes) -> tuple[str, int, int, int] | None:
    """Return (lower-case name, type, class, question-end) for one DNS question."""
    if len(packet) < 17 or struct.unpack_from("!H", packet, 4)[0] != 1:
        return None

    labels: list[str] = []
    offset = 12
    while offset < len(packet):
        label_length = packet[offset]
        offset += 1
        if label_length == 0:
            break
        # DNS clients do not normally compress QNAME. Keeping the fixture
        # deliberately minimal also makes malformed/compressed input fail shut.
        if label_length & 0xC0 or offset + label_length > len(packet):
            return None
        try:
            labels.append(packet[offset : offset + label_length].decode("ascii"))
        except UnicodeDecodeError:
            return None
        offset += label_length
    else:
        return None

    if offset + 4 > len(packet):
        return None
    query_type, query_class = struct.unpack_from("!HH", packet, offset)
    return ".".join(labels).lower(), query_type, query_class, offset + 4


class _DnsFixtureState:
    def __init__(self, hostname: str) -> None:
        self.hostname = hostname.rstrip(".").lower()
        self._queries: list[tuple[str, int]] = []
        self._lock = threading.Lock()

    def record(self, hostname: str, query_type: int) -> None:
        with self._lock:
            self._queries.append((hostname, query_type))

    def query_types(self) -> list[int]:
        with self._lock:
            return [
                query_type
                for hostname, query_type in self._queries
                if hostname == self.hostname
            ]


class _DnsFixtureServer(socketserver.ThreadingUDPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(
        self,
        server_address: tuple[str, int],
        state: _DnsFixtureState,
    ) -> None:
        self.state = state
        super().__init__(server_address, _DnsFixtureHandler)


class _DnsFixtureHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        packet, response_socket = cast(tuple[bytes, socket.socket], self.request)
        question = _decode_question(packet)
        if question is None:
            return

        hostname, query_type, query_class, question_end = question
        server = cast(_DnsFixtureServer, self.server)
        server.state.record(hostname, query_type)

        exact_name = hostname == server.state.hostname
        internet_class = query_class == 1
        answer_aaaa = exact_name and internet_class and query_type == 28
        rcode = 0 if exact_name else 3  # NOERROR for the fixture, NXDOMAIN otherwise.

        query_flags = struct.unpack_from("!H", packet, 2)[0]
        # Preserve opcode and recursion-desired; mark this tiny fixture as a
        # recursive response so ordinary stub resolvers accept it.
        response_flags = 0x8000 | (query_flags & 0x7900) | 0x0080 | rcode
        header = struct.pack(
            "!HHHHHH",
            struct.unpack_from("!H", packet, 0)[0],
            response_flags,
            1,
            1 if answer_aaaa else 0,
            0,
            0,
        )
        response = header + packet[12:question_end]
        if answer_aaaa:
            response += (
                b"\xc0\x0c"  # NAME: pointer to QNAME
                + struct.pack("!HHIH", 28, 1, 30, 16)
                + socket.inet_pton(socket.AF_INET6, "::1")
            )
        response_socket.sendto(response, self.client_address)


@contextlib.contextmanager
def _dns_fixture(hostname: str) -> Iterator[tuple[str, _DnsFixtureState]]:
    state = _DnsFixtureState(hostname)
    server = _DnsFixtureServer(("127.0.0.1", 0), state)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address[:2]
        yield f"{host}:{port}", state
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


class _IPv6HttpServer(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True


class _FixtureHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        body = (
            "<!doctype html><meta charset=utf-8>"
            "<title>custom-dns-ipv6</title>"
            f"<main id=fixture>{FIXTURE_TEXT}</main>"
            f"<script>globalThis.__darkpandaCustomDns={json.dumps(FIXTURE_MARKER)};</script>"
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        del format, args


@contextlib.contextmanager
def _ipv6_http_fixture() -> Iterator[int]:
    server = _IPv6HttpServer(("::1", 0), _FixtureHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield int(server.server_address[1])
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq", required=True)
    args = parser.parse_args()

    if os.name != "nt":
        print("SKIP ffi_custom_dns.py is a Windows wreq integration test")
        return
    if not _ipv6_loopback_available():
        print("SKIP IPv6 loopback is unavailable on this Windows host")
        return

    hostname = f"darkpanda-custom-dns-{os.getpid()}.test"
    with _ipv6_http_fixture() as http_port, _dns_fixture(hostname) as (
        dns_nameserver,
        dns_state,
    ):
        with Runtime(
            library_path=args.library,
            wreq_library_path=args.wreq,
            dns_nameservers=[dns_nameserver],
            navigation_timeout_ms=15_000,
            locale="en-US",
            timezone="UTC",
            profile=ClientProfile.CHROME149,
        ) as runtime:
            with runtime.new_page() as page:
                page.navigate(f"http://{hostname}:{http_port}/fixture", timeout_ms=15_000)
                snapshot = json.loads(
                    page.evaluate(
                        """JSON.stringify({
                            hostname: location.hostname,
                            port: location.port,
                            title: document.title,
                            text: document.querySelector('#fixture')?.textContent || '',
                            marker: globalThis.__darkpandaCustomDns || ''
                        })"""
                    )
                )

        assert snapshot == {
            "hostname": hostname,
            "port": str(http_port),
            "title": "custom-dns-ipv6",
            "text": FIXTURE_TEXT,
            "marker": FIXTURE_MARKER,
        }, snapshot
        query_types = dns_state.query_types()
        assert 28 in query_types, (
            "custom resolver never issued the required AAAA query; "
            f"observed DNS types: {query_types}"
        )
        assert any(query_type in (1, 28) for query_type in query_types), query_types

    observed = ["A" if value == 1 else "AAAA" for value in query_types if value in (1, 28)]
    print(
        "PASS custom DNS nameserver resolved an IPv6-only local origin "
        f"(queries={observed})"
    )


if __name__ == "__main__":
    main()
