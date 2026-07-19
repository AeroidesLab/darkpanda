function measureStackDepth() {
  let depth = 0;
  function recurse() {
    'use strict';
    depth++;
    recurse();
  }

  try {
    recurse();
  } catch (error) {
    return {
      depth,
      name: error.name,
      message: error.message,
    };
  }

  throw new Error('recursive call unexpectedly returned');
}

function stableDepth(measure) {
  let result;
  for (let i = 0; i < 6; i++) result = measure();
  return result;
}

const initial = stableDepth(measureStackDepth);
importScripts('./stack-limit-imported.js');
const imported = stableDepth(self.importedStackDepth);

setTimeout(() => {
  const timer = stableDepth(measureStackDepth);
  postMessage({ phase: 'ready', initial, imported, timer });
}, 0);

self.onmessage = () => {
  postMessage({ phase: 'message', result: stableDepth(measureStackDepth) });
};
