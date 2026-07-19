// Focused upper-layer Canvas backend tests. Keeping this root at `src/`
// allows Zig's module-path sandbox to include both the browser adapter and the
// standalone Rust C-ABI adapter without weakening import boundaries.
test {
    _ = @import("browser/canvas_backend/Surface.zig");
    _ = @import("browser/canvas_backend/Provider.zig");
}
