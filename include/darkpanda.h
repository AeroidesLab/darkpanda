#ifndef DARKPANDA_H
#define DARKPANDA_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#  if defined(DARKPANDA_BUILD)
#    define DP_API __declspec(dllexport)
#  else
#    define DP_API __declspec(dllimport)
#  endif
#else
#  define DP_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define DP_ABI_VERSION 1u

typedef uint64_t dp_runtime_handle;
typedef uint64_t dp_page_handle;

typedef enum dp_status {
    DP_OK = 0,
    DP_INVALID_ARGUMENT = 1,
    DP_INVALID_HANDLE = 2,
    DP_CLOSED = 3,
    DP_BUSY = 4,
    DP_OUT_OF_MEMORY = 5,
    DP_INITIALIZATION_FAILED = 6,
    DP_NAVIGATION_FAILED = 7,
    DP_EVALUATION_FAILED = 8,
    DP_CANCELLED = 9,
    DP_TIMEOUT = 10,
    DP_INTERNAL_ERROR = 11
} dp_status;

typedef enum dp_client_profile {
    DP_CLIENT_PROFILE_DEFAULT = 0,
    DP_CLIENT_PROFILE_DARKPANDA = 1,
    DP_CLIENT_PROFILE_CHROME149 = 149
} dp_client_profile;

typedef enum dp_canvas_driver {
    /* Legacy caller: retain CLI/environment mechanics. */
    DP_CANVAS_DRIVER_ENVIRONMENT = 0,
    DP_CANVAS_DRIVER_SOFTWARE = 1,
    DP_CANVAS_DRIVER_DYNAMIC = 2
} dp_canvas_driver;

typedef enum dp_canvas_fallback {
    DP_CANVAS_FALLBACK_DISABLED = 0,
    DP_CANVAS_FALLBACK_SOFTWARE = 1
} dp_canvas_fallback;

typedef struct dp_slice {
    const uint8_t *ptr;
    size_t len;
} dp_slice;

typedef struct dp_bytes {
    uint8_t *ptr;
    size_t len;
} dp_bytes;

typedef struct dp_error {
    dp_status code;
    dp_bytes message;
} dp_error;

typedef struct dp_runtime_options {
    uint32_t abi_version;
    uint32_t struct_size;
    /* Optional for C embedders. Python supplies an absolute sibling path. */
    dp_slice wreq_transport_path;
    uint32_t navigation_timeout_ms;
    /* Kept for binary compatibility with the original 56-byte ABI v1 type. */
    uint8_t reserved[28];
    /* Appended ABI v1 fields; old callers are detected through struct_size. */
    dp_slice application_locale;
    dp_slice timezone;
    /* Appended ABI v1 field. Zero selects the platform default. */
    uint32_t client_profile;
    uint32_t reserved_tail;
    /* Optional strict ResolvedFingerprintProfile schema-v2 JSON. */
    dp_slice fingerprint_profile_json;
    /* Optional LF-separated IP-literal DNS endpoints for Windows wreq.
     * Empty preserves the operating-system resolver. */
    dp_slice wreq_dns_nameservers;
    /* Optional absolute Canvas ABI v5 backend. Empty with DYNAMIC loads the
     * packaged Chromium M149 Skia CPU backend adjacent to DarkPanda. */
    dp_slice canvas_backend_path;
    uint32_t canvas_driver;
    uint32_t canvas_fallback;
    /* Optional absolute path used to attest the packaged WebRTC ABI. */
    dp_slice webrtc_backend_path;
    /* Required numeric TUN-interface address when WebRTC is enabled. */
    dp_slice webrtc_tun_bind_address;
    /* 0 = disabled, 1 = TUN-bound data channels. */
    uint32_t webrtc_mode;
    uint32_t webrtc_reserved;
} dp_runtime_options;

typedef struct dp_navigation_options {
    uint32_t abi_version;
    uint32_t struct_size;
    /* Zero selects the runtime default. */
    uint32_t timeout_ms;
    uint8_t reserved[20];
} dp_navigation_options;

typedef struct dp_evaluate_options {
    uint32_t abi_version;
    uint32_t struct_size;
    /* Zero selects the library default (currently 30 seconds). */
    uint32_t promise_timeout_ms;
    uint8_t reserved[20];
} dp_evaluate_options;

typedef struct dp_click_options {
    uint32_t abi_version;
    uint32_t struct_size;
    /* Zero selects the root frame represented by the page handle. */
    uint32_t frame_id;
    /* Zero selects the runtime's navigation timeout. */
    uint32_t timeout_ms;
    /* 0/1: permit browser-internal traversal of open and closed shadow roots. */
    uint8_t pierce_shadow;
    uint8_t reserved0[3];
    /* Zero selects the Chrome-compatible default of 16 ms. */
    uint32_t move_delay_ms;
    /* Zero selects the Chrome-compatible default of 60 ms. */
    uint32_t press_delay_ms;
    uint8_t reserved[4];
} dp_click_options;

typedef struct dp_evaluate_result {
    dp_bytes value;
    /* Non-zero is a JavaScript diagnostic carried in value, not an ABI error. */
    uint8_t is_error;
    uint8_t reserved[7];
} dp_evaluate_result;

DP_API uint32_t dp_abi_version(void);
/* NUL-terminated immutable build version; owned by the DLL. */
DP_API const char *dp_version(void);

/*
 * Binary-compatibility entry point: initializes only the original 56-byte
 * x64 ABI-v1 prefix, because an old caller may have allocated no appended
 * tail. New callers should use dp_runtime_options_init_sized.
 */
DP_API void dp_runtime_options_init(dp_runtime_options *out);
/* Initializes up to capacity bytes and publishes the initialized size. */
DP_API dp_status dp_runtime_options_init_sized(void *out, size_t capacity);
DP_API void dp_navigation_options_init(dp_navigation_options *out);
DP_API void dp_evaluate_options_init(dp_evaluate_options *out);
DP_API void dp_click_options_init(dp_click_options *out);

DP_API void dp_bytes_free(dp_bytes *bytes);
DP_API void dp_error_free(dp_error *error);
DP_API void dp_evaluate_result_free(dp_evaluate_result *result);

/*
 * The current DarkPanda App owns V8's process-global Platform, so ABI v1
 * permits one live runtime per process. Every browser/V8 operation is executed
 * on that runtime's private worker thread. Public calls may originate from any
 * thread; do not race destroy/close against another use except dp_page_cancel.
 */
DP_API dp_status dp_runtime_create(
    const dp_runtime_options *options,
    dp_runtime_handle *out_handle,
    dp_error *out_error);
/*
 * A valid handle is consumed before worker/session cleanup. A non-OK cleanup
 * result therefore does not make that handle reusable; discard it after the
 * call. An invalid handle returns DP_STATUS_INVALID_HANDLE.
 */
DP_API dp_status dp_runtime_destroy(
    dp_runtime_handle handle,
    dp_error *out_error);

/*
 * Returns an owned UTF-8 JSON report tying the resolved profile to the
 * configured ICU/V8 and actual HTTP transport. Release it with
 * dp_bytes_free. TLS fields in this report are build/catalog claims, not a
 * cryptographic runtime attestation.
 */
DP_API dp_status dp_runtime_identity_manifest(
    dp_runtime_handle handle,
    dp_bytes *out_json,
    dp_error *out_error);

DP_API dp_status dp_page_create(
    dp_runtime_handle runtime,
    dp_page_handle *out_page,
    dp_error *out_error);
/* A valid page handle is consumed even if worker-side cleanup reports error. */
DP_API dp_status dp_page_close(
    dp_page_handle page,
    dp_error *out_error);
DP_API dp_status dp_page_cancel(dp_page_handle page);

DP_API dp_status dp_page_navigate(
    dp_page_handle page,
    dp_slice url,
    const dp_navigation_options *options,
    dp_error *out_error);
DP_API dp_status dp_page_evaluate(
    dp_page_handle page,
    dp_slice script,
    const dp_evaluate_options *options,
    dp_evaluate_result *out_result,
    dp_error *out_error);

/*
 * Returns owned UTF-8 JSON describing the root and descendant frames. Each
 * entry includes frameId, parentFrameId, URL/name, attachment/visibility and
 * the iframe owner rect.
 * Release the result with dp_bytes_free.
 */
DP_API dp_status dp_page_frames(
    dp_page_handle page,
    dp_bytes *out_json,
    dp_error *out_error);

/*
 * Returns an owned privacy-minimized JSON batch for this Page's root frame,
 * descendant frames and Dedicated Workers. Only lifecycle phase, numeric
 * frame/request attribution, resource type/status, monotonic time, host and a
 * query-free/high-entropy-redacted path category are retained. `since_sequence`
 * acknowledges records at or below that cursor. `droppedCount` is cumulative
 * capacity eviction since Page creation. Release with dp_bytes_free.
 */
DP_API dp_status dp_page_network_observations(
    dp_page_handle page,
    uint64_t since_sequence,
    dp_bytes *out_json,
    dp_error *out_error);

/*
 * Dispatches a browser-trusted primary-mouse click at the selector's rect.
 * Hover, press and release are separate event-loop phases; no delay sleeps
 * while a V8 isolate/context is entered.
 */
DP_API dp_status dp_page_click(
    dp_page_handle page,
    dp_slice selector,
    const dp_click_options *options,
    dp_error *out_error);

#ifdef __cplusplus
}
#endif

#endif /* DARKPANDA_H */
