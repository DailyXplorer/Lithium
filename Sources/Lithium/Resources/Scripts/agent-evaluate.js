// The body `evaluate` runs. It first waits for agent.js to hand over the element, which it sends
// only after it found no password or card value in the frame. The agent's function is pasted in
// below that wait, and Lithium refuses text that would close the brackets around it (a function
// declared there would be hoisted above the wait). Lithium scrubs the JSON result.
const lithiumHandedOver = await new Promise((resolve) => {
  const take = (event) => {
    const target = event.composedPath()[0];
    done(target === document ? { element: undefined } : target === window ? { stale: true } : { element: target });
  };
  const done = (value) => {
    removeEventListener(lithium.element, take, true);
    clearTimeout(timer);
    resolve(value);
  };
  addEventListener(lithium.element, take, true);
  const timer = setTimeout(() => done({ lost: true }), 3000);
});
if (lithiumHandedOver.lost) return JSON.stringify({ lost: true });
if (lithiumHandedOver.stale) return JSON.stringify({ stale: true });
const lithiumFunction = async () => (
__LITHIUM_FUNCTION__
);
return await (async (source, setup, element) => {
  const serialize = (value) => {
    const seen = new WeakSet();
    return JSON.stringify(value, (key, item) => {
      switch (typeof item) {
        case 'bigint': return `${item}n`;
        case 'function': return `[function ${item.name || 'anonymous'}]`;
        case 'symbol': return String(item);
        // Half a surrogate pair comes back replaced, so the result still decodes as JSON.
        case 'string': return item.toWellFormed();
        case 'object': break;
        default: return item;
      }
      if (item === null) return item;
      if (item === window) return '[window]';
      if (item instanceof Node) return item.nodeType === 1 ? `<${item.localName}${item.id ? `#${item.id}` : ''}>` : item.nodeName;
      if (seen.has(item)) return '[repeated]';
      seen.add(item);
      if (item instanceof Map) return Object.fromEntries(item);
      if (item instanceof Set) return [...item];
      if (item instanceof Error) return `${item.name}: ${item.message}`;
      return item;
    });
  };

  try {
    const args = JSON.parse(setup.args);
    const fn = await source();
    const value = typeof fn === 'function' ? await (setup.wantsElement ? fn(element, args) : fn(args)) : fn;
    const json = serialize(value);
    const end = /[\uD800-\uDBFF]/.test(json?.[setup.cap - 1] ?? '') ? setup.cap - 1 : setup.cap;
    if (json !== undefined && json.length > setup.cap) return JSON.stringify({ json: json.slice(0, end), cut: true });
    return JSON.stringify({ json });
  } catch (error) {
    let message;
    try { message = error && typeof error === 'object' && 'message' in error ? `${error.name}: ${error.message}` : String(error); } catch { message = 'an error' }
    return JSON.stringify({ error: message.toWellFormed() });
  }
})(lithiumFunction, lithium, lithiumHandedOver.element);
