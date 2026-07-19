# DarkPanda wreq patch

This directory is the crates.io `wreq 6.0.0-rc.29` package whose registry
checksum is `3f0eba5f5814a94e5f1a99156f187133464e525b66bdbc69a9627d46530af2e1`.
The transport workspace selects it with `[patch.crates-io]`, so `wreq-util`
and the direct dependency share one package and one feature set.

DarkPanda's delta is intentionally limited to Trust Anchor Identifiers:

- add `TlsOptions::requested_trust_anchors` and its builder method;
- preserve `None` (extension absent) versus `Some(empty)` (support/retry
  signal with no selected identifier);
- call BoringSSL's generated
  `SSL_CTX_set1_requested_trust_anchors` binding while building the connector.

BoringSSL validates and serializes the identifier list. No TLS record or
ClientHello bytes are constructed or patched by wreq.
