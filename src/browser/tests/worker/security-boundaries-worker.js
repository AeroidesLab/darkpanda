const describeError = error => ({
  name: error?.name,
  message: error?.message,
  code: error?.code,
  constructor: error?.constructor?.name,
  isDOMException: error instanceof DOMException,
  tag: Object.prototype.toString.call(error),
  ownKeys: Reflect.ownKeys(error).map(String),
  stackFirst: String(error?.stack).split('\n')[0],
});

const capture = callback => {
  try {
    callback();
    return { threw: false };
  } catch (error) {
    return { threw: true, error: describeError(error) };
  }
};

const prototypeChain = [];
for (let value = self; value; value = Object.getPrototypeOf(value)) {
  prototypeChain.push(value.constructor?.name ?? null);
}

postMessage({
  types: Object.fromEntries([
    'window',
    'document',
    'parent',
    'top',
    'frames',
    'Window',
    'Document',
    'HTMLElement',
    'navigator',
    'location',
    'importScripts',
    'postMessage',
    'close',
    'Worker',
    'WorkerGlobalScope',
    'DedicatedWorkerGlobalScope',
    'SharedArrayBuffer',
    'Atomics',
    'crossOriginIsolated',
  ].map(name => [name, typeof globalThis[name]])),
  selfIsGlobalThis: self === globalThis,
  prototypeChain,
  forbiddenReferences: Object.fromEntries([
    'window',
    'document',
    'parent',
    'top',
    'frames',
  ].map(name => [name, capture(() => eval(name))])),
  crossOriginIsolated,
  isSecureContext,
  structuredCloneSelf: capture(() => structuredClone(self)),
});
