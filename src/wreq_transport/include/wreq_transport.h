#ifndef WREQ_TRANSPORT_H
#define WREQ_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>

#if !defined(WREQ_TRANSPORT_API)
#if defined(_WIN32)
#define WREQ_TRANSPORT_API __declspec(dllimport)
#else
#define WREQ_TRANSPORT_API __attribute__((visibility("default")))
#endif
#endif

#if defined(_WIN32)
#define WREQ_TRANSPORT_CALL __cdecl
#else
#define WREQ_TRANSPORT_CALL
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define WREQ_TRANSPORT_ABI_VERSION 5u
#define WREQ_TRANSPORT_DEFAULT_EVENT_CAPACITY 256u
#define WREQ_TRANSPORT_MAX_EVENT_CAPACITY 65536u
#define WREQ_TRANSPORT_OPTION_INSECURE_SKIP_TLS_VERIFY (UINT64_C(1) << 0)
#define WREQ_TRANSPORT_OPTION_CUSTOM_DNS (UINT64_C(1) << 1)
#define WREQ_REQUEST_OPTION_CONFIG_OVERRIDE (UINT64_C(1) << 0)
#define WREQ_REQUEST_OPTION_INSECURE_SKIP_TLS_VERIFY (UINT64_C(1) << 1)
#define WREQ_REQUEST_OPTION_FOLLOW_REDIRECTS (UINT64_C(1) << 2)
#define WREQ_TRANSPORT_PROFILE_DEFAULT 0u
#define WREQ_TRANSPORT_PROFILE_CHROME_124 124u
#define WREQ_TRANSPORT_PROFILE_CHROME_149 149u

typedef struct WreqTransport WreqTransport;

typedef struct WreqSlice {
    const uint8_t *ptr;
    size_t len;
} WreqSlice;

typedef struct WreqHeader {
    WreqSlice name;
    WreqSlice value;
} WreqHeader;

/*
 * Extensible creation options. proxy_url may be empty; otherwise it must be
 * an absolute HTTP(S) proxy URL. event_capacity == 0 selects the default.
 * INSECURE_SKIP_TLS_VERIFY disables both certificate and hostname checks.
 * CUSTOM_DNS selects dns_nameservers instead of the operating-system resolver.
 * dns_nameservers is a UTF-8 list of at most eight IP literals. LF is the
 * canonical separator; comma is accepted for compatibility and CR is valid
 * only as part of CRLF. Bare IPv4/IPv6 literals use port 53; an explicit port
 * uses IPv4:port or [IPv6]:port syntax. Port zero is invalid. The slice must
 * be non-empty exactly when CUSTOM_DNS is set.
 * ABI version 5 removes the host IP-filter callback and places
 * dns_nameservers directly after the fixed client fields. Callers must pass
 * the complete v5 structure; the ABI version rejects v4 DLL/caller mixing.
 */
typedef struct WreqTransportOptions {
    uint32_t struct_size;
    uint32_t abi_version;
    uint64_t flags;
    WreqSlice proxy_url;
    uint32_t event_capacity;
    uint32_t profile_id;
    uint32_t reserved32;
    WreqSlice dns_nameservers;
} WreqTransportOptions;

/*
 * Every byte range is borrowed only for the duration of submit(). The DLL
 * deep-copies method, URL, the flat ordered header pairs (including
 * duplicates), and body before submit() returns success.
 */
typedef struct WreqRequest {
    uint32_t struct_size;
    uint32_t abi_version;
    WreqSlice method;
    WreqSlice url;
    const WreqHeader *headers;
    size_t header_count;
    WreqSlice body;
    /* Zero means no transport-level total timeout. A nonzero deadline keeps
     * running while HEADERS awaits acknowledgement and through body delivery. */
    uint64_t timeout_ms;
    /* CONFIG_OVERRIDE selects proxy_url plus the request TLS flag instead of
     * the creation defaults. INSECURE_SKIP_TLS_VERIFY is valid only with it.
     * FOLLOW_REDIRECTS applies wreq's bounded (10-hop) redirect policy to this
     * request; browser-owned requests leave it clear and handle redirects in
     * the browser layer. */
    uint64_t flags;
    /* Empty means a direct request when CONFIG_OVERRIDE is set. */
    WreqSlice proxy_url;
} WreqRequest;

enum {
    WREQ_EVENT_HEADERS = 1u,
    WREQ_EVENT_DATA = 2u,
    WREQ_EVENT_DONE = 3u,
    WREQ_EVENT_ERROR = 4u,
    WREQ_EVENT_CANCELLED = 5u,
    WREQ_EVENT_WEBSOCKET_OPEN = 6u,
    WREQ_EVENT_WEBSOCKET_TEXT = 7u,
    WREQ_EVENT_WEBSOCKET_BINARY = 8u,
    WREQ_EVENT_WEBSOCKET_CLOSE = 9u,
};

enum {
    WREQ_WEBSOCKET_SEND_TEXT = 1u,
    WREQ_WEBSOCKET_SEND_BINARY = 2u,
    WREQ_WEBSOCKET_SEND_CLOSE = 3u,
};

enum {
    WREQ_HTTP_VERSION_UNKNOWN = 0u,
    WREQ_HTTP_VERSION_09 = 9u,
    WREQ_HTTP_VERSION_10 = 10u,
    WREQ_HTTP_VERSION_11 = 11u,
    WREQ_HTTP_VERSION_2 = 20u,
    WREQ_HTTP_VERSION_3 = 30u,
};

/*
 * `headers` and `data` are immutable views owned by this event. They remain
 * valid until wreq_transport_event_free(event). ERROR uses data for a UTF-8
 * diagnostic. DATA uses data for response bytes. WEBSOCKET_OPEN owns the
 * HTTP upgrade response headers/status; WEBSOCKET_TEXT/BINARY use data for a
 * complete message; WEBSOCKET_CLOSE uses status_code for the close code and
 * data for its UTF-8 reason. A successful HTTP DONE event reports body bytes
 * before and after transparent content decoding in encoded_body_size and
 * decoded_body_size; other event kinds leave both fields zero.
 */
typedef struct WreqEvent {
    uint32_t kind;
    uint32_t http_version;
    uint64_t request_id;
    uint16_t status_code;
    uint16_t reserved16;
    uint32_t reserved32;
    uint64_t encoded_body_size;
    uint64_t decoded_body_size;
    const WreqHeader *headers;
    size_t header_count;
    WreqSlice data;
} WreqEvent;

/* The Windows x64 host and Zig loader rely on the platform C ABI, never on a
 * packed representation. Keep these assertions beside the public layout. */
#if defined(_WIN64)
#if defined(__cplusplus)
static_assert(sizeof(WreqSlice) == 16, "WreqSlice ABI drift");
static_assert(sizeof(WreqHeader) == 32, "WreqHeader ABI drift");
static_assert(sizeof(WreqTransportOptions) == 64, "WreqTransportOptions ABI drift");
static_assert(offsetof(WreqTransportOptions, proxy_url) == 16, "options.proxy_url ABI drift");
static_assert(offsetof(WreqTransportOptions, profile_id) == 36, "options.profile_id ABI drift");
static_assert(offsetof(WreqTransportOptions, dns_nameservers) == 48, "options.dns_nameservers ABI drift");
static_assert(sizeof(WreqRequest) == 104, "WreqRequest ABI drift");
static_assert(offsetof(WreqRequest, method) == 8, "request.method ABI drift");
static_assert(offsetof(WreqRequest, body) == 56, "request.body ABI drift");
static_assert(offsetof(WreqRequest, timeout_ms) == 72, "request.timeout ABI drift");
static_assert(offsetof(WreqRequest, proxy_url) == 88, "request.proxy_url ABI drift");
static_assert(sizeof(WreqEvent) == 72, "WreqEvent ABI drift");
static_assert(offsetof(WreqEvent, encoded_body_size) == 24, "event.encoded_body_size ABI drift");
static_assert(offsetof(WreqEvent, decoded_body_size) == 32, "event.decoded_body_size ABI drift");
static_assert(offsetof(WreqEvent, headers) == 40, "event.headers ABI drift");
static_assert(offsetof(WreqEvent, data) == 56, "event.data ABI drift");
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(WreqSlice) == 16, "WreqSlice ABI drift");
_Static_assert(sizeof(WreqHeader) == 32, "WreqHeader ABI drift");
_Static_assert(sizeof(WreqTransportOptions) == 64, "WreqTransportOptions ABI drift");
_Static_assert(offsetof(WreqTransportOptions, proxy_url) == 16, "options.proxy_url ABI drift");
_Static_assert(offsetof(WreqTransportOptions, profile_id) == 36, "options.profile_id ABI drift");
_Static_assert(offsetof(WreqTransportOptions, dns_nameservers) == 48, "options.dns_nameservers ABI drift");
_Static_assert(sizeof(WreqRequest) == 104, "WreqRequest ABI drift");
_Static_assert(offsetof(WreqRequest, method) == 8, "request.method ABI drift");
_Static_assert(offsetof(WreqRequest, body) == 56, "request.body ABI drift");
_Static_assert(offsetof(WreqRequest, timeout_ms) == 72, "request.timeout ABI drift");
_Static_assert(offsetof(WreqRequest, proxy_url) == 88, "request.proxy_url ABI drift");
_Static_assert(sizeof(WreqEvent) == 72, "WreqEvent ABI drift");
_Static_assert(offsetof(WreqEvent, encoded_body_size) == 24, "event.encoded_body_size ABI drift");
_Static_assert(offsetof(WreqEvent, decoded_body_size) == 32, "event.decoded_body_size ABI drift");
_Static_assert(offsetof(WreqEvent, headers) == 40, "event.headers ABI drift");
_Static_assert(offsetof(WreqEvent, data) == 56, "event.data ABI drift");
#endif
#endif

enum {
    WREQ_TRANSPORT_OK = 0,
    WREQ_TRANSPORT_EMPTY = 1,
    WREQ_TRANSPORT_INVALID_ARGUMENT = -1,
    WREQ_TRANSPORT_NOT_FOUND = -2,
    WREQ_TRANSPORT_INVALID_STATE = -3,
    WREQ_TRANSPORT_SHUTTING_DOWN = -4,
    WREQ_TRANSPORT_INTERNAL_ERROR = -5,
    WREQ_TRANSPORT_PANIC = -6,
    WREQ_TRANSPORT_OVERFLOW = -7,
    WREQ_TRANSPORT_OUT_OF_MEMORY = -8,
};

/* Creates a Chrome 149 / Windows transport. Redirects, cookies, and system
 * proxy discovery are disabled. */
WREQ_TRANSPORT_API int32_t WREQ_TRANSPORT_CALL
wreq_transport_create(WreqTransport **out_transport);

WREQ_TRANSPORT_API int32_t WREQ_TRANSPORT_CALL
wreq_transport_create_with_options(const WreqTransportOptions *options,
                                   WreqTransport **out_transport);

/* NULL is a no-op. This must not race any other operation on the handle. */
WREQ_TRANSPORT_API void WREQ_TRANSPORT_CALL
wreq_transport_free(WreqTransport *transport);

WREQ_TRANSPORT_API int32_t WREQ_TRANSPORT_CALL
wreq_transport_submit(WreqTransport *transport,
                      const WreqRequest *request,
                      uint64_t *out_request_id);

/* WebSocket requests use the same deep-copied request layout, but require GET,
 * an empty body, no redirect flag, and a ws:// or wss:// URL. OPEN is emitted
 * only after the RFC 6455 response has been validated and upgraded. */
WREQ_TRANSPORT_API int32_t WREQ_TRANSPORT_CALL
wreq_transport_websocket_submit(WreqTransport *transport,
                                const WreqRequest *request,
                                uint64_t *out_request_id);

/* send() deep-copies data before returning. TEXT and CLOSE require UTF-8;
 * CLOSE accepts code 1000 or 3000..4999 and at most 123 reason bytes. */
WREQ_TRANSPORT_API int32_t WREQ_TRANSPORT_CALL
wreq_transport_websocket_send(WreqTransport *transport,
                              uint64_t request_id,
                              uint32_t message_type,
                              WreqSlice data,
                              uint16_t close_code);

WREQ_TRANSPORT_API int32_t WREQ_TRANSPORT_CALL
wreq_transport_websocket_cancel(WreqTransport *transport,
                                uint64_t request_id);

/* Cancellation is idempotent while a request remains in flight. */
WREQ_TRANSPORT_API int32_t WREQ_TRANSPORT_CALL
wreq_transport_cancel(WreqTransport *transport, uint64_t request_id);

/* timeout_ms == 0 is non-blocking; UINT32_MAX waits indefinitely. Only one
 * polling call may block at a time. EMPTY always leaves *out_event == NULL. */
WREQ_TRANSPORT_API int32_t WREQ_TRANSPORT_CALL
wreq_transport_poll_event(WreqTransport *transport,
                          uint32_t timeout_ms,
                          WreqEvent **out_event);

/* Interrupts a blocking poll and makes it return EMPTY without fabricating a
 * request event. Repeated pending wakeups are coalesced. */
WREQ_TRANSPORT_API int32_t WREQ_TRANSPORT_CALL
wreq_transport_wakeup(WreqTransport *transport);

/* A response body is not polled by this layer until its HEADERS event is
 * acknowledged. Freeing the HEADERS event does not acknowledge it. */
WREQ_TRANSPORT_API int32_t WREQ_TRANSPORT_CALL
wreq_transport_headers_ack(WreqTransport *transport, uint64_t request_id);

/* NULL is a no-op. Events may outlive their transport, but must be freed by
 * this function before the DLL is unloaded. */
WREQ_TRANSPORT_API void WREQ_TRANSPORT_CALL
wreq_transport_event_free(WreqEvent *event);

/* Process-lifetime, NUL-terminated implementation/dependency version string. */
WREQ_TRANSPORT_API const char *WREQ_TRANSPORT_CALL
wreq_transport_version(void);

WREQ_TRANSPORT_API uint32_t WREQ_TRANSPORT_CALL
wreq_transport_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif
