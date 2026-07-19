const limit = 1 << 23;

function uleb32(value) {
  const bytes = [];
  do {
    let byte = value & 0x7f;
    value >>>= 7;
    if (value !== 0) byte |= 0x80;
    bytes.push(byte);
  } while (value !== 0);
  return bytes;
}

function customSectionModule(totalSize) {
  for (let width = 1; width <= 5; width++) {
    const sectionSize = totalSize - 9 - width;
    if (sectionSize < 1) continue;
    const encodedSize = uleb32(sectionSize);
    if (encodedSize.length !== width) continue;

    const bytes = new Uint8Array(totalSize);
    bytes.set([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);
    bytes[8] = 0;
    bytes.set(encodedSize, 9);
    return bytes;
  }
  throw new Error('could not encode requested WebAssembly wire size');
}

(async () => {
  try {
    let moduleErrorName = '';
    try {
      new WebAssembly.Module(new Uint8Array(limit + 1));
    } catch (error) {
      moduleErrorName = error.name;
    }

    const module = await WebAssembly.compile(customSectionModule(limit + 1));
    const instance = new WebAssembly.Instance(module);
    postMessage({
      moduleErrorName,
      instanceCreated: instance instanceof WebAssembly.Instance,
      fatal: '',
    });
  } catch (error) {
    postMessage({
      moduleErrorName: '',
      instanceCreated: false,
      fatal: `${error.name}: ${error.message}`,
    });
  }
})();
