# wreq transport

This directory contains a Windows-first Rust `cdylib` with a small C ABI. It
is the network transport boundary for the browser host. ABI v4 adds exact
pre/post content-decoding body counts to successful HTTP DONE events; this is
the transport input for Chrome-compatible PerformanceResourceTiming sizes.
It retains ABI v3 native WebSocket submit/send/cancel and
OPEN/TEXT/BINARY/CLOSE events, plus the ABI v2 optional
calls one thread-safe host IP-policy callback after DNS resolution and before
TCP connection; no other Zig, C, or Python callback runs on Tokio workers.
As browsers require, `localhost` and every `*.localhost` name (case-insensitive,
with an optional trailing dot) resolve internally to IPv4 and IPv6 loopback;
the optional IP-policy callback runs afterward and may still block them.

The dependency pair is deliberately exact:

- `wreq = 6.0.0-rc.29`
- `wreq-util = 3.0.0-rc.14`

`wreq` is patched through `vendor/wreq` rather than forked at the transport
ABI. The patch exposes BoringSSL's existing
`SSL_CTX_set1_requested_trust_anchors` API as a `TlsOptions` field. Chrome149
on Windows supplies `Some(empty)`, which makes BoringSSL encode extension
`0xca34` with payload `0000`; Chrome124 and `None` still omit it. This is a
native protocol option, not raw ClientHello byte injection.

The default client configuration is `Chrome149` on `Windows`, matching the
repository's V8 14.9 generation. `Chrome124` remains selectable through the
versioned options for controlled comparison. Redirects use `Policy::none()`,
the cookie-store feature is not compiled, and system
proxy discovery is both uncompiled and explicitly disabled with `no_proxy()`.
The request builder disables emulation's default document headers because the
browser host supplies the complete fetch/navigation context header list.

`wreq_transport_create_with_options` reserves the versioned client-level ABI
for an explicit HTTP(S) proxy, TLS verification policy, event capacity, and IP
filter callback.
The ordinary `create` call uses Chrome149, verification, no proxy, and 256 event slots.
Requests also have a versioned struct and an optional total timeout. A request
can override proxy and TLS verification together; clients are cached by that
configuration, preserving connection reuse without incorrectly pinning every
request to the creation defaults.

The IP callback uses transport-neutral family values `4` and `6`, not platform
`AF_*` constants. DNS results are filtered individually, so a public fallback
remains usable when another address is blocked. A request fails when every
resolved address is blocked. Literal IPv4/IPv6 request and proxy hosts are
checked separately because they bypass the resolver. Invalid callback input is
treated as blocked by the Zig host.

On Windows, the transport snapshots usable roots from both the Current User
and Local Machine `ROOT` certificate stores, then builds a BoringSSL
`CertStore`. This includes locally installed enterprise roots and avoids the
static WebPKI bundle. It is not identical to delegating validation to the
Windows Certificate Chain Engine: dynamic root updates, Windows revocation
policy, and the `Disallowed` store are follow-up integration work.

`btls-sys 0.5.6` explicitly does not support its `prefix-symbols` feature on
Windows; enabling it generates prefixed Rust declarations but leaves the MSVC
libraries unprefixed and fails at link time. This crate therefore leaves that
feature disabled on Windows. DLL-level symbol collision validation remains a
host-integration test item.

## Event protocol

`submit` synchronously validates and copies all request memory, then returns a
monotonic request id. Each request produces one of these sequences:

```text
HEADERS -> DATA* -> DONE
HEADERS -> DATA* -> ERROR
HEADERS -> DATA* -> CANCELLED
ERROR
CANCELLED
```

After queuing `HEADERS`, the worker waits for
`wreq_transport_headers_ack(request_id)`. It does not call the response body's
stream poll before that ACK. The HTTP stack or operating system can still
perform protocol-level buffering, so this is an application-layer backpressure
guarantee, not a claim that the socket receives zero bytes.

The event owns every pointer exposed through `WreqEvent`; release it only with
`wreq_transport_event_free`. An event does not borrow from its transport and
may be freed after the transport. Request memory is caller-owned and may be
changed or freed as soon as `submit` returns.

For successful HTTP requests, DONE reports `encoded_body_size` from Body
frames below transparent decompression and `decoded_body_size` from the DATA
stream delivered to the host. Chunk framing and HTTP/2 frame overhead are not
part of encoded body size. Other event kinds leave both fields zero.

Event memory is bounded by a Tokio semaphore. A slot is acquired before an
event enters the synchronous queue and remains owned by that event until
`event_free`, so callers must release consumed events promptly. At capacity,
workers asynchronously wait instead of blocking a Tokio worker thread.

`wreq_transport_wakeup` coalesces wake notifications into the same poll inbox
without creating a fake request event. A poll that consumes a wake returns
`EMPTY`; real request events retain their queue order and remain available.

The request ABI retains a flat list of ordered duplicate headers. The current
`wreq` `HeaderMap`/`OrigHeaderMap` backend groups interleaved values with the
same name during wire serialization, so a sequence such as `A: 1, B: 1, A: 2`
is not yet wire-exact. Fixing that requires a lower-level HTTP/1 encoder change;
the C ABI does not need to change.

`submit`, `cancel`, and `headers_ack` may run concurrently. Calls to
`poll_event` are serialized internally. `wreq_transport_free` must not race any
operation using the same raw handle. Invalid non-NULL pointers, double-free,
and unloading the DLL while handles/events exist are caller errors that Rust
panic containment cannot make safe.

`wreq_transport_free` cancels async requests and waits for the Tokio runtime,
including an in-flight blocking OS DNS lookup, to stop before returning. This
is required so a C host may safely unload the DLL after freeing the transport;
teardown can therefore wait for the platform resolver if that resolver stalls.

## Windows build

From this directory in an MSVC developer environment:

```powershell
cargo check --target x86_64-pc-windows-msvc
cargo test --target x86_64-pc-windows-msvc
cargo build --release --target x86_64-pc-windows-msvc
```

After the release build, the deterministic TLS 1.3 fixture forces two fresh
TCP connections through one wreq client and verifies both the trust-anchor
extension and PSK resumption:

```powershell
python ..\..\tests\wreq_tls_resumption.py `
  --wreq .\target\x86_64-pc-windows-msvc\release\wreq_transport.dll

Cargo keeps the internal crate output name above. The public ABI version string
uses `libwreq`, and `zig build` installs the library as `wreq.dll` on Windows,
`libwreq.so` on Linux, or `libwreq.dylib` on macOS.
```

The native browser/peet gate additionally requires Chrome149's cold
`t13d1517h2` shape and `0xca34:0000`. `tests/tls_fingerprint_compare.py`
normalizes GREASE and extension ordering when comparing saved Chrome/wreq cold
and resumed peet captures.

The DLL and import library are emitted below
`target/x86_64-pc-windows-msvc/release`.
