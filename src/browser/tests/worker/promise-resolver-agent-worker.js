self.onmessage = (event) => {
  const gate = new Int32Array(event.data.gate);

  // Publish readiness before blocking this owner thread. The queued microtask
  // cannot run until Atomics.wait returns and this message task completes.
  postMessage({ phase: 'armed' });
  queueMicrotask(() => postMessage({ phase: 'worker-microtask' }));

  const waitResult = Atomics.wait(gate, 0, 0, 4000);
  postMessage({ phase: 'released', waitResult });
};
