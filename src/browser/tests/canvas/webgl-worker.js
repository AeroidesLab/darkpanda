try {
  const gl = new OffscreenCanvas(8, 8).getContext('webgl');
  const info = gl.getExtension('WEBGL_debug_renderer_info');
  postMessage({
    ok: true,
    vendor: gl.getParameter(info.UNMASKED_VENDOR_WEBGL),
    width: gl.drawingBufferWidth,
  });
} catch (error) {
  postMessage({ok: false, error: `${error.name}: ${error.message}`});
}
