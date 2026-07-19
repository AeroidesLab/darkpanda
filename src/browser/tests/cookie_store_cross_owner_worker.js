cookieStore.addEventListener('change', event => {
  postMessage({
    type: 'change',
    changed: event.changed.map(cookie => ({ name: cookie.name, value: cookie.value })),
    deleted: event.deleted.map(cookie => ({ name: cookie.name, value: cookie.value })),
  });
});

postMessage({ type: 'ready' });

onmessage = async event => {
  const command = event.data;
  if (command.type === 'set') {
    await cookieStore.set(command.name, command.value);
    postMessage({ type: 'set-done', name: command.name });
    return;
  }
  if (command.type === 'arm') {
    postMessage({ type: 'armed', name: command.name });
  }
};
