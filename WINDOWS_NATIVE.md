# Native Windows x64

This branch supports a native `x86_64-windows-msvc` build. Its Windows default
is the Chrome `149.0.7827.203` application/network profile with V8
`14.9.207.35`. HTTP and TLS use the Rust `wreq.dll`, not libcurl.
The remaining BoringSSL `crypto.lib` dependency implements WebCrypto
primitives only; it is not the TLS transport, and `ssl.lib` is not linked.

This is a source-build development path. It does not imply complete Windows or
Web Platform Test coverage. The page and DedicatedWorker `WebSocket` API use
the versioned wreq ABI v5 transport on Windows.

## Prerequisites

- Windows x64 with Visual Studio 2022 Build Tools (MSVC C++ workload) and a
  Windows 10 or 11 SDK.
- Zig `0.15.2`.
- Rust `1.88` or newer/Cargo with the `x86_64-pc-windows-msvc` target.
- Python 3 and Git when building the pinned V8 source rather than using a
  prebuilt archive.
- An MSVC `/MT` BoringSSL directory containing `crypto.lib` and
  `fipsmodule.lib` for WebCrypto.

Run the build from an MSVC developer PowerShell. Set
`DARKPANDA_DEPS_ROOT` to the dependency root described in the main README.
`DARKPANDA_V8_ARCHIVE`, `DARKPANDA_BORINGSSL_DIRECTORY`, and
`DARKPANDA_WREQ_LIBRARY` can override individual inputs. If the wreq override
is omitted, Cargo builds the pinned wreq transport from this repository:

```powershell
$DepsRoot = (Resolve-Path $env:DARKPANDA_DEPS_ROOT).Path
$V8Archive = if ($env:DARKPANDA_V8_ARCHIVE) {
    (Resolve-Path $env:DARKPANDA_V8_ARCHIVE).Path
} else {
    Join-Path $DepsRoot 'windows\v8\c_v8_standalone.lib'
}
$BoringSslDirectory = if ($env:DARKPANDA_BORINGSSL_DIRECTORY) {
    (Resolve-Path $env:DARKPANDA_BORINGSSL_DIRECTORY).Path
} else {
    Join-Path $DepsRoot 'windows\boringssl-prefix\lib'
}
$WreqOption = if ($env:DARKPANDA_WREQ_LIBRARY) {
    @("-Dprebuilt_wreq_library=$((Resolve-Path $env:DARKPANDA_WREQ_LIBRARY).Path)")
} else {
    @()
}

zig build -j2 `
  -Dtarget=x86_64-windows-msvc `
  -Doptimize=ReleaseFast `
  "-Dprebuilt_v8_path=$V8Archive" `
  "-Dprebuilt_boringssl_dir=$BoringSslDirectory" `
  @WreqOption
```

This direct `zig build` path is intended for development. Use the formal build
pipeline in the main README for acceptance artifacts and provenance manifests.
The key options are:

| Option | Purpose |
| --- | --- |
| `-Dprebuilt_v8_path=...` | Reuse the complete Windows `c_v8_standalone.lib`. If omitted, the sibling `zig-v8-fork` builds the pinned Chrome 149 V8 and its Rust/Temporal closure. |
| `-Dprebuilt_wreq_library=...` | Reuse a prebuilt wreq library. If omitted, Cargo builds `src/wreq_transport` for MSVC. |
| `-Dprebuilt_boringssl_dir=...` | Directory containing MSVC `/MT` `crypto.lib` and `fipsmodule.lib`; currently required for WebCrypto, not TLS. |

The five runtime files are installed together in `zig-out\bin`:

```text
darkpanda.exe
darkpanda.dll
wreq.dll
darkpanda_canvas_backend.dll
darkpanda_html5ever.dll
```

Keep the DLLs adjacent to the executable or embedding DLL. When the C ABI's
`wreq_transport_path` is empty, `darkpanda.dll` resolves `wreq.dll`
relative to its own module directory, not the host process image (for example,
`python.exe`). `DARKPANDA_WREQ_LIBRARY` remains the next explicit override
for standalone/CLI use. A quick executable check is:

```powershell
.\zig-out\bin\darkpanda.exe version
```

## Direct Python API (no CDP)

The package in `python\darkpanda` calls `darkpanda.dll` in-process with
`ctypes`. It does not start a subprocess, connect to localhost, or use CDP.
`Runtime` owns the native runtime, `new_page()` returns a `Page`, and
`navigate()`/`evaluate()` call the native ABI directly. Select the coherent
Chrome 149 profile explicitly when embedding:

```python
import os
from pathlib import Path

from darkpanda import CanvasDriver, ClientProfile, Runtime

bin_dir = Path(os.environ["DARKPANDA_BIN_DIR"]).resolve()

with Runtime(
    library_path=bin_dir / "darkpanda.dll",
    wreq_library_path=bin_dir / "wreq.dll",
    canvas_library_path=bin_dir / "darkpanda_canvas_backend.dll",
    canvas_driver=CanvasDriver.DYNAMIC,
    locale="en-US",
    timezone="UTC",
    profile=ClientProfile.CHROME149,
) as runtime:
    with runtime.new_page() as page:
        page.navigate("https://example.com/")
        value = page.evaluate("({title: document.title, url: location.href})")
        print(value)  # JSON text returned by the native evaluator
```

A complete strict schema-v2 profile can be supplied as JSON text, UTF-8 bytes,
or a Python mapping. In that mode the resolved profile owns locale/timezone,
Navigator/display identity and browser request headers together; omit
`locale`/`timezone`, or pass values that exactly agree with the profile. The
native side validates the 64 KiB/depth/value limits, duplicate and unknown
fields, Chrome/V8 catalog, UA metadata and transport manifest before it
reserves V8. It deep-copies the input for the physical Runtime/App lifetime.
Later logical Runtime generations compare the validated observable digest, so
JSON whitespace/key order cannot cause a false mismatch while a genuinely
different browser identity is rejected without mutating the cached session:

```python
import json

profile = json.loads(Path("profile.json").read_text(encoding="utf-8"))
with Runtime(
    library_path=bin_dir / "darkpanda.dll",
    wreq_library_path=bin_dir / "wreq.dll",
    profile=ClientProfile.CHROME149,
    fingerprint_profile_json=profile,
) as runtime:
    evidence = runtime.identity_manifest()
    print(evidence["consistency"])
```

`identity_manifest()` reports the actual `v8::V8::GetVersion()`, the
locale/timezone accepted by `ConfigureICU`, the exact UA/Accept-Language/UA-CH
values sent by the browser client, and the loaded wreq version/ABI plus the
numeric profile ID DarkPanda passed. wreq has no runtime getter for its
internal Profile enum, so that source mapping is labeled as a non-queried
claim. `network.transportProfileId` and `manifestDigest` are
validated and mapped by DarkPanda; wreq directly consumes numeric profile 149
and the ordered request headers, not those two strings. The TLS backend entry
is explicitly a pinned build/catalog claim with `runtimeAttested: false`, not
a fabricated cryptographic attestation. Canvas schema-v2 identity is likewise
reported as configured `skia|fake` plus canonical 16-digit hex seeds. The
manifest does not claim that a Page selected the dynamic driver or that a GPU
was observed; dynamic Skia is CPU rust-skia and differs from Chrome GPU
rasterization/antialiasing.

From the `browser` directory, run the native ABI smoke test with:

```powershell
$env:PYTHONPATH = "$PWD\python"
python .\python\smoke.py `
  --library "$PWD\zig-out\bin\darkpanda.dll" `
  --wreq "$PWD\zig-out\bin\wreq.dll" `
  --canvas "$PWD\zig-out\bin\darkpanda_canvas_backend.dll"
```

Additional native regressions cover retry after a missing transport, logical
Runtime state isolation, Chrome request metadata, high-signal V8/WebIDL pages,
the live wreq TLS/HTTP2 fingerprint, and the two peet.ws Turnstile fixtures.
The Turnstile regression proves trusted client-side challenge completion and
token consistency across the widget API and hidden inputs. The static peet.ws
fixtures have no backend Siteverify endpoint, so this is not evidence that a
site secret successfully redeemed the token:

```powershell
python .\tests\ffi_runtime_retry.py --library .\zig-out\bin\darkpanda.dll
python .\tests\ffi_runtime_session_isolation.py --library .\zig-out\bin\darkpanda.dll --wreq .\zig-out\bin\wreq.dll
python .\tests\ffi_request_context.py --library .\zig-out\bin\darkpanda.dll --wreq .\zig-out\bin\wreq.dll
python .\tests\ffi_fingerprint_profile.py --library .\zig-out\bin\darkpanda.dll --wreq .\zig-out\bin\wreq.dll
python .\tests\ffi_html_regressions.py --library .\zig-out\bin\darkpanda.dll --wreq .\zig-out\bin\wreq.dll
python .\tests\ffi_tls_peet.py --library .\zig-out\bin\darkpanda.dll --wreq .\zig-out\bin\wreq.dll
python .\tests\ffi_turnstile.py --library .\zig-out\bin\darkpanda.dll --wreq .\zig-out\bin\wreq.dll
```

## V8 parity boundary

The V8 source revision and deterministic Win x64 build tuple are pinned to
Chrome 149: pointer compression/shared cage, external code space, sandbox,
static roots, Temporal, the 64-byte in-heap TypedArray threshold, and embedder
internal-field counts. This aligns ordinary ECMAScript and Math behavior, but
does not make the whole browser indistinguishable from official Chrome.

The standalone build is non-official and does not use Chrome's ThinLTO,
Chrome/V8 PGO, or identical final link layout. Those differences can affect
startup, tier-up, GC, memory and timing distributions. More importantly,
Dedicated Workers currently create another Context in the Browser's single V8
isolate instead of owning a worker thread/isolate. Consequently Worker
`Atomics.wait`, COOP/COEP `crossOriginIsolated`/SharedArrayBuffer enablement,
and SharedArrayBuffer structured cloning are known deterministic gaps. DOM and
WebIDL prototypes are generated by DarkPanda's snapshot layer and remain a
separate parity surface from V8 itself.
