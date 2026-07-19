//! CPU-only Canvas backing store exposed through a small, versioned C ABI.
//!
//! The ABI intentionally stops below WebIDL/CanvasRenderingContext2D.  It can
//! therefore be loaded as an optional backend without making Rust or Skia part
//! of DarkPanda's public Zig ABI.

use skia_safe::{
    surfaces, AlphaType, BlendMode, Color, Color4f, ColorSpace, ColorType, ImageInfo, Paint, Rect,
    Surface,
};
use std::ffi::c_char;
use std::mem::size_of;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;
use std::thread::{self, ThreadId};

pub const ABI_VERSION: u32 = 2;
pub const MAX_DIMENSION: u32 = 32_768;
pub const MAX_SURFACE_BYTES: usize = 512 * 1024 * 1024;

const OK: i32 = 0;
const INVALID_ARGUMENT: i32 = 1;
const UNSUPPORTED_ABI: i32 = 2;
const UNSUPPORTED_BACKEND: i32 = 3;
const OUT_OF_MEMORY: i32 = 4;
const SIZE_OVERFLOW: i32 = 5;
const OUT_OF_BOUNDS: i32 = 6;
const BUFFER_TOO_SMALL: i32 = 7;
const WRONG_THREAD: i32 = 8;
const BACKEND_FAILURE: i32 = 9;
const RUST_PANIC: i32 = 10;

const BACKEND_SKIA: i32 = 1;
const BACKEND_FAKE: i32 = 2;
const PIXEL_RGBA8_PREMUL_SRGB: i32 = 1;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Rgba8 {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct SurfaceDesc {
    pub struct_size: u32,
    pub abi_version: u32,
    pub backend_kind: i32,
    pub width: u32,
    pub height: u32,
    pub flags: u32,
    pub profile_seed: u64,
    pub canvas_seed: u64,
    pub reserved: [u64; 4],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SurfaceInfo {
    pub struct_size: u32,
    pub backend_kind: i32,
    pub width: u32,
    pub height: u32,
    pub canonical_row_bytes: u32,
    pub pixel_format: i32,
    pub profile_seed: u64,
    pub canvas_seed: u64,
}

struct FakeSurface {
    pixels: Vec<u8>,
}

enum Backend {
    Skia(Option<Surface>),
    Fake(FakeSurface),
}

/// Opaque outside this crate. Every operation is restricted to `owner`.
pub struct CanvasSurface {
    owner: ThreadId,
    width: u32,
    height: u32,
    profile_seed: u64,
    canvas_seed: u64,
    backend: Backend,
}

impl CanvasSurface {
    fn create(desc: SurfaceDesc) -> Result<Self, i32> {
        validate_dimensions(desc.width, desc.height)?;
        if desc.flags != 0 || desc.reserved.iter().any(|v| *v != 0) {
            return Err(INVALID_ARGUMENT);
        }

        let backend = match desc.backend_kind {
            BACKEND_SKIA => Backend::Skia(make_skia_surface(desc.width, desc.height)?),
            BACKEND_FAKE => Backend::Fake(FakeSurface {
                pixels: make_fake_pixels(
                    desc.width,
                    desc.height,
                    desc.profile_seed,
                    desc.canvas_seed,
                )?,
            }),
            _ => return Err(UNSUPPORTED_BACKEND),
        };

        Ok(Self {
            owner: thread::current().id(),
            width: desc.width,
            height: desc.height,
            profile_seed: desc.profile_seed,
            canvas_seed: desc.canvas_seed,
            backend,
        })
    }

    fn check_owner(&self) -> Result<(), i32> {
        if self.owner == thread::current().id() {
            Ok(())
        } else {
            Err(WRONG_THREAD)
        }
    }

    fn backend_kind(&self) -> i32 {
        match self.backend {
            Backend::Skia(_) => BACKEND_SKIA,
            Backend::Fake(_) => BACKEND_FAKE,
        }
    }

    fn resize(&mut self, width: u32, height: u32) -> Result<(), i32> {
        validate_dimensions(width, height)?;

        // Build the replacement before dropping the old backing store. A
        // failed allocation therefore leaves the observable surface intact.
        let replacement = match self.backend {
            Backend::Skia(_) => Backend::Skia(make_skia_surface(width, height)?),
            Backend::Fake(_) => Backend::Fake(FakeSurface {
                pixels: make_fake_pixels(width, height, self.profile_seed, self.canvas_seed)?,
            }),
        };
        self.backend = replacement;
        self.width = width;
        self.height = height;
        Ok(())
    }

    fn clear(&mut self, color: Rgba8) -> Result<(), i32> {
        match &mut self.backend {
            Backend::Skia(surface) => {
                if let Some(surface) = surface {
                    surface.canvas().clear(color4f(color));
                }
            }
            Backend::Fake(surface) => {
                let pixel = premultiply(color);
                for dst in surface.pixels.chunks_exact_mut(4) {
                    dst.copy_from_slice(&pixel);
                }
            }
        }
        Ok(())
    }

    fn fill_rect(
        &mut self,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        color: Rgba8,
        opacity: f64,
    ) -> Result<(), i32> {
        let rect = normalized_rect(x, y, width, height)?;
        if rect.is_none() || opacity == 0.0 || color.a == 0 || self.width == 0 || self.height == 0 {
            return Ok(());
        }
        if !opacity.is_finite() || !(0.0..=1.0).contains(&opacity) {
            return Err(INVALID_ARGUMENT);
        }
        let (left, top, right, bottom) = rect.unwrap();

        match &mut self.backend {
            Backend::Skia(surface) => {
                if let Some(surface) = surface {
                    // Chromium's Canvas path begins from an 8-bit SkColor,
                    // then applies globalAlpha. Going straight through a
                    // Color4f rounds half-channel premultiplication upward and
                    // is observably one byte off at getImageData().
                    let mut paint = Paint::default();
                    paint.set_color(Color::from_argb(color.a, color.r, color.g, color.b));
                    paint.set_alpha_f(color.a as f32 * opacity as f32 / 255.0);
                    paint.set_blend_mode(BlendMode::SrcOver);
                    paint.set_anti_alias(true);
                    surface.canvas().draw_rect(
                        Rect::new(left as f32, top as f32, right as f32, bottom as f32),
                        &paint,
                    );
                }
            }
            Backend::Fake(surface) => {
                fill_fake_rect(
                    &mut surface.pixels,
                    self.width,
                    self.height,
                    left,
                    top,
                    right,
                    bottom,
                    color,
                    opacity,
                );
            }
        }
        Ok(())
    }

    fn clear_rect(&mut self, x: f64, y: f64, width: f64, height: f64) -> Result<(), i32> {
        let Some((left, top, right, bottom)) = normalized_rect(x, y, width, height)? else {
            return Ok(());
        };
        if self.width == 0 || self.height == 0 {
            return Ok(());
        }

        match &mut self.backend {
            Backend::Skia(surface) => {
                if let Some(surface) = surface {
                    let mut paint = Paint::default();
                    paint.set_blend_mode(BlendMode::Clear);
                    paint.set_anti_alias(false);
                    surface.canvas().draw_rect(
                        Rect::new(left as f32, top as f32, right as f32, bottom as f32),
                        &paint,
                    );
                }
            }
            Backend::Fake(surface) => clear_fake_rect(
                &mut surface.pixels,
                self.width,
                self.height,
                left,
                top,
                right,
                bottom,
            ),
        }
        Ok(())
    }

    fn read_pixels(
        &mut self,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        dst: &mut [u8],
        row_bytes: usize,
    ) -> Result<(), i32> {
        validate_rect_and_buffer(
            self.width,
            self.height,
            x,
            y,
            width,
            height,
            dst.len(),
            row_bytes,
        )?;
        if width == 0 || height == 0 {
            return Ok(());
        }

        let tight = width as usize * 4;
        match &mut self.backend {
            Backend::Skia(Some(surface)) => {
                let info = rgba_info(width, 1);
                for row in 0..height as usize {
                    let offset = row * row_bytes;
                    if !surface.read_pixels(
                        &info,
                        &mut dst[offset..offset + tight],
                        tight,
                        (x as i32, y as i32 + row as i32),
                    ) {
                        return Err(BACKEND_FAILURE);
                    }
                }
            }
            Backend::Skia(None) => return Err(BACKEND_FAILURE),
            Backend::Fake(surface) => {
                let source_row_bytes = self.width as usize * 4;
                for row in 0..height as usize {
                    let src_offset = (y as usize + row) * source_row_bytes + x as usize * 4;
                    let dst_offset = row * row_bytes;
                    dst[dst_offset..dst_offset + tight]
                        .copy_from_slice(&surface.pixels[src_offset..src_offset + tight]);
                }
            }
        }
        Ok(())
    }

    fn write_pixels(
        &mut self,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        src: &[u8],
        row_bytes: usize,
    ) -> Result<(), i32> {
        validate_rect_and_buffer(
            self.width,
            self.height,
            x,
            y,
            width,
            height,
            src.len(),
            row_bytes,
        )?;
        if width == 0 || height == 0 {
            return Ok(());
        }

        let tight = width as usize * 4;
        match &mut self.backend {
            Backend::Skia(Some(surface)) => {
                let info = rgba_info(width, 1);
                for row in 0..height as usize {
                    let offset = row * row_bytes;
                    if !surface.canvas().write_pixels(
                        &info,
                        &src[offset..offset + tight],
                        tight,
                        (x as i32, y as i32 + row as i32),
                    ) {
                        return Err(BACKEND_FAILURE);
                    }
                }
            }
            Backend::Skia(None) => return Err(BACKEND_FAILURE),
            Backend::Fake(surface) => {
                let destination_row_bytes = self.width as usize * 4;
                for row in 0..height as usize {
                    let src_offset = row * row_bytes;
                    let dst_offset = (y as usize + row) * destination_row_bytes + x as usize * 4;
                    surface.pixels[dst_offset..dst_offset + tight]
                        .copy_from_slice(&src[src_offset..src_offset + tight]);
                }
            }
        }
        Ok(())
    }
}

fn validate_dimensions(width: u32, height: u32) -> Result<usize, i32> {
    if width > MAX_DIMENSION || height > MAX_DIMENSION {
        return Err(SIZE_OVERFLOW);
    }
    let row_bytes = (width as usize).checked_mul(4).ok_or(SIZE_OVERFLOW)?;
    let bytes = row_bytes
        .checked_mul(height as usize)
        .ok_or(SIZE_OVERFLOW)?;
    if bytes > MAX_SURFACE_BYTES {
        return Err(SIZE_OVERFLOW);
    }
    Ok(bytes)
}

fn validate_rect_and_buffer(
    surface_width: u32,
    surface_height: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    buffer_len: usize,
    row_bytes: usize,
) -> Result<(), i32> {
    if x.checked_add(width)
        .filter(|end| *end <= surface_width)
        .is_none()
        || y.checked_add(height)
            .filter(|end| *end <= surface_height)
            .is_none()
    {
        return Err(OUT_OF_BOUNDS);
    }

    let tight = (width as usize).checked_mul(4).ok_or(SIZE_OVERFLOW)?;
    if height != 0 && row_bytes < tight {
        return Err(BUFFER_TOO_SMALL);
    }
    let required = if width == 0 || height == 0 {
        0
    } else {
        row_bytes
            .checked_mul(height as usize - 1)
            .and_then(|prefix| prefix.checked_add(tight))
            .ok_or(SIZE_OVERFLOW)?
    };
    if buffer_len < required || required > isize::MAX as usize {
        return Err(BUFFER_TOO_SMALL);
    }
    Ok(())
}

fn normalized_rect(
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> Result<Option<(f64, f64, f64, f64)>, i32> {
    if !x.is_finite() || !y.is_finite() || !width.is_finite() || !height.is_finite() {
        return Err(INVALID_ARGUMENT);
    }
    if width == 0.0 || height == 0.0 {
        return Ok(None);
    }
    let x2 = x + width;
    let y2 = y + height;
    if !x2.is_finite() || !y2.is_finite() {
        return Err(INVALID_ARGUMENT);
    }
    Ok(Some((x.min(x2), y.min(y2), x.max(x2), y.max(y2))))
}

fn rgba_info(width: u32, height: u32) -> ImageInfo {
    ImageInfo::new(
        (width as i32, height as i32),
        ColorType::RGBA8888,
        AlphaType::Premul,
        ColorSpace::new_srgb(),
    )
}

fn make_skia_surface(width: u32, height: u32) -> Result<Option<Surface>, i32> {
    if width == 0 || height == 0 {
        return Ok(None);
    }
    let info = rgba_info(width, height);
    surfaces::raster(&info, Some(width as usize * 4), None)
        .map(Some)
        .ok_or(BACKEND_FAILURE)
}

fn color4f(color: Rgba8) -> Color4f {
    const SCALE: f32 = 1.0 / 255.0;
    Color4f::new(
        color.r as f32 * SCALE,
        color.g as f32 * SCALE,
        color.b as f32 * SCALE,
        color.a as f32 * SCALE,
    )
}

fn premultiply(color: Rgba8) -> [u8; 4] {
    fn channel(value: u8, alpha: u8) -> u8 {
        ((value as u16 * alpha as u16 + 127) / 255) as u8
    }
    [
        channel(color.r, color.a),
        channel(color.g, color.a),
        channel(color.b, color.a),
        color.a,
    ]
}

fn source_over(dst: &mut [u8], source: [u8; 4]) {
    let inverse_alpha = 255 - source[3] as u16;
    for channel in 0..3 {
        let kept = (dst[channel] as u16 * inverse_alpha + 127) / 255;
        dst[channel] = (source[channel] as u16 + kept).min(255) as u8;
    }
    let kept_alpha = (dst[3] as u16 * inverse_alpha + 127) / 255;
    dst[3] = (source[3] as u16 + kept_alpha).min(255) as u8;
}

#[allow(clippy::too_many_arguments)]
fn fill_fake_rect(
    pixels: &mut [u8],
    surface_width: u32,
    surface_height: u32,
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,
    color: Rgba8,
    opacity: f64,
) {
    let clipped_left = left.max(0.0).min(surface_width as f64);
    let clipped_top = top.max(0.0).min(surface_height as f64);
    let clipped_right = right.max(0.0).min(surface_width as f64);
    let clipped_bottom = bottom.max(0.0).min(surface_height as f64);
    if clipped_right <= clipped_left || clipped_bottom <= clipped_top {
        return;
    }

    let row_bytes = surface_width as usize * 4;
    for row in clipped_top.floor() as usize..clipped_bottom.ceil() as usize {
        let y_coverage =
            (clipped_bottom.min(row as f64 + 1.0) - clipped_top.max(row as f64)).clamp(0.0, 1.0);
        for column in clipped_left.floor() as usize..clipped_right.ceil() as usize {
            let x_coverage = (clipped_right.min(column as f64 + 1.0)
                - clipped_left.max(column as f64))
            .clamp(0.0, 1.0);
            let effective_alpha =
                ((color.a as f64 * opacity * x_coverage * y_coverage).round()) as u8;
            if effective_alpha == 0 {
                continue;
            }
            let source = premultiply(Rgba8 {
                r: color.r,
                g: color.g,
                b: color.b,
                a: effective_alpha,
            });
            let offset = row * row_bytes + column * 4;
            source_over(&mut pixels[offset..offset + 4], source);
        }
    }
}

fn clear_fake_rect(
    pixels: &mut [u8],
    surface_width: u32,
    surface_height: u32,
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,
) {
    // Canvas clearRect is not edge-antialiased. Sampling pixel centres also
    // gives the same half-pixel inclusion threshold as Skia/Chromium.
    let clipped_left = left.max(0.0).min(surface_width as f64);
    let clipped_top = top.max(0.0).min(surface_height as f64);
    let clipped_right = right.max(0.0).min(surface_width as f64);
    let clipped_bottom = bottom.max(0.0).min(surface_height as f64);
    if clipped_right <= clipped_left || clipped_bottom <= clipped_top {
        return;
    }
    let row_bytes = surface_width as usize * 4;
    for row in clipped_top.floor() as usize..clipped_bottom.ceil() as usize {
        let centre_y = row as f64 + 0.5;
        if centre_y < clipped_top || centre_y >= clipped_bottom {
            continue;
        }
        for column in clipped_left.floor() as usize..clipped_right.ceil() as usize {
            let centre_x = column as f64 + 0.5;
            if centre_x < clipped_left || centre_x >= clipped_right {
                continue;
            }
            let offset = row * row_bytes + column * 4;
            pixels[offset..offset + 4].fill(0);
        }
    }
}

fn make_fake_pixels(
    width: u32,
    height: u32,
    profile_seed: u64,
    canvas_seed: u64,
) -> Result<Vec<u8>, i32> {
    let len = validate_dimensions(width, height)?;
    let mut pixels = Vec::new();
    pixels.try_reserve_exact(len).map_err(|_| OUT_OF_MEMORY)?;
    pixels.resize(len, 0);

    // Coordinate-based generation makes output independent of read call
    // boundaries and call order. Re-creating or resizing back to the same
    // dimensions produces exactly the same baseline image.
    let seed = splitmix64(profile_seed ^ canvas_seed.rotate_left(29) ^ 0x4450_4341_4e56_4153);
    for row in 0..height as usize {
        for column in 0..width as usize {
            let coordinate = ((row as u64) << 32) | column as u64;
            let value = splitmix64(seed ^ coordinate.wrapping_mul(0x9e37_79b9_7f4a_7c15));
            let alpha = (value >> 56) as u8;
            let straight = Rgba8 {
                r: value as u8,
                g: (value >> 8) as u8,
                b: (value >> 16) as u8,
                a: alpha,
            };
            let offset = (row * width as usize + column) * 4;
            pixels[offset..offset + 4].copy_from_slice(&premultiply(straight));
        }
    }
    Ok(pixels)
}

fn splitmix64(mut value: u64) -> u64 {
    value = value.wrapping_add(0x9e37_79b9_7f4a_7c15);
    value = (value ^ (value >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    value = (value ^ (value >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    value ^ (value >> 31)
}

fn ffi_status(f: impl FnOnce() -> Result<(), i32>) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => OK,
        Ok(Err(status)) => status,
        Err(_) => RUST_PANIC,
    }
}

unsafe fn surface_mut<'a>(surface: *mut CanvasSurface) -> Result<&'a mut CanvasSurface, i32> {
    // SAFETY: The caller owns the validity obligation of an opaque C handle.
    // Null is still rejected before dereferencing.
    unsafe { surface.as_mut() }.ok_or(INVALID_ARGUMENT)
}

unsafe fn desc_copy(desc: *const SurfaceDesc) -> Result<SurfaceDesc, i32> {
    if desc.is_null() {
        return Err(INVALID_ARGUMENT);
    }
    // Read only the first field until the caller-provided size is known.
    let caller_size = unsafe { ptr::read(desc.cast::<u32>()) } as usize;
    if caller_size < size_of::<SurfaceDesc>() {
        return Err(INVALID_ARGUMENT);
    }
    Ok(unsafe { ptr::read(desc) })
}

unsafe fn bytes_mut<'a>(ptr: *mut u8, len: usize) -> Result<&'a mut [u8], i32> {
    if len == 0 {
        return Ok(&mut []);
    }
    if ptr.is_null() || len > isize::MAX as usize {
        return Err(INVALID_ARGUMENT);
    }
    Ok(unsafe { slice::from_raw_parts_mut(ptr, len) })
}

unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> Result<&'a [u8], i32> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() || len > isize::MAX as usize {
        return Err(INVALID_ARGUMENT);
    }
    Ok(unsafe { slice::from_raw_parts(ptr, len) })
}

#[no_mangle]
pub extern "C" fn dp_canvas_backend_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub extern "C" fn dp_canvas_backend_version() -> *const c_char {
    b"darkpanda-canvas-backend/0.1.0 rust-skia/0.99.0\0"
        .as_ptr()
        .cast()
}

#[no_mangle]
pub extern "C" fn dp_canvas_status_string(status: i32) -> *const c_char {
    let text: &'static [u8] = match status {
        OK => b"ok\0",
        INVALID_ARGUMENT => b"invalid argument\0",
        UNSUPPORTED_ABI => b"unsupported ABI\0",
        UNSUPPORTED_BACKEND => b"unsupported backend\0",
        OUT_OF_MEMORY => b"out of memory\0",
        SIZE_OVERFLOW => b"size overflow\0",
        OUT_OF_BOUNDS => b"out of bounds\0",
        BUFFER_TOO_SMALL => b"buffer too small\0",
        WRONG_THREAD => b"wrong thread\0",
        BACKEND_FAILURE => b"backend failure\0",
        RUST_PANIC => b"Rust panic\0",
        _ => b"unknown status\0",
    };
    text.as_ptr().cast()
}

#[no_mangle]
pub unsafe extern "C" fn dp_canvas_surface_create(
    desc: *const SurfaceDesc,
    out_surface: *mut *mut CanvasSurface,
) -> i32 {
    ffi_status(|| {
        if out_surface.is_null() {
            return Err(INVALID_ARGUMENT);
        }
        unsafe { ptr::write(out_surface, ptr::null_mut()) };
        let desc = unsafe { desc_copy(desc)? };
        if desc.abi_version != ABI_VERSION {
            return Err(UNSUPPORTED_ABI);
        }
        let surface = CanvasSurface::create(desc)?;
        unsafe { ptr::write(out_surface, Box::into_raw(Box::new(surface))) };
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn dp_canvas_surface_free(surface: *mut CanvasSurface) -> i32 {
    ffi_status(|| {
        if surface.is_null() {
            return Ok(());
        }
        let borrowed = unsafe { &*surface };
        borrowed.check_owner()?;
        drop(unsafe { Box::from_raw(surface) });
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn dp_canvas_surface_get_info(
    surface: *mut CanvasSurface,
    out_info: *mut SurfaceInfo,
) -> i32 {
    ffi_status(|| {
        let surface = unsafe { surface_mut(surface)? };
        surface.check_owner()?;
        if out_info.is_null() {
            return Err(INVALID_ARGUMENT);
        }
        let caller_size = unsafe { ptr::read(out_info.cast::<u32>()) } as usize;
        if caller_size < size_of::<SurfaceInfo>() {
            return Err(INVALID_ARGUMENT);
        }
        let row_bytes = surface.width.checked_mul(4).ok_or(SIZE_OVERFLOW)?;
        unsafe {
            ptr::write(
                out_info,
                SurfaceInfo {
                    struct_size: size_of::<SurfaceInfo>() as u32,
                    backend_kind: surface.backend_kind(),
                    width: surface.width,
                    height: surface.height,
                    canonical_row_bytes: row_bytes,
                    pixel_format: PIXEL_RGBA8_PREMUL_SRGB,
                    profile_seed: surface.profile_seed,
                    canvas_seed: surface.canvas_seed,
                },
            )
        };
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn dp_canvas_surface_resize(
    surface: *mut CanvasSurface,
    width: u32,
    height: u32,
) -> i32 {
    ffi_status(|| {
        let surface = unsafe { surface_mut(surface)? };
        surface.check_owner()?;
        surface.resize(width, height)
    })
}

#[no_mangle]
pub unsafe extern "C" fn dp_canvas_surface_clear(
    surface: *mut CanvasSurface,
    straight_rgba: Rgba8,
) -> i32 {
    ffi_status(|| {
        let surface = unsafe { surface_mut(surface)? };
        surface.check_owner()?;
        surface.clear(straight_rgba)
    })
}

#[no_mangle]
pub unsafe extern "C" fn dp_canvas_surface_fill_rect(
    surface: *mut CanvasSurface,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    straight_rgba: Rgba8,
    opacity: f64,
) -> i32 {
    ffi_status(|| {
        let surface = unsafe { surface_mut(surface)? };
        surface.check_owner()?;
        surface.fill_rect(x, y, width, height, straight_rgba, opacity)
    })
}

#[no_mangle]
pub unsafe extern "C" fn dp_canvas_surface_clear_rect(
    surface: *mut CanvasSurface,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> i32 {
    ffi_status(|| {
        let surface = unsafe { surface_mut(surface)? };
        surface.check_owner()?;
        surface.clear_rect(x, y, width, height)
    })
}

#[no_mangle]
pub unsafe extern "C" fn dp_canvas_surface_read_pixels(
    surface: *mut CanvasSurface,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    dst: *mut u8,
    dst_len: usize,
    dst_row_bytes: usize,
) -> i32 {
    ffi_status(|| {
        let surface = unsafe { surface_mut(surface)? };
        surface.check_owner()?;
        let dst = unsafe { bytes_mut(dst, dst_len)? };
        surface.read_pixels(x, y, width, height, dst, dst_row_bytes)
    })
}

#[no_mangle]
pub unsafe extern "C" fn dp_canvas_surface_write_pixels(
    surface: *mut CanvasSurface,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    src: *const u8,
    src_len: usize,
    src_row_bytes: usize,
) -> i32 {
    ffi_status(|| {
        let surface = unsafe { surface_mut(surface)? };
        surface.check_owner()?;
        let src = unsafe { bytes(src, src_len)? };
        surface.write_pixels(x, y, width, height, src, src_row_bytes)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn descriptor(kind: i32, profile_seed: u64, canvas_seed: u64) -> SurfaceDesc {
        SurfaceDesc {
            struct_size: size_of::<SurfaceDesc>() as u32,
            abi_version: ABI_VERSION,
            backend_kind: kind,
            width: 4,
            height: 3,
            flags: 0,
            profile_seed,
            canvas_seed,
            reserved: [0; 4],
        }
    }

    unsafe fn create(kind: i32, profile_seed: u64, canvas_seed: u64) -> *mut CanvasSurface {
        let desc = descriptor(kind, profile_seed, canvas_seed);
        let mut surface = ptr::null_mut();
        assert_eq!(unsafe { dp_canvas_surface_create(&desc, &mut surface) }, OK);
        assert!(!surface.is_null());
        surface
    }

    unsafe fn read_all(surface: *mut CanvasSurface) -> Vec<u8> {
        let mut pixels = vec![0; 4 * 3 * 4];
        assert_eq!(
            unsafe {
                dp_canvas_surface_read_pixels(
                    surface,
                    0,
                    0,
                    4,
                    3,
                    pixels.as_mut_ptr(),
                    pixels.len(),
                    16,
                )
            },
            OK
        );
        pixels
    }

    #[test]
    fn fake_is_stable_and_seeded() {
        unsafe {
            let first = create(BACKEND_FAKE, 11, 22);
            let second = create(BACKEND_FAKE, 11, 22);
            let different = create(BACKEND_FAKE, 11, 23);
            let baseline = read_all(first);
            assert_eq!(baseline, read_all(first));
            assert_eq!(baseline, read_all(second));
            assert_ne!(baseline, read_all(different));

            assert_eq!(dp_canvas_surface_resize(first, 2, 2), OK);
            assert_eq!(dp_canvas_surface_resize(first, 4, 3), OK);
            assert_eq!(baseline, read_all(first));

            assert_eq!(dp_canvas_surface_free(first), OK);
            assert_eq!(dp_canvas_surface_free(second), OK);
            assert_eq!(dp_canvas_surface_free(different), OK);
        }
    }

    #[test]
    fn both_backends_expose_premultiplied_rgba() {
        for kind in [BACKEND_SKIA, BACKEND_FAKE] {
            unsafe {
                let surface = create(kind, 1, 2);
                assert_eq!(
                    dp_canvas_surface_clear(
                        surface,
                        Rgba8 {
                            r: 255,
                            g: 0,
                            b: 0,
                            a: 128,
                        },
                    ),
                    OK
                );
                let pixels = read_all(surface);
                for pixel in pixels.chunks_exact(4) {
                    assert_eq!(pixel, [128, 0, 0, 128]);
                }

                let written = [7, 6, 5, 8];
                assert_eq!(
                    dp_canvas_surface_write_pixels(
                        surface,
                        2,
                        1,
                        1,
                        1,
                        written.as_ptr(),
                        written.len(),
                        4,
                    ),
                    OK
                );
                let pixels = read_all(surface);
                assert_eq!(&pixels[24..28], &written);
                assert_eq!(dp_canvas_surface_free(surface), OK);
            }
        }
    }

    #[test]
    fn rejects_cross_thread_use_without_consuming_handle() {
        unsafe {
            let surface = create(BACKEND_FAKE, 1, 2);
            let address = surface as usize;
            let status = std::thread::spawn(move || {
                dp_canvas_surface_clear(
                    address as *mut CanvasSurface,
                    Rgba8 {
                        r: 0,
                        g: 0,
                        b: 0,
                        a: 0,
                    },
                )
            })
            .join()
            .unwrap();
            assert_eq!(status, WRONG_THREAD);
            assert_eq!(dp_canvas_surface_free(surface), OK);
        }
    }
}
