function importedStackDepth() {
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

self.importedStackDepth = importedStackDepth;
