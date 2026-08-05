from __future__ import annotations

import hashlib
import ntpath
import tempfile
import unittest
import urllib.error
import urllib.request
from email.message import Message
from pathlib import Path
from unittest import mock

from tools.ci.materialize_skia_cpu_deps import open_url_with_retry, tree_digest
from tools.ci.verify_chromium_toolchain import tree_digest as verify_tree_digest


class MaterializeSkiaCpuDepsTest(unittest.TestCase):
    def test_open_url_retries_transient_http_errors(self) -> None:
        request = urllib.request.Request("https://example.test/archive.tar.gz")
        response = object()
        error = urllib.error.HTTPError(
            request.full_url,
            503,
            "Service Unavailable",
            Message(),
            None,
        )
        delays: list[float] = []
        with mock.patch(
            "tools.ci.materialize_skia_cpu_deps.urllib.request.urlopen",
            side_effect=[error, response],
        ) as urlopen:
            observed = open_url_with_retry(
                request,
                max_attempts=2,
                initial_backoff_seconds=0.25,
                sleep=delays.append,
            )

        self.assertIs(observed, response)
        self.assertEqual(urlopen.call_count, 2)
        self.assertEqual(delays, [0.25])

    def test_open_url_does_not_retry_permanent_http_errors(self) -> None:
        request = urllib.request.Request("https://example.test/missing")
        error = urllib.error.HTTPError(
            request.full_url,
            404,
            "Not Found",
            Message(),
            None,
        )
        delays: list[float] = []
        with mock.patch(
            "tools.ci.materialize_skia_cpu_deps.urllib.request.urlopen",
            side_effect=error,
        ) as urlopen, self.assertRaises(urllib.error.HTTPError):
            open_url_with_retry(request, sleep=delays.append)

        urlopen.assert_called_once_with(request, timeout=120)
        self.assertEqual(delays, [])

    def test_open_url_stops_after_bounded_transport_retries(self) -> None:
        request = urllib.request.Request("https://example.test/archive.tar.gz")
        errors = [urllib.error.URLError("offline") for _ in range(3)]
        delays: list[float] = []
        with mock.patch(
            "tools.ci.materialize_skia_cpu_deps.urllib.request.urlopen",
            side_effect=errors,
        ) as urlopen, self.assertRaises(urllib.error.URLError):
            open_url_with_retry(
                request,
                max_attempts=3,
                initial_backoff_seconds=1,
                sleep=delays.append,
            )

        self.assertEqual(urlopen.call_count, 3)
        self.assertEqual(delays, [1, 2])

    def test_tree_digest_uses_platform_independent_casefolded_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = {
                "BUILD.gn": b"build",
                "arm0.c": b"root",
                "arm/arm_init.c": b"arm",
                "README.chromium": b"readme",
            }
            for relative, content in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)

            expected = hashlib.sha256()
            expected_order = [
                "arm0.c",
                "arm/arm_init.c",
                "BUILD.gn",
                "README.chromium",
            ]
            self.assertEqual(
                expected_order,
                sorted(files, key=lambda value: (ntpath.normcase(value), value)),
            )
            for relative in expected_order:
                encoded = relative.encode("utf-8")
                expected.update(len(encoded).to_bytes(8, "big"))
                expected.update(encoded)
                expected.update(hashlib.sha256(files[relative]).digest())

            expected_digest = (expected.hexdigest(), len(files))
            self.assertEqual(tree_digest(root), expected_digest)
            self.assertEqual(verify_tree_digest(root), expected_digest)


if __name__ == "__main__":
    unittest.main()
