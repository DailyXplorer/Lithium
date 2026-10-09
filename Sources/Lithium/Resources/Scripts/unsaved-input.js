// Tells Lithium once per document that leaving it may lose the user's work, so an idle tab isn't
// put to sleep. WebKit only lets a `beforeunload` handler ask after the user interacted, so a
// handler alone (ads and analytics add them) keeps no tab awake.
(() => {
  // Taken now, before the page can replace them.
  const channel = globalThis.webkit?.messageHandlers?.lithiumUnsavedInput;
  if (!channel) return;
  const post = channel.postMessage.bind(channel);
  const send = () => { try { post(null); } catch {} };
  const apply = Reflect.apply;
  const listen = EventTarget.prototype.addEventListener;
  const unlisten = EventTarget.prototype.removeEventListener;
  const types = ['input', 'keydown', 'pointerdown'];
  let told = false;
  let interacted = false;
  let hasHandler = false;

  const tell = () => {
    if (told) return;
    told = true;
    for (const type of types) apply(unlisten, window, [type, note, true]);
    send();
  };
  // A getter that throws is the page's own code at leaving too: counted as a handler.
  const hasProperty = () => { try { return typeof window.onbeforeunload === 'function'; } catch { return true; } };
  const note = (event) => {
    if (!event.isTrusted) return;
    interacted = true;
    if (event.type === 'input' || hasHandler || hasProperty()) tell();
  };
  for (const type of types) apply(listen, window, [type, note, true]);

  // A listener can only be seen as it is added.
  EventTarget.prototype.addEventListener = {
    addEventListener(type, listener) {
      if (!told && type === 'beforeunload' && listener && this === window) {
        hasHandler = true;
        if (interacted) tell();
      }
      return apply(listen, this, arguments);
    },
  }.addEventListener;

  // Back from the back-forward cache, the tab counts afresh from the page's commit.
  apply(listen, window, ['pageshow', (event) => { if (event.persisted && told) send(); }]);
})();
