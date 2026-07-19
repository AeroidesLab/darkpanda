importScripts("v8_recursion_shapes.js?rev=2026-07-15-1");

self.onmessage = event => {
  try {
    self.postMessage({
      ok: true,
      probe: self.__runV8RecursionShapes(event.data && event.data.rounds),
    });
  } catch (error) {
    self.postMessage({
      ok: false,
      error: {
        name: error && error.name ? String(error.name) : "Error",
        message: error && error.message ? String(error.message) : String(error),
      },
    });
  }
};
