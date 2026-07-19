let generation = 0;

function churn() {
  for (let index = 0; index < 32; index++) {
    const expected = `close-${generation}-${index}`;
    const url = URL.createObjectURL(new Blob([expected], { type: 'text/plain' }));
    fetch(url).then(response => response.text()).then(actual => {
      if (actual !== expected) throw new Error(`close mismatch: ${actual}`);
    }).catch(() => {
      // Page teardown is expected to abort transfers that have not settled.
    });
    URL.revokeObjectURL(url);
  }

  generation++;
  if (generation === 2) {
    postMessage({ type: 'armed', generation });
  }
  setTimeout(churn, 0);
}

churn();
