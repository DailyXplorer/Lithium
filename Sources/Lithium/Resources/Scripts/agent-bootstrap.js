// Runs at document start in every frame, in the lithium-agent content world, while agent access
// is on. The page's world sees none of it. It names the document with a random token, tells
// Lithium the frame exists (so agent.js can be called in it later), and notes every input that
// ever had type=password, from the first parsed byte: a "show password" toggle doesn't unlock it.
(() => {
  if (globalThis.lithiumAgentFrame) return;
  const bytes = crypto.getRandomValues(new Uint8Array(12));
  const token = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
  const passwords = new WeakSet();
  new MutationObserver((records) => {
    for (const record of records) {
      if (record.oldValue && record.oldValue.toLowerCase() === 'password') passwords.add(record.target);
    }
  }).observe(document, { attributes: true, attributeFilter: ['type'], attributeOldValue: true, subtree: true });
  globalThis.lithiumAgentFrame = { token, passwords };
  webkit.messageHandlers.lithiumAgent.postMessage({ token });
  // A page Back or Forward brings back from WebKit's cache runs no document-start script again.
  addEventListener('pageshow', (event) => {
    if (event.persisted) webkit.messageHandlers.lithiumAgent.postMessage({ token });
  });
})();
