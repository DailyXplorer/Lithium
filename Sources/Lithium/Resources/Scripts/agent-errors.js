// Runs at document start in the lithium-agent world, in every frame of a tab an agent uses. The
// page's uncaught errors and unhandled rejections reach this world's listeners too, with file and
// line, so they need nothing in the page's world, where the page could see it.
(() => {
  // Once per document, so no error is posted twice when capture reaches a frame twice. This
  // world's globals are out of the page's sight.
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
  addEventListener('error', (event) => {
    post({ level: 'error', kind: 'exception', text: String(event.message), source: event.filename || undefined, line: event.lineno || undefined, column: event.colno || undefined });
  });
  addEventListener('unhandledrejection', (event) => {
    post({ level: 'error', kind: 'rejection', text: describe(event.reason).slice(0, 4096) });
  });
})();
