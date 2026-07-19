# DarkPanda Canvas backend

This directory is an optional CPU Canvas backing-store library. It is kept
behind a versioned C ABI so the Zig DOM/WebIDL layer can choose `skia` or
`fake` at surface creation time without linking a Rust runtime into the main
browser library.

## Dependency choice

`skia-safe` is pinned to exactly `0.99.0` and Cargo.lock pins its complete Rust
dependency graph. Default features are disabled; `binary-cache` and
`embed-freetype` are enabled, so this component contains CPU raster Skia and
its font raster dependency but no GPU, PDF, image
codec, text-layout, or embedded ICU feature set.

This uses rust-skia directly instead of `skia-canvas`. `skia-canvas` exposes a
Node/N-API-oriented HTML Canvas package with its own JavaScript object and
threading model. DarkPanda already owns WebIDL, V8 isolates, object identity,
and task scheduling. Linking N-API into that path would add another JS ABI and
make Python/native embedding harder. rust-skia gives the lower-level Skia
surface needed here and allows the exported boundary to remain plain C.

## ABI and pixel contract

The public ABI is in `include/darkpanda_canvas_backend.h`; the Zig loader is
`adapter.zig`. ABI v2 keeps Canvas-space rectangle coordinates and opacity as
floating point through the Skia call and exposes non-antialiased `clearRect`.

- The caller sets `struct_size` and `abi_version` in a create descriptor.
- A surface is opaque and thread-affine. Every operation, including free, must
  run on its creating OS thread. Wrong-thread calls fail without mutating or
  consuming the surface.
- Surface storage and pixel I/O are always byte-ordered `R,G,B,A`, 8 bits per
  channel, premultiplied alpha, and sRGB. This is **not** Windows BGRA.
- Clear/fill colors are straight RGBA sRGB and are premultiplied by the
  backend. `write_pixels` input is already premultiplied RGBA.
- The canonical tight stride is `width * 4`. Read/write accept a larger caller
  stride and access only `width * 4` bytes per row. Rectangles are strict and
  must be completely in bounds; `fill_rect` clips negative coordinates.
- Dimensions can be zero. Non-zero surfaces are capped at 32768 per axis and
  512 MiB. Resize is transactional: allocation failure leaves the old surface
  intact.
- Skia surfaces use `ColorType::RGBA8888`, `AlphaType::Premul`, an explicit
  sRGB color space, and CPU raster memory.

The fake backend is a deterministic fingerprint fixture, not a vector
renderer. Its baseline pixels are derived from both `profile_seed` and
`canvas_seed` plus pixel coordinates. Repeated or differently chunked reads
are identical, and resizing back to the same dimensions recreates the same
baseline. Clear, integer source-over fill, write, and read all mutate/read one
persistent premultiplied buffer, so observable calls do not contradict one
another.

## Build and test

The main Zig build exposes explicit targets and does not put Skia on the
default build path:

```text
zig build canvas-backend       -Dtarget=x86_64-windows-msvc
zig build canvas-backend-smoke -Dtarget=x86_64-windows-msvc
zig build canvas-backend       -Dtarget=x86_64-linux-gnu
zig build canvas-backend       -Dtarget=aarch64-macos
```

The Windows build uses the MSVC Rust target. Linux supports x86_64/aarch64 GNU
and musl triples; macOS supports x86_64 and arm64. Native builds are preferred.
Cross builds also require the corresponding `rustup target` and platform
linker/SDK (in particular, an Apple SDK for macOS). rust-skia first tries its
versioned prebuilt Skia binary cache; if no matching archive exists, its own
build script falls back to compiling Skia.

`-Dcanvas_only=true` keeps this independent component build from configuring
V8, wreq, the browser executable, or the FFI library. The Rust-only validation
is:

```text
cargo test --locked --manifest-path src/canvas_backend/Cargo.toml \
  --target x86_64-pc-windows-msvc
```

`canvas-backend-smoke` builds and installs the platform dynamic library, loads
every symbol through `std.DynLib`, then exercises both backends, non-tight row
stride, premultiplication, clipping, write/read round trips, zero-size resize,
and fake-seed stability.

## DOM connection and selection

`browser/canvas_backend/Provider.zig` owns the library handle and every native
surface for a Page. `HTMLCanvasElement` lazily creates one surface, and resize,
reset, clear/fill rectangles and ImageData I/O all use that same surface.
ImageData is converted at the API boundary with Chromium-compatible integer
premultiply/unpremultiply rounding; transparent RGB is canonicalized to zero.

`Page.init` first selects driver/library/fallback policy, then injects Canvas
identity from `Browser.resolvedFingerprint().graphics` before `Frame.init` can
create a surface. Schema v2 represents both u64 seeds as exactly 16 lowercase
hexadecimal digits, avoiding Python/JavaScript's 2^53 JSON-number boundary:

```json
"graphics": {
  "bundleId": "angle-d3d11-generic-v1",
  "canvasBackend": "skia",
  "profileSeed": "445050524f46494c",
  "canvasSeed": "445043414e564153"
}
```

The provider derives a stable distinct seed for each canvas. Environment is
strictly an implementation-mechanics hook and cannot change observable kind
or seeds:

- `DARKPANDA_CANVAS_DRIVER=software|dynamic`
- `DARKPANDA_CANVAS_BACKEND_FALLBACK=disabled|software`
- `DARKPANDA_CANVAS_BACKEND_LIBRARY=<absolute path>`

The Python FFI selects the adjacent dynamic backend by default and exposes
`canvas_library_path`, `canvas_driver`, and `canvas_fallback`; those mechanics
are copied into the App and preflighted before V8 initialization. Environment
selection remains a CLI compatibility path. Dynamic loading is required when
requested unless software fallback is explicitly selected. Missing symbols and ABI mismatches are returned as
configuration errors; they do not silently switch a requested identity.
Configured `skia` is not a GPU attestation: the dynamic library uses CPU
rust-skia and does not reproduce Chrome GPU rasterization/antialiasing. The
runtime identity manifest consequently reports configured selection and marks
actual driver, runtime backend and GPU as unqueried/unattested.
