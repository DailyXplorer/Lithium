// Tells Lithium that leaving this document may lose the user's work, so an idle tab isn't put to
// sleep, again at most every 10 seconds while the user keeps at it: work left alone lapses after
// the idle interval. WebKit only lets a `beforeunload` handler ask after the user interacted, so a
// handler alone (ads and analytics add them) keeps no tab awake.
(() => {
  // Taken now, before the page can replace them.
  const channel = globalThis.webkit?.messageHandlers?.lithiumUnsavedInput;
  if (!channel) return;
  const post = channel.postMessage.bind(channel);
  const send = () => { try { post(null); } catch {} };
  const now = Date.now;
  const apply = Reflect.apply;
  const listen = EventTarget.prototype.addEventListener;
  let toldAt = -Infinity;
  let interacted = false;
  let hasHandler = false;

  const tell = () => {
    const time = now();
    if (time - toldAt < 10000) return;
    toldAt = time;
    send();
  };
  // A getter that throws is the page's own code at leaving too: counted as a handler.
  const hasProperty = () => { try { return typeof window.onbeforeunload === 'function'; } catch { return true; } };
  const note = (event) => {
    if (!event.isTrusted) return;
    interacted = true;
    if (event.type === 'input' || hasHandler || hasProperty()) tell();
  };
  for (const type of ['input', 'keydown', 'pointerdown']) apply(listen, window, [type, note, true]);

  // A listener can only be seen as it is added.
  EventTarget.prototype.addEventListener = {
    addEventListener(type, listener) {
      if (!hasHandler && type === 'beforeunload' && listener && this === window) {
        hasHandler = true;
        if (interacted) tell();
      }
      return apply(listen, this, arguments);
    },
  }.addEventListener;

  // Back from the back-forward cache, the tab counts afresh from the page's commit.
  apply(listen, window, ['pageshow', (event) => {
    if (event.persisted && toldAt > -Infinity) { toldAt = now(); send(); }
  }]);
})();
