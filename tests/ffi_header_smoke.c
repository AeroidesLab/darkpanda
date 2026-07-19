#include "darkpanda.h"

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
#define DP_STATIC_ASSERT(condition, message) static_assert((condition), message)
#else
#define DP_STATIC_ASSERT(condition, message) _Static_assert((condition), message)
#endif

/*
 * The shipping Python/Windows ABI is x64. Compile this file once as C and once
 * as C++ with MSVC /W4 /WX so declarations and layout stay consumable from
 * both languages without warning suppressions.
 */
DP_STATIC_ASSERT(sizeof(void *) == 8, "the Windows embedding ABI requires x64");
DP_STATIC_ASSERT(sizeof(dp_status) == 4, "dp_status size changed");
DP_STATIC_ASSERT(sizeof(dp_runtime_handle) == 8, "runtime handle size changed");
DP_STATIC_ASSERT(sizeof(dp_page_handle) == 8, "page handle size changed");

DP_STATIC_ASSERT(sizeof(dp_slice) == 16, "dp_slice size changed");
DP_STATIC_ASSERT(offsetof(dp_slice, ptr) == 0, "dp_slice.ptr offset changed");
DP_STATIC_ASSERT(offsetof(dp_slice, len) == 8, "dp_slice.len offset changed");
DP_STATIC_ASSERT(sizeof(dp_bytes) == 16, "dp_bytes size changed");
DP_STATIC_ASSERT(sizeof(dp_error) == 24, "dp_error size changed");
DP_STATIC_ASSERT(offsetof(dp_error, code) == 0, "dp_error.code offset changed");
DP_STATIC_ASSERT(offsetof(dp_error, message) == 8, "dp_error.message offset changed");

DP_STATIC_ASSERT(sizeof(dp_runtime_options) == 152, "dp_runtime_options size changed");
DP_STATIC_ASSERT(offsetof(dp_runtime_options, abi_version) == 0, "runtime abi_version offset changed");
DP_STATIC_ASSERT(offsetof(dp_runtime_options, struct_size) == 4, "runtime struct_size offset changed");
DP_STATIC_ASSERT(offsetof(dp_runtime_options, wreq_transport_path) == 8, "runtime wreq path offset changed");
DP_STATIC_ASSERT(offsetof(dp_runtime_options, navigation_timeout_ms) == 24, "runtime timeout offset changed");
DP_STATIC_ASSERT(offsetof(dp_runtime_options, reserved) == 28, "runtime reserved offset changed");
DP_STATIC_ASSERT(offsetof(dp_runtime_options, application_locale) == 56, "runtime locale offset changed");
DP_STATIC_ASSERT(offsetof(dp_runtime_options, timezone) == 72, "runtime timezone offset changed");
DP_STATIC_ASSERT(offsetof(dp_runtime_options, client_profile) == 88, "runtime client profile offset changed");
DP_STATIC_ASSERT(offsetof(dp_runtime_options, reserved_tail) == 92, "runtime reserved tail offset changed");
DP_STATIC_ASSERT(offsetof(dp_runtime_options, fingerprint_profile_json) == 96, "runtime fingerprint JSON offset changed");
DP_STATIC_ASSERT(offsetof(dp_runtime_options, wreq_dns_nameservers) == 112, "runtime DNS nameservers offset changed");
DP_STATIC_ASSERT(offsetof(dp_runtime_options, canvas_backend_path) == 128, "runtime Canvas path offset changed");
DP_STATIC_ASSERT(offsetof(dp_runtime_options, canvas_driver) == 144, "runtime Canvas driver offset changed");
DP_STATIC_ASSERT(offsetof(dp_runtime_options, canvas_fallback) == 148, "runtime Canvas fallback offset changed");
DP_STATIC_ASSERT(DP_CANVAS_DRIVER_DYNAMIC == 2, "Canvas driver ABI changed");
DP_STATIC_ASSERT(DP_CANVAS_FALLBACK_SOFTWARE == 1, "Canvas fallback ABI changed");

DP_STATIC_ASSERT(sizeof(dp_navigation_options) == 32, "dp_navigation_options size changed");
DP_STATIC_ASSERT(offsetof(dp_navigation_options, timeout_ms) == 8, "navigation timeout offset changed");
DP_STATIC_ASSERT(sizeof(dp_evaluate_options) == 32, "dp_evaluate_options size changed");
DP_STATIC_ASSERT(offsetof(dp_evaluate_options, promise_timeout_ms) == 8, "evaluate timeout offset changed");
DP_STATIC_ASSERT(sizeof(dp_click_options) == 32, "dp_click_options size changed");
DP_STATIC_ASSERT(offsetof(dp_click_options, frame_id) == 8, "click frame id offset changed");
DP_STATIC_ASSERT(offsetof(dp_click_options, timeout_ms) == 12, "click timeout offset changed");
DP_STATIC_ASSERT(offsetof(dp_click_options, pierce_shadow) == 16, "click pierce offset changed");
DP_STATIC_ASSERT(offsetof(dp_click_options, move_delay_ms) == 20, "click move delay offset changed");
DP_STATIC_ASSERT(offsetof(dp_click_options, press_delay_ms) == 24, "click press delay offset changed");
DP_STATIC_ASSERT(sizeof(dp_evaluate_result) == 24, "dp_evaluate_result size changed");
DP_STATIC_ASSERT(offsetof(dp_evaluate_result, value) == 0, "evaluate result value offset changed");
DP_STATIC_ASSERT(offsetof(dp_evaluate_result, is_error) == 16, "evaluate result flag offset changed");

int main(void) {
    return DP_ABI_VERSION == 1u ? 0 : 1;
}
