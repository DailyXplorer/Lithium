// Body of a function run by ReaderMode in the page's own world, as the reader opens, which takes the
// page's <style>s and <link>s out of the document, and as it closes, which moves those the page added
// meanwhile to the page's: put back, each gets a new sheet, while a CSS-in-JS
// library keeps writing to the one it holds (styled-components keeps it for good). That one now
// passes what it's told on: to its element's sheet once the page is back, and while the reader is
// open, to the one `reader.js` gives back on leaving. Only while both hold as many rules, so that an
// index means the same rule in each. replace() and replaceSync() throw on these sheets anyway.
const latest = document[Symbol.for('lithium.readerSheets')] ??= new WeakMap();
const owned = (root) => [
  ...[...root.styleSheets].filter((sheet) => sheet.ownerNode),
  ...[...root.querySelectorAll('*')].filter((element) => element.shadowRoot).flatMap((element) => owned(element.shadowRoot)),
];
const disabled = Object.getOwnPropertyDescriptor(StyleSheet.prototype, 'disabled');
for (const sheet of owned(document)) {
  const node = sheet.ownerNode;
  latest.set(node, sheet);
  if (Object.hasOwn(sheet, 'insertRule')) continue;
  const other = (self) => {
    const current = node.sheet ?? latest.get(node);
    return current && current !== self ? current : null;
  };
  for (const name of ['insertRule', 'deleteRule', 'addRule', 'removeRule']) {
    const native = CSSStyleSheet.prototype[name];
    if (!native) continue;
    Object.defineProperty(sheet, name, { configurable: true, writable: true, value: function (...args) {
      let target = other(this);
      try { if (target && target.cssRules.length !== this.cssRules.length) target = null; } catch { target = null; }
      const result = native.apply(this, args);
      if (target) try { native.apply(target, args); } catch {}
      return result;
    } });
  }
  if (disabled) Object.defineProperty(sheet, 'disabled', { configurable: true, get() { return disabled.get.call(this); }, set(value) {
    disabled.set.call(this, value);
    const target = other(this);
    if (target) disabled.set.call(target, value);
  } });
}
