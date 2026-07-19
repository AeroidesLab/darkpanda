#ifndef DARKPANDA_CANVAS_BACKEND_H
#define DARKPANDA_CANVAS_BACKEND_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && defined(DP_CANVAS_BACKEND_LINK_SHARED)
#define DP_CANVAS_API __declspec(dllimport)
#elif defined(__GNUC__) || defined(__clang__)
#define DP_CANVAS_API __attribute__((visibility("default")))
#else
#define DP_CANVAS_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define DP_CANVAS_BACKEND_ABI_VERSION 2u
#define DP_CANVAS_BACKEND_MAX_DIMENSION 32768u
#define DP_CANVAS_BACKEND_MAX_SURFACE_BYTES (512u * 1024u * 1024u)

typedef struct dp_canvas_surface dp_canvas_surface;

typedef enum dp_canvas_status {
    DP_CANVAS_OK = 0,
    DP_CANVAS_INVALID_ARGUMENT = 1,
    DP_CANVAS_UNSUPPORTED_ABI = 2,
    DP_CANVAS_UNSUPPORTED_BACKEND = 3,
    DP_CANVAS_OUT_OF_MEMORY = 4,
    DP_CANVAS_SIZE_OVERFLOW = 5,
    DP_CANVAS_OUT_OF_BOUNDS = 6,
    DP_CANVAS_BUFFER_TOO_SMALL = 7,
    DP_CANVAS_WRONG_THREAD = 8,
    DP_CANVAS_BACKEND_FAILURE = 9,
    DP_CANVAS_RUST_PANIC = 10
} dp_canvas_status;

typedef enum dp_canvas_backend_kind {
    DP_CANVAS_BACKEND_SKIA = 1,
    DP_CANVAS_BACKEND_FAKE = 2
} dp_canvas_backend_kind;

typedef enum dp_canvas_pixel_format {
    /* In-memory byte order is R, G, B, A on every supported architecture. */
    DP_CANVAS_PIXEL_RGBA8_PREMUL_SRGB = 1
} dp_canvas_pixel_format;

/* clear/fill colors are straight (unpremultiplied) sRGB. Pixel buffers are
 * RGBA8 premultiplied sRGB, as stated by dp_canvas_pixel_format. */
typedef struct dp_canvas_rgba8 {
    uint8_t r;
    uint8_t g;
    uint8_t b;
    uint8_t a;
} dp_canvas_rgba8;

typedef struct dp_canvas_surface_desc {
    uint32_t struct_size;
    uint32_t abi_version;
    int32_t backend_kind;
    uint32_t width;
    uint32_t height;
    uint32_t flags;
    uint64_t profile_seed;
    uint64_t canvas_seed;
    uint64_t reserved[4];
} dp_canvas_surface_desc;

typedef struct dp_canvas_surface_info {
    uint32_t struct_size;
    int32_t backend_kind;
    uint32_t width;
    uint32_t height;
    uint32_t canonical_row_bytes;
    int32_t pixel_format;
    uint64_t profile_seed;
    uint64_t canvas_seed;
} dp_canvas_surface_info;

DP_CANVAS_API uint32_t dp_canvas_backend_abi_version(void);
DP_CANVAS_API const char *dp_canvas_backend_version(void);
DP_CANVAS_API const char *dp_canvas_status_string(int32_t status);

DP_CANVAS_API int32_t dp_canvas_surface_create(
    const dp_canvas_surface_desc *desc,
    dp_canvas_surface **out_surface);

/* A surface is thread-affine: resize, drawing, pixel I/O and free must run on
 * the same OS thread that called create. Wrong-thread calls return
 * DP_CANVAS_WRONG_THREAD and leave the surface untouched. */
DP_CANVAS_API int32_t dp_canvas_surface_free(dp_canvas_surface *surface);
DP_CANVAS_API int32_t dp_canvas_surface_get_info(
    dp_canvas_surface *surface,
    dp_canvas_surface_info *out_info);
DP_CANVAS_API int32_t dp_canvas_surface_resize(
    dp_canvas_surface *surface,
    uint32_t width,
    uint32_t height);

DP_CANVAS_API int32_t dp_canvas_surface_clear(
    dp_canvas_surface *surface,
    dp_canvas_rgba8 straight_rgba);

/* Floating-point fillRect using source-over compositing. */
/* Canvas-space coordinates stay floating-point until Skia rasterization. The
 * opacity is multiplied with straight_rgba.a without first quantizing it to
 * another 8-bit alpha value. */
DP_CANVAS_API int32_t dp_canvas_surface_fill_rect(
    dp_canvas_surface *surface,
    double x,
    double y,
    double width,
    double height,
    dp_canvas_rgba8 straight_rgba,
    double opacity);

/* clearRect intentionally uses non-antialiased Skia rasterization, matching
 * Chromium's Canvas 2D clear operation rather than alpha-blending transparent
 * black over the destination. */
DP_CANVAS_API int32_t dp_canvas_surface_clear_rect(
    dp_canvas_surface *surface,
    double x,
    double y,
    double width,
    double height);

/* Pixel I/O is strict: the complete rectangle must be inside the surface.
 * row_bytes may exceed width*4. Only width*4 bytes in each row are accessed.
 * The buffer representation is RGBA8 premultiplied sRGB (never BGRA). */
DP_CANVAS_API int32_t dp_canvas_surface_read_pixels(
    dp_canvas_surface *surface,
    uint32_t x,
    uint32_t y,
    uint32_t width,
    uint32_t height,
    uint8_t *dst,
    size_t dst_len,
    size_t dst_row_bytes);

DP_CANVAS_API int32_t dp_canvas_surface_write_pixels(
    dp_canvas_surface *surface,
    uint32_t x,
    uint32_t y,
    uint32_t width,
    uint32_t height,
    const uint8_t *src,
    size_t src_len,
    size_t src_row_bytes);

#ifdef __cplusplus
}
#endif

#endif
