const thrown = {
  get message() {
    postMessage('message getter');
    return 'author message';
  },
  get stack() {
    postMessage('stack getter');
    return 'author stack';
  },
  toString() {
    postMessage('toString');
    return 'accessor-object';
  },
};

throw thrown;
