const capture = callback => {
  try {
    return {value: callback()};
  } catch (error) {
    return {error: {name: error.name, message: error.message}};
  }
};

const href = location.href;
if (href.includes('nullish=1')) {
  trustedTypes.createPolicy('default', {
    createScript() {
      return null;
    },
  });
}

const trustedTypesEval = href.includes('policy=tteval');
postMessage({
  eval: capture(() => eval(trustedTypesEval ? '6' : '4')),
  timer: trustedTypesEval
    ? capture(() => setTimeout('globalThis.workerStringTimer = 1', 0))
    : null,
});
