const capture = callback => {
  try {
    return callback();
  } catch (error) {
    return {name: error.name, message: error.message};
  }
};

const missing = eval('6');
const calls = [];
trustedTypes.createPolicy('default', {
  createScript(input, type, sink) {
    calls.push([input, type, sink]);
    if (input === '2') return '3';
    if (input === '4') return null;
    if (input === '5') throw new RangeError('worker author sentinel');
    return input;
  },
});

postMessage({
  missing,
  same: eval('1'),
  changed: capture(() => eval('2')),
  nullish: eval('4'),
  thrown: capture(() => eval('5')),
  functionValue: Function('return 7')(),
  calls,
});
