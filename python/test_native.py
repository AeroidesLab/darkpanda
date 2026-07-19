"""Pure-Python binding tests; these do not load darkpanda.dll."""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest
from unittest import mock

from darkpanda import _native


class TransportPathTests(unittest.TestCase):
    def test_platform_default_is_adjacent_to_darkpanda_library(self) -> None:
        cases = (("nt", "win32", "wreq.dll"), ("posix", "linux", "libwreq.so"), ("posix", "darwin", "libwreq.dylib"))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = root / "darkpanda-placeholder"
            library.touch()
            for os_name, platform, wreq_name in cases:
                with self.subTest(platform=platform):
                    expected = root / wreq_name
                    expected.touch()
                    with mock.patch.object(_native.os, "name", os_name), mock.patch.object(_native.sys, "platform", platform):
                        self.assertEqual(
                            _native._resolve_wreq_transport_path(library, None),
                            expected.resolve(),
                        )
                    expected.unlink()

    def test_explicit_absolute_wreq_path_is_cross_platform(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = root / "libdarkpanda.so"
            wreq = root / "custom-libwreq.so"
            library.touch()
            wreq.touch()
            self.assertEqual(
                _native._resolve_wreq_transport_path(library, wreq),
                wreq.resolve(),
            )

    def test_explicit_relative_wreq_path_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "must be absolute"):
            _native._resolve_wreq_transport_path(Path("libdarkpanda.so"), "libwreq.so")


class DnsNameserverTests(unittest.TestCase):
    def test_single_endpoint_and_sequence_are_serialized(self) -> None:
        self.assertEqual(
            _native._normalize_dns_nameservers("2606:4700:4700::1111"),
            "2606:4700:4700::1111",
        )
        self.assertEqual(
            _native._normalize_dns_nameservers(["1.1.1.1", "[::1]:5353"]),
            "1.1.1.1\n[::1]:5353",
        )

    def test_empty_or_injected_endpoint_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            _native._normalize_dns_nameservers([""])
        with self.assertRaises(ValueError):
            _native._normalize_dns_nameservers(["1.1.1.1\n8.8.8.8"])

    def test_at_most_eight_endpoints_are_accepted(self) -> None:
        with self.assertRaises(ValueError):
            _native._normalize_dns_nameservers([f"192.0.2.{index}" for index in range(1, 10)])


class NetworkFailureKindTests(unittest.TestCase):
    def test_null_and_whitelisted_categories_are_accepted(self) -> None:
        self.assertIsNone(_native._parse_network_failure_kind(None))
        for value in (
            "timeout",
            "dns",
            "connect",
            "tls",
            "http2",
            "cancelled",
            "transport",
        ):
            self.assertEqual(_native._parse_network_failure_kind(value), value)

    def test_backend_error_names_and_unknown_values_are_rejected(self) -> None:
        for value in ("CouldntResolveHost", "raw backend detail", 1):
            with self.subTest(value=value):
                with self.assertRaisesRegex(RuntimeError, "invalid failureKind"):
                    _native._parse_network_failure_kind(value)


if __name__ == "__main__":
    unittest.main()
