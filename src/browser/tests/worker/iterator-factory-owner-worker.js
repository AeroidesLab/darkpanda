const headers = new Headers([
  ['x-owner', 'dedicated-worker'],
]);

postMessage({
  entries: Array.from(headers.entries()),
});
