const ownStress = (async () => {
  for (let batch = 0; batch < 12; batch++) {
    const pending = [];
    for (let index = 0; index < 8; index++) {
      const expected = `worker-${batch}-${index}`;
      const url = URL.createObjectURL(new Blob([expected], { type: 'text/plain' }));
      const request = fetch(url).then(response => response.text());
      URL.revokeObjectURL(url);
      pending.push(request.then(actual => {
        if (actual !== expected) throw new Error(`worker own mismatch: ${actual}`);
      }));
    }
    await Promise.all(pending);
  }
})();

const crossGlobalSource = "postMessage('cross-global-blob-worker')";
const crossGlobalUrl = URL.createObjectURL(
  new Blob([crossGlobalSource], { type: 'text/javascript' }),
);
postMessage({ type: 'worker-url', url: crossGlobalUrl });

ownStress.then(
  () => postMessage({ type: 'worker-stress-done' }),
  error => postMessage({ type: 'error', error: String(error) }),
);

onmessage = async event => {
  if (event.data.type !== 'window-url') return;

  try {
    // fetch() resolves and retains the registry entry synchronously. Tell the
    // Window only after that point so it can race revoke against consumption.
    const request = fetch(event.data.url);
    postMessage({ type: 'window-fetch-started' });
    const actual = await (await request).text();
    if (actual !== event.data.expected) {
      throw new Error(`cross-global Window URL mismatch: ${actual}`);
    }
    postMessage({ type: 'window-url-done' });
  } catch (error) {
    postMessage({ type: 'error', error: String(error) });
  }
};
