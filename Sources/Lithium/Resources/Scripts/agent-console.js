// Runs in the page's own world: each content world has its own console, so only this one sees the
// page's console calls. It never throws into the page, defines no global, and its wrappers report
// the originals' source, name and length.
(() => {
  const handler = window.webkit?.messageHandlers?.lithiumAgentConsole;
  if (!handler) return;
  const BODIES = __LITHIUM_BODIES__;
  // Taken now, before any page script can replace them.
  const apply = Reflect.apply;
  const postMessage = handler.postMessage;
  const post = (message) => { try { apply(postMessage, handler, [message]); } catch (_) {} };
  const { defineProperty, getOwnPropertyDescriptor, keys } = Object;
  const isArray = Array.isArray;
  const now = performance.now.bind(performance);
  const slice = Array.prototype.slice;
  const nativeToString = Function.prototype.toString;

  // The technique farbling.js uses: a replacement answers toString with its original's source.
  const disguises = new WeakMap();
  const disguise = (replacement, original) => {
    defineProperty(replacement, 'name', { value: original.name });
    defineProperty(replacement, 'length', { value: original.length });
    disguises.set(replacement, original);
    return replacement;
  };
  const toString = disguise({ toString() { return apply(nativeToString, disguises.get(this) || this, []); } }.toString, nativeToString);
  defineProperty(Function.prototype, 'toString', { ...getOwnPropertyDescriptor(Function.prototype, 'toString'), value: toString });
  const wrap = (owner, name, make) => {
    const descriptor = owner && getOwnPropertyDescriptor(owner, name);
    if (!descriptor || typeof descriptor.value !== 'function') return;
    defineProperty(owner, name, { ...descriptor, value: disguise(make(descriptor.value), descriptor.value) });
  };

  // Own data properties only: reading a getter would run the page's code.
  const describe = (value, depth) => {
    try {
      switch (typeof value) {
        case 'string': return value.length > 1024 ? value.slice(0, 1024) + '…' : value;
        case 'function': return 'function ' + (value.name || '(anonymous)');
        case 'symbol': return value.description === undefined ? 'Symbol()' : 'Symbol(' + value.description + ')';
        case 'object': break;
        default: return String(value);
      }
      if (value === null) return 'null';
      if (value instanceof Error) return value.name + ': ' + value.message;
      if (value instanceof Node) return '<' + value.nodeName.toLowerCase() + (value.id ? '#' + value.id : '') + '>';
      if (depth > 1) return isArray(value) ? '[…]' : '{…}';
      if (isArray(value)) return '[' + apply(slice, value, [0, 20]).map((item) => describe(item, depth + 1)).join(', ') + ']';
      const fields = keys(value).slice(0, 20).map((key) => {
        const field = getOwnPropertyDescriptor(value, key);
        return key + ': ' + (field && 'value' in field ? describe(field.value, depth + 1) : '[getter]');
      });
      return '{' + fields.join(', ') + '}';
    } catch (_) {
      return '[unreadable]';
    }
  };

  let second = -Infinity;
  let sent = 0;
  let dropped = 0;
  const send = (level, args) => {
    const time = now();
    if (time - second > 1000) { second = time; sent = 0; }
    if (++sent > 100) { dropped++; return; }
    const text = [];
    for (let index = 0; index < args.length && index < 20; index++) text.push(describe(args[index], 0).slice(0, 1024));
    post({ level, text: text.join(' '), dropped });
    dropped = 0;
  };
  for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
    wrap(console, level, (original) => ({ [level](...args) {
      try { send(level, args); } catch (_) {}
      return apply(original, this, args);
    } })[level]);
  }

  if (!BODIES) return;
  const LIMIT = 262144;
  const textual = (type) => /^(text\/(?!event-stream)|application\/([\w.+-]*\+)?(json|xml|javascript|x-www-form-urlencoded|graphql))/i.test(type || '');
  const getHeader = Headers.prototype.get;
  const clone = Response.prototype.clone;
  const then = Promise.prototype.then;
  const decoder = () => new TextDecoder();
  const sendBody = (method, url, status, type, text) => post({ body: { method: String(method).toUpperCase(), url, status, type, text: text.slice(0, LIMIT), truncated: text.length > LIMIT } });

  // The page's own response is untouched: a copy is read, and no further than LIMIT.
  const readCopy = async (response, method) => {
    try {
      const type = apply(getHeader, response.headers, ['content-type']);
      if (!textual(type)) return;
      const body = apply(clone, response, []).body;
      if (!body) return sendBody(method, response.url, response.status, type, '');
      const reader = body.getReader();
      const text = decoder();
      let read = '';
      while (read.length <= LIMIT) {
        const { done, value } = await reader.read();
        if (done) break;
        read += text.decode(value, { stream: true });
      }
      if (read.length > LIMIT) reader.cancel().catch(() => {});
      sendBody(method, response.url, response.status, type, read);
    } catch (_) {}
  };
  // A rejection the page leaves unhandled is still reported, from the promise it holds.
  wrap(window, 'fetch', (original) => ({ fetch(...args) {
    const promise = apply(original, this, args);
    try {
      const [input, init] = args;
      const method = init?.method || (input instanceof Request ? input.method : 'GET');
      return apply(then, promise, [(response) => { readCopy(response, method); return response; }]);
    } catch (_) {
      return promise;
    }
  } }).fetch);

  const requests = new WeakMap();
  const addListener = EventTarget.prototype.addEventListener;
  const xhr = XMLHttpRequest.prototype;
  wrap(xhr, 'open', (original) => ({ open(...args) {
    try { requests.set(this, String(args[0] || 'GET')); } catch (_) {}
    return apply(original, this, args);
  } }).open);
  wrap(xhr, 'send', (original) => ({ send(...args) {
    try {
      const request = this;
      apply(addListener, request, ['loadend', () => {
        try {
          const type = request.getResponseHeader('content-type');
          if (!request.status || !textual(type)) return;
          const text = request.responseType === '' || request.responseType === 'text' ? request.responseText
            : request.responseType === 'json' ? JSON.stringify(request.response) : null;
          if (text != null) sendBody(requests.get(request) || 'GET', request.responseURL, request.status, type, text);
        } catch (_) {}
      }]);
    } catch (_) {}
    return apply(original, this, args);
  } }).send);
})();
