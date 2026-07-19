const source = new ArrayBuffer(3);
const view = new Uint8Array(source);
view.set([7, 8, 9]);
const cloned = structuredClone({ source, view }, { transfer: [source] });

let invalid;
try {
  structuredClone(1, { transfer: [{}] });
} catch (error) {
  invalid = { name: error.name, message: error.message };
}

postMessage({
  sourceLength: source.byteLength,
  viewLength: view.byteLength,
  cloneBytes: Array.from(cloned.view),
  sameBuffer: cloned.source === cloned.view.buffer,
  invalid,
});
