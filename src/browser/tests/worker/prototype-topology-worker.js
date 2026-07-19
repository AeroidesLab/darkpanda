const own = (object, key) =>
  Object.prototype.hasOwnProperty.call(object, key);

const dedicatedPrototype = Object.getPrototypeOf(self);
const workerPrototype = Object.getPrototypeOf(dedicatedPrototype);

postMessage({
  nodeIsAbsent: typeof Node === 'undefined',
  workerGlobalScopeIsDefined: typeof WorkerGlobalScope !== 'undefined',
  dedicatedWorkerGlobalScopeIsDefined:
    typeof DedicatedWorkerGlobalScope !== 'undefined',
  selfIsDedicatedWorkerGlobalScope:
    self instanceof DedicatedWorkerGlobalScope,
  selfIsWorkerGlobalScope: self instanceof WorkerGlobalScope,
  constructorName: self.constructor.name,
  selfIsGlobalThis: self === globalThis,
  requestAnimationFrameIsFunction:
    typeof self.requestAnimationFrame === 'function',
  cancelAnimationFrameIsFunction:
    typeof self.cancelAnimationFrame === 'function',
  globalPrototypeIsDedicated:
    dedicatedPrototype === DedicatedWorkerGlobalScope.prototype,
  workerPrototypeIsWorker:
    workerPrototype === WorkerGlobalScope.prototype,
  eventTargetPrototypeIsNext:
    Object.getPrototypeOf(workerPrototype) === EventTarget.prototype,
  dedicatedTag: Object.prototype.toString.call(dedicatedPrototype),
  dedicatedKeys: Reflect.ownKeys(dedicatedPrototype).map(key =>
    typeof key === 'symbol' ? key.toString() : key
  ),
  temporary: DedicatedWorkerGlobalScope.TEMPORARY,
  persistent: DedicatedWorkerGlobalScope.PERSISTENT,
  constantsOnPrototype:
    own(dedicatedPrototype, 'TEMPORARY') &&
    own(dedicatedPrototype, 'PERSISTENT'),
  constantsOnGlobal:
    own(self, 'TEMPORARY') || own(self, 'PERSISTENT'),
  postMessageOnGlobal: own(self, 'postMessage'),
  postMessageOnDedicatedPrototype: own(dedicatedPrototype, 'postMessage'),
  importScriptsOnGlobal: own(self, 'importScripts'),
  importScriptsOnWorkerPrototype: own(workerPrototype, 'importScripts'),
  addEventListenerOnGlobal: own(self, 'addEventListener'),
  addEventListenerOnEventTargetPrototype:
    own(EventTarget.prototype, 'addEventListener'),
});
