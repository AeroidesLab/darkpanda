"""Focused strict-profile, shared HTTP identity, and manifest regression."""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import threading

from darkpanda import ClientProfile, DarkPandaError, Runtime


EXPECTED_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/149.0.0.0 Safari/537.36"
)
EXPECTED_CH = (
    '"Google Chrome";v="149", "Chromium";v="149", '
    '"Not)A;Brand";v="24"'
)


class CaptureServer(ThreadingHTTPServer):
    observed: threading.Event
    request_headers: tuple[tuple[str, str], ...] | None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = ""
    sys_version = ""

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def do_GET(self) -> None:  # noqa: N802
        server = self.server
        assert isinstance(server, CaptureServer)
        server.request_headers = tuple(self.headers.raw_items())
        server.observed.set()
        body = b"<!doctype html><meta charset=utf-8><title>profile fixture</title>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)


def one(headers: tuple[tuple[str, str], ...], name: str) -> str:
    values = [value for key, value in headers if key.lower() == name.lower()]
    assert len(values) == 1, (name, values, headers)
    return values[0]


def runtime_kwargs(args: argparse.Namespace) -> dict[str, object]:
    kwargs: dict[str, object] = {
        "library_path": args.library,
        "profile": ClientProfile.CHROME149,
    }
    if os.name == "nt":
        kwargs["wreq_transport_path"] = args.wreq
    return kwargs


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", required=True)
    parser.add_argument("--wreq")
    parser.add_argument(
        "--profile-json",
        default=str(Path(__file__).with_name("fixtures") / "chrome149_profile_fr.json"),
    )
    args = parser.parse_args()
    if os.name == "nt" and not args.wreq:
        parser.error("--wreq is required on Windows")
    if os.name != "nt" and args.wreq is not None:
        parser.error("--wreq is Windows-only")

    profile = json.loads(Path(args.profile_json).read_text(encoding="utf-8"))

    # A rejected schema must leave both the logical registry and physical V8
    # startup untouched, so the corrected profile succeeds in this process.
    invalid = dict(profile)
    invalid["unknownField"] = True
    try:
        Runtime(**runtime_kwargs(args), fingerprint_profile_json=invalid)
    except DarkPandaError as error:
        assert error.status == 1, error
        assert "UnknownField" in str(error), error
    else:
        raise AssertionError("unknown strict-profile field was accepted")

    server = CaptureServer(("127.0.0.1", 0), Handler)
    server.observed = threading.Event()
    server.request_headers = None
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address

    try:
        with Runtime(
            **runtime_kwargs(args),
            fingerprint_profile_json=profile,
        ) as runtime:
            manifest = runtime.identity_manifest()
            assert manifest["reportSchemaVersion"] == 2
            assert manifest["profile"]["schemaVersion"] == 2
            with runtime.new_page() as page:
                page.navigate(f"http://{host}:{port}/")
                visible = json.loads(
                    page.evaluate(
                        "JSON.stringify({"
                        "language:navigator.language,"
                        "languages:navigator.languages,"
                        "hardwareConcurrency:navigator.hardwareConcurrency,"
                        "deviceMemory:navigator.deviceMemory,"
                        "screen:[screen.width,screen.height],"
                        "dpr:devicePixelRatio,"
                        "timeZone:Intl.DateTimeFormat().resolvedOptions().timeZone"
                        "})"
                    )
                )

            assert visible == {
                "language": "fr-FR",
                "languages": ["fr-FR", "fr"],
                "hardwareConcurrency": 12,
                "deviceMemory": 16,
                "screen": [2560, 1440],
                "dpr": 1.25,
                "timeZone": "Europe/Paris",
            }, visible

            assert manifest["profile"]["catalogId"] == profile["browser"]["catalogId"]
            assert manifest["javascriptRuntime"]["actualV8Version"] == "14.9.207.35"
            assert manifest["javascriptRuntime"]["icuApplicationLocale"] == "fr-FR"
            assert manifest["javascriptRuntime"]["icuTimeZone"] == "Europe/Paris"
            assert manifest["httpHeaders"]["source"] == "ResolvedFingerprintProfile"
            assert manifest["httpHeaders"]["userAgent"] == EXPECTED_UA
            assert manifest["httpHeaders"]["acceptLanguage"] == "fr-FR,fr;q=0.9"
            assert manifest["httpHeaders"]["secChUa"] == EXPECTED_CH
            assert manifest["canvas"]["selectionSource"] == "ResolvedFingerprintProfile.graphics"
            assert manifest["canvas"]["configuredBackend"] == "skia"
            assert manifest["canvas"]["configuredProfileSeed"] == "445050524f46494c"
            assert manifest["canvas"]["configuredCanvasSeed"] == "445043414e564153"
            assert manifest["canvas"]["actualDriverQueried"] is False
            assert manifest["canvas"]["runtimeBackendAttested"] is False
            assert manifest["canvas"]["gpuAttested"] is False
            assert manifest["transport"]["consumption"]["transportProfileIdPassedDirectly"] is False
            assert manifest["transport"]["consumption"]["manifestDigestPassedDirectly"] is False
            assert manifest["transport"]["tls"]["runtimeAttested"] is False
            assert manifest["consistency"]["tlsRuntimeAttested"] is False
            if os.name == "nt":
                assert manifest["transport"]["backend"] == "wreq"
                assert "wreq/6.0.0-rc.29" in manifest["transport"]["libraryVersion"]
                assert manifest["transport"]["configuredNumericProfileId"] == 149
                assert manifest["transport"]["emulationPresetRuntimeQueried"] is False
                assert manifest["consistency"]["allNonTlsAttestedChecksPass"] is True

        assert server.observed.wait(2), "navigation was not observed"
        assert server.request_headers is not None
        headers = server.request_headers
        assert one(headers, "User-Agent") == EXPECTED_UA
        assert one(headers, "Accept-Language") == "fr-FR,fr;q=0.9"
        assert one(headers, "Sec-CH-UA") == EXPECTED_CH
        assert one(headers, "Sec-CH-UA-Mobile") == "?0"
        assert one(headers, "Sec-CH-UA-Platform") == '"Windows"'

        # A second valid profile with a different observable digest cannot be
        # installed into V8's cached physical App. The failed reservation must
        # still leave the original profile reusable below.
        different = json.loads(json.dumps(profile))
        different["navigator"]["hardwareConcurrency"] = 24
        try:
            Runtime(**runtime_kwargs(args), fingerprint_profile_json=different)
        except DarkPandaError as error:
            assert error.status == 6, error
            assert "RuntimeOptionsMismatch" in str(error), error
        else:
            raise AssertionError("different observable profile replaced cached runtime")

        # Repeat the rejection after a logical Runtime has been destroyed and
        # the physical V8/App runtime is cached. The invalid attempt must not
        # corrupt that cached session; reopening the original profile works.
        try:
            Runtime(**runtime_kwargs(args), fingerprint_profile_json=invalid)
        except DarkPandaError as error:
            assert error.status == 1, error
        else:
            raise AssertionError("invalid profile was accepted after runtime reuse")
        with Runtime(
            **runtime_kwargs(args),
            # Reformat and reorder every object key. Physical runtime reuse is
            # based on the validated observable digest, not caller JSON bytes.
            fingerprint_profile_json=json.dumps(profile, indent=2, sort_keys=True),
        ) as reopened:
            assert reopened.identity_manifest()["profile"]["catalogId"] == profile["browser"]["catalogId"]
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    print("darkpanda native strict fingerprint/profile manifest: PASS")


if __name__ == "__main__":
    main()
