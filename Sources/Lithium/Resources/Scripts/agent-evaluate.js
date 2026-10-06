// The body `evaluate` runs (PR 10), in Lithium's script world or the page's. The agent's
// function is compiled first, so it sees none of the names below but `lithium`, which holds
// nothing secret. It waits for agent.js to hand over the element its ref names and the
// password and card fields (events whose names only this call knows), then calls the function
// with the element and its args. In the script world, password fields read as empty while the
// function runs. What it returns comes back as JSON text, which Lithium scrubs before the agent
// sees it.
const lithiumFunction = (
__LITHIUM_FUNCTION__
);
return await (async (fn, setup) => {
  const lost = {};
  const guarded = new WeakSet();
  const element = await new Promise((resolve) => {
    const guard = (event) => guarded.add(event.composedPath()[0]);
    const take = (event) => {
      const target = event.composedPath()[0];
      done(target === document ? undefined : target === window ? null : target);
    };
    const done = (value) => {
      removeEventListener(setup.guard, guard, true);
      removeEventListener(setup.element, take, true);
      clearTimeout(timer);
      resolve(value);
    };
    addEventListener(setup.guard, guard, true);
    addEventListener(setup.element, take, true);
    const timer = setTimeout(() => done(lost), 3000);
  });
  if (element === lost) return JSON.stringify({ lost: true });
  if (element === null) return JSON.stringify({ stale: true });

  const undo = [];
  if (setup.isolated) {
    const secret = (field) => guarded.has(field) || (field instanceof HTMLInputElement
      && (field.type === 'password' || /\b(current-password|new-password|one-time-code)\b/i.test(field.autocomplete || '')));
    const replace = (target, key, make) => {
      const descriptor = Object.getOwnPropertyDescriptor(target, key);
      if (!descriptor) return;
      Object.defineProperty(target, key, make(descriptor));
      undo.push(() => Object.defineProperty(target, key, descriptor));
    };
    for (const key of ['value', 'defaultValue']) {
      replace(HTMLInputElement.prototype, key, (descriptor) => ({
        ...descriptor, get() { return secret(this) ? '' : descriptor.get.call(this); },
      }));
    }
    replace(Element.prototype, 'getAttribute', (descriptor) => ({
      ...descriptor, value(name) { return secret(this) && String(name).toLowerCase() === 'value' ? null : descriptor.value.apply(this, arguments); },
    }));
    const Original = FormData;
    replace(globalThis, 'FormData', (descriptor) => ({
      ...descriptor,
      value: class FormData extends Original {
        constructor(form) {
          super(...arguments);
          for (const field of form?.elements ?? []) if (secret(field) && field.name) this.delete(field.name);
        }
      },
    }));
  }

  const serialize = (value) => {
    const seen = new WeakSet();
    return JSON.stringify(value, (key, item) => {
      switch (typeof item) {
        case 'bigint': return `${item}n`;
        case 'function': return `[function ${item.name || 'anonymous'}]`;
        case 'symbol': return String(item);
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

  // Serialized before the guard comes off, so a getter in the result reads through it too.
  try {
    const args = JSON.parse(setup.args);
    const value = typeof fn === 'function' ? await (setup.wantsElement ? fn(element, args) : fn(args)) : await fn;
    const json = serialize(value);
    if (json !== undefined && json.length > setup.cap) return JSON.stringify({ json: json.slice(0, setup.cap), cut: true });
    return JSON.stringify({ json });
  } catch (error) {
    let message;
    try { message = error && typeof error === 'object' && 'message' in error ? `${error.name}: ${error.message}` : String(error); } catch { message = 'an error' }
    return JSON.stringify({ error: message });
  } finally {
    for (const step of undo.reverse()) step();
  }
})(lithiumFunction, lithium);
