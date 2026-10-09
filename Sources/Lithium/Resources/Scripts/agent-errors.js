// Runs in the lithium-agent world: the page's uncaught errors reach this world's listeners too, so
// nothing is needed in the page's world, where the page could see it.
(() => {
  // Once per document, so no error is posted twice.
  if (globalThis.lithiumAgentErrors) return;
  globalThis.lithiumAgentErrors = true;
  const post = (message) => {
    try { webkit.messageHandlers.lithiumAgent.postMessage({ console: message }); } catch (_) {}
  };
  const describe = (reason) => {
    try {
      // The page's Error isn't this world's, so instanceof can't tell one.
      if (reason && typeof reason === 'object' && typeof reason.message === 'string') return (reason.name || 'Error') + ': ' + reason.message;
      return typeof reason === 'string' ? reason : JSON.stringify(reason) ?? String(reason);
    } catch (_) {
      return '[unreadable]';
    }
  };
  // Cut here, as the page decides their size: the whole message would cross to Lithium first.
  addEventListener('error', (event) => {
    post({
      level: 'error', kind: 'exception', text: String(event.message).slice(0, 4096), source: event.filename ? String(event.filename).slice(0, 2048) : undefined,
      line: event.lineno || undefined, column: event.colno || undefined,
    });
  });
  addEventListener('unhandledrejection', (event) => {
    post({ level: 'error', kind: 'rejection', text: describe(event.reason).slice(0, 4096) });
  });
})();
