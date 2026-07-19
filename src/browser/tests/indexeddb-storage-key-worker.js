(async () => {
  try {
    const infos = await indexedDB.databases();
    const request = indexedDB.open('storage-key-dedicated-worker');

    request.onerror = () => postMessage({error: request.error?.name || 'open'});
    request.onupgradeneeded = () => postMessage({error: 'unexpected-upgrade'});
    request.onsuccess = () => {
      const database = request.result;
      const transaction = database.transaction('records', 'readwrite');
      const store = transaction.objectStore('records');
      const read = store.get('page');
      let pageValue;

      read.onerror = () => postMessage({error: read.error?.name || 'read'});
      read.onsuccess = () => {
        pageValue = read.result;
        store.put('written-by-worker', 'worker');
      };
      transaction.onabort = () => postMessage({error: transaction.error?.name || 'abort'});
      transaction.oncomplete = () => {
        database.close();
        postMessage({
          listed: infos.some(info => info.name === 'storage-key-dedicated-worker'),
          pageValue,
          cmp: indexedDB.cmp(1, 2),
        });
      };
    };
  } catch (error) {
    postMessage({error: error?.name || String(error)});
  }
})();
