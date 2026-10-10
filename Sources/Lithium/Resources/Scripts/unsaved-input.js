// Tells Lithium that leaving this document may lose the user's work, so an idle tab isn't put to
// sleep, again at most every 10 seconds while the user keeps at it: work left alone lapses after
// the idle interval. WebKit only lets a `beforeunload` handler ask after the user interacted, so a
// handler alone (ads and analytics add them) keeps no tab awake. An upload of files from such a
// page is told as it starts and ends, so the tab stays awake while it runs, however long.
(() => {
  // Taken now, before the page can replace them.
  const channel = globalThis.webkit?.messageHandlers?.lithiumUnsavedInput;
  if (!channel) return;
  const post = channel.postMessage.bind(channel);
  const send = (body = null) => { try { post(body); } catch {} };
  const now = Date.now;
  const apply = Reflect.apply;
  const listen = EventTarget.prototype.addEventListener;
  const then = Promise.prototype.then;
  const formValues = FormData.prototype.values;
  const [FileBody, StreamBody, Form] = [Blob, ReadableStream, FormData];
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
    report();
  };
  for (const type of ['input', 'keydown', 'pointerdown']) apply(listen, window, [type, note, true]);

  // A listener can only be seen as it is added.
  EventTarget.prototype.addEventListener = {
    addEventListener(type, listener) {
      if (!hasHandler && type === 'beforeunload' && listener && this === window) {
        hasHandler = true;
        if (interacted) tell();
        report();
      }
      return apply(listen, this, arguments);
    },
  }.addEventListener;

  // Uploads of files only: analytics send text, and are done at once. Told as the first starts and
  // the last ends, rather than again and again while they run, which would need a timer.
  const uploads = new Set();
  let reported = false;
  function report() {
    const uploading = uploads.size > 0 && interacted && (hasHandler || hasProperty());
    if (uploading === reported) return;
    reported = uploading;
    send(uploading ? 'uploading' : 'uploaded');
  }
  const isFile = (body) => {
    try {
      if (body instanceof FileBody || body instanceof StreamBody) return true;
      if (!(body instanceof Form)) return false;
      for (const value of apply(formValues, body, [])) if (value instanceof FileBody) return true;
    } catch {}
    return false;
  };
  const started = (upload) => { uploads.add(upload); report(); };
  const ended = (upload) => { if (uploads.delete(upload)) report(); };

  const xhrSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = {
    send(body) {
      const file = isFile(body);
      const result = apply(xhrSend, this, arguments);
      // A synchronous one is over already. Opened again, one stops without a `loadend`.
      if (file && this.readyState !== 4) {
        const xhr = this;
        const end = () => ended(xhr);
        apply(listen, xhr, ['loadend', end]);
        apply(listen, xhr, ['readystatechange', () => { if (xhr.readyState === 1) end(); }]);
        started(xhr);
      }
      return result;
    },
  }.send;

  const pageFetch = globalThis.fetch;
  globalThis.fetch = {
    fetch(input, init) {
      const promise = apply(pageFetch, this, arguments);
      let file = false;
      try { file = isFile(init?.body); } catch {}
      if (file) {
        const upload = {};
        const end = () => ended(upload);
        started(upload);
        apply(then, promise, [end, end]);
      }
      return promise;
    },
  }.fetch;

  // Back from the back-forward cache, the tab counts afresh from the page's commit. A frame leaving
  // (removed, or gone to another page) says its upload ended: the app counts each frame's.
  apply(listen, window, ['pageshow', (event) => {
    if (!event.persisted) return;
    if (toldAt > -Infinity) { toldAt = now(); send(); }
    reported = false;
    report();
  }]);
  apply(listen, window, ['pagehide', () => {
    if (reported) { reported = false; send('uploaded'); }
  }]);
})();
