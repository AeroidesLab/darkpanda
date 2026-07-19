// Generic cross-origin classic-script fixture. A classic script executes in
// the embedding document's realm even when its response URL is cross-origin;
// only uncaught error reporting is sanitized when CORS is not enabled.
window.__securityCrossOriginClassic = {
  documentURL: document.URL,
  origin: location.origin,
  currentScriptURL: document.currentScript && document.currentScript.src,
  secret: document.documentElement.dataset.securityBoundarySecret,
  throwSynchronously() {
    throw new Error("cross-origin-sync-boom");
  },
};

setTimeout(() => {
  throw new Error("cross-origin-async-boom");
}, 50);
