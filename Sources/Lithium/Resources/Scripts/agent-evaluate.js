// The body `evaluate` runs (PR 10), in Lithium's script world or the page's. The agent's
// function is pasted into a wrapper first, so it sees none of the names below but `lithium`,
// which holds nothing secret, and an expression in its place is evaluated only once agent.js
// has handed over the element its ref names (by an event whose name only this call knows),
// after agent.js found no password or card value in the frame. It is then called with the
// element and its args. What it returns comes back as JSON text, which Lithium scrubs before
// the agent sees it.
const lithiumFunction = async () => (
__LITHIUM_FUNCTION__
);
return await (async (source, setup) => {
  const lost = {};
  const element = await new Promise((resolve) => {
    const take = (event) => {
      const target = event.composedPath()[0];
      done(target === document ? undefined : target === window ? null : target);
    };
    const done = (value) => {
      removeEventListener(setup.element, take, true);
      clearTimeout(timer);
      resolve(value);
    };
    addEventListener(setup.element, take, true);
    const timer = setTimeout(() => done(lost), 3000);
  });
  if (element === lost) return JSON.stringify({ lost: true });
  if (element === null) return JSON.stringify({ stale: true });

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
    // Cut on a code point, never between the two halves of an emoji.
    const end = /[\uD800-\uDBFF]/.test(json?.[setup.cap - 1] ?? '') ? setup.cap - 1 : setup.cap;
    if (json !== undefined && json.length > setup.cap) return JSON.stringify({ json: json.slice(0, end), cut: true });
    return JSON.stringify({ json });
  } catch (error) {
    let message;
    try { message = error && typeof error === 'object' && 'message' in error ? `${error.name}: ${error.message}` : String(error); } catch { message = 'an error' }
    return JSON.stringify({ error: message.toWellFormed() });
  }
})(lithiumFunction, lithium);
