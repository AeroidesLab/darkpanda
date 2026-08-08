# Native Windows x64

DarkPanda supports a native `x86_64-windows-msvc` build with Zig `0.15.2`,
Visual Studio 2022 C++ Build Tools, and a Windows 10 or 11 SDK. The default
application/network profile is Chrome Stable `149.0.7827.201` with V8 `14.9.207.35`.

HTTP and TLS use the external `wreq.dll`; libcurl is not part of the runtime.
WebCrypto links only the M149 BoringSSL `crypto.lib`. That archive already
contains the fipsmodule objects, so a second fipsmodule archive must not be
linked.

## Component inputs

Canvas, HTML5ever, wreq, and BoringSSL provide source and one standardized build
entry in their own repositories. Only the DarkPanda repository runs the build,
using the Chromium M149 toolchain fixed by DarkPanda's root profile and `DEPS`.
Each build produces an absolute standardized root:

```text
dist/x86_64-windows-msvc/
  bin/
  lib/
  include/
  metadata/build-info.json
  metadata/test-results.json
  metadata/SHA256SUMS
```

The browser build consumes those roots without invoking Cargo or CMake inside
this repository. Canvas's contract is `bin/canvas.dll` plus
`include/canvas.h`, exporting `cs_canvas_*` ABI v5. HTML5ever and wreq provide
`bin/html5ever.dll` and `bin/wreq.dll`; HTML5ever also provides
`lib/html5ever.dll.lib`. BoringSSL provides `lib/crypto.lib`.

## Build and install

Run from a Visual Studio Developer PowerShell and pass absolute paths:

```powershell
$Target = 'x86_64-windows-msvc'
$CanvasDist = (Resolve-Path ("..\canvas\dist\$Target")).Path
$Html5everDist = (Resolve-Path ("..\html5ever\dist\$Target")).Path
$WreqDist = (Resolve-Path ("..\wreq\dist\$Target")).Path
$BoringSslDist = (Resolve-Path ("..\boringssl\dist\$Target")).Path
$V8Archive = (Resolve-Path $env:DARKPANDA_V8_ARCHIVE).Path

zig build install -j2 `
  -Dtarget=$Target `
  -Doptimize=ReleaseFast `
  "-Dprebuilt_v8_path=$V8Archive" `
  "-Dcanvas_dist=$CanvasDist" `
  "-Dhtml5ever_dist=$Html5everDist" `
  "-Dwreq_dist=$WreqDist" `
  "-Dboringssl_dist=$BoringSslDist"
```

The complete adjacent runtime is installed in `zig-out\bin`:

```text
darkpanda.exe
darkpanda.dll
wreq.dll
canvas.dll
html5ever.dll
```

`zig-out\include` contains `darkpanda.h` and `canvas.h`. Keep the runtime DLLs
adjacent to `darkpanda.exe`/`darkpanda.dll`. The C ABI resolves an empty wreq or
Canvas path relative to the DarkPanda module, not relative to the embedding
process such as `python.exe`.

All compile, install, run, and test steps require the four dist roots.
DarkPanda's run/test graph sets the Canvas driver to `dynamic` and fallback to
`disabled`; a missing or incompatible `canvas.dll` is therefore an error.

## Direct Python API

The package in `python\darkpanda` calls `darkpanda.dll` in-process. It does not
start a child browser or connect over CDP:

```python
import os
from pathlib import Path

from darkpanda import CanvasDriver, CanvasFallback, ClientProfile, Runtime

bin_dir = Path(os.environ["DARKPANDA_BIN_DIR"]).resolve()

with Runtime(
    library_path=bin_dir / "darkpanda.dll",
    wreq_library_path=bin_dir / "wreq.dll",
    canvas_library_path=bin_dir / "canvas.dll",
    canvas_driver=CanvasDriver.DYNAMIC,
    canvas_fallback=CanvasFallback.DISABLED,
    locale="en-US",
    timezone="UTC",
    profile=ClientProfile.CHROME149,
) as runtime:
    with runtime.new_page() as page:
        page.navigate("https://example.com/")
        print(page.evaluate("({title: document.title, url: location.href})"))
```

Run the native smoke from the `browser` directory:

```powershell
$env:PYTHONPATH = "$PWD\python"
python .\python\smoke.py `
  --library "$PWD\zig-out\bin\darkpanda.dll" `
  --wreq "$PWD\zig-out\bin\wreq.dll" `
  --canvas "$PWD\zig-out\bin\canvas.dll"
```

The dedicated runtime attestation loads all four runtime DLLs and validates
the exported DarkPanda, wreq, and Canvas identities, including Canvas ABI 5:

```powershell
python .\tools\runtime_artifact_attestation.py `
  --python-root .\python `
  --library "$PWD\zig-out\bin\darkpanda.dll" `
  --wreq "$PWD\zig-out\bin\wreq.dll" `
  --canvas "$PWD\zig-out\bin\canvas.dll" `
  --html5ever "$PWD\zig-out\bin\html5ever.dll"
```

## V8 parity boundary

The V8 source revision and Windows x64 build tuple are pinned to Chrome 149:
pointer compression/shared cage, external code space, sandbox, static roots,
Temporal, the 64-byte in-heap TypedArray threshold, and embedder internal-field
counts. This aligns ordinary ECMAScript and Math behavior, but it does not make
the complete browser equivalent to official Chrome.

The standalone V8 build is non-official and does not use Chrome's ThinLTO, PGO,
or identical final link layout. Dedicated Workers also currently create
another Context in the browser's single V8 isolate instead of owning a separate
thread/isolate. DOM, WebIDL, rendering, GPU, and process isolation remain
separate compatibility surfaces.
