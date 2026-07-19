const source = "postMessage('cross-global-blob-worker')";
const url = URL.createObjectURL(
  new Blob([source], { type: 'text/javascript' })
);

postMessage(url);
