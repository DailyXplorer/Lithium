// Body of an async function run by PageTranslator in Lithium's own content world, only once the
// user asks for a translation. Argument: action, 'start' or 'restore'.
// Translates the page in place through the app's `lithiumPageTranslate` handler: its text, and
// alt, title and placeholder, what is in view first. While translated, what the page adds or
// changes is translated too. 'restore' puts back the page's own text, exactly as it was.

const state = window.__lithiumPageTranslation;
if (action === 'restore') {
  state?.restore();
  return true;
}
if (state) return true;

const handler = webkit.messageHandlers.lithiumPageTranslate;
const attributes = ['alt', 'title', 'placeholder'];
// Never read: neither their text nor their attributes are the page's words.
const quiet = 'script, style, noscript, template, svg, math';
// Code and what the user types keep their text; a field's placeholder is still translated.
const kept = 'code, pre, kbd, samp, var, textarea';
const letter = /\p{L}/u;

// The node's own record, so the page's text can be put back and our own changes told apart.
const texts = new Map();
const attrs = new Map();
// A copy of text already translated (the reader's, cloned from the page) isn't sent again.
const known = new Map();
const queued = new WeakSet();
const pending = [];
// Elements waiting to come into view, with what each holds to translate.
const waiting = new Map();
let stopped = false;
let sending = false;
let dirty = new Set();
// The page removed nodes since the last pass: what they held is let go then.
let removed = false;
let timer = 0;
let ready;
const first = new Promise((resolve) => { ready = resolve; });

const marked = (element) => {
  const decided = element.closest('[translate], .notranslate');
  return !!decided && (decided.classList.contains('notranslate') || decided.getAttribute('translate').trim().toLowerCase() === 'no');
};

const watch = (element, item) => {
  const items = waiting.get(element);
  if (items) return items.push(item);
  waiting.set(element, [item]);
  visible.observe(element);
};

// Copies may lose spacing (the reader's does): known text is looked up without it.
const plain = (text) => text.replace(/\s+/g, ' ').trim();
// Only in the reader's copy: the page's own text that happens to read like a translation is its own.
const copied = (node) => !!window.__lithiumReader?.article?.contains(node);

const addText = (node) => {
  if (texts.has(node) || queued.has(node)) return;
  const data = node.data;
  if (!letter.test(data)) return;
  const [, lead, core, trail] = /^(\s*)([\s\S]*?)(\s*)$/.exec(data);
  const original = copied(node) ? known.get(plain(core)) : undefined;
  if (original !== undefined) return texts.set(node, { original: lead + original + trail, translated: data });
  queued.add(node);
  watch(node.parentElement, {
    node,
    text: core,
    apply: (result) => {
      queued.delete(node);
      // The page changed it meanwhile: its new text goes instead.
      if (node.data !== data) return addText(node);
      const translated = lead + result + trail;
      if (translated === data) return;
      texts.set(node, { original: data, translated });
      known.set(plain(result), core);
      node.data = translated;
    },
  });
};

const addAttributes = (element) => {
  for (const name of attributes) {
    const value = element.getAttribute(name);
    if (!value || !letter.test(value)) continue;
    const own = attrs.get(element);
    if (own?.get(name)?.translated === value || own?.get(name)?.queued === value) continue;
    const record = (entry) => {
      const entries = attrs.get(element) ?? new Map();
      entries.set(name, entry);
      attrs.set(element, entries);
    };
    const original = copied(element) ? known.get(plain(value)) : undefined;
    if (original !== undefined) {
      record({ original, translated: value });
      continue;
    }
    record({ queued: value });
    watch(element, {
      text: value.trim(),
      apply: (result) => {
        if (element.getAttribute(name) !== value) return;
        if (result === value) return attrs.get(element)?.delete(name);
        record({ original: value, translated: result });
        known.set(plain(result), value);
        element.setAttribute(name, result);
      },
    });
  }
};

const add = (root) => {
  const start = root.nodeType === Node.TEXT_NODE ? root.parentElement : root;
  if (!start || start.nodeType !== Node.ELEMENT_NODE || start.closest(quiet) || marked(start)) return;
  const keepsText = start.closest(kept) || start.isContentEditable;
  if (root.nodeType === Node.TEXT_NODE) return keepsText || addText(root);
  addAttributes(root);
  if (keepsText) return;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (node.nodeType === Node.TEXT_NODE) return NodeFilter.FILTER_ACCEPT;
      if (node.matches(quiet) || node.classList.contains('notranslate') || node.getAttribute('translate')?.trim().toLowerCase() === 'no') {
        return NodeFilter.FILTER_REJECT;
      }
      addAttributes(node);
      return node.matches(kept) || node.isContentEditable ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP;
    },
  });
  for (let node = walker.nextNode(); node; node = walker.nextNode()) addText(node);
};

// One batch in flight at a time, in the order things came into view.
const flush = async () => {
  if (sending) return;
  sending = true;
  try {
    while (pending.length && !stopped) {
      const batch = [];
      let length = 0;
      while (pending.length && batch.length < 50 && length < 4000) {
        const item = pending.shift();
        batch.push(item);
        length += item.text.length;
      }
      const results = await handler.postMessage(batch.map((item) => item.text));
      if (stopped || !Array.isArray(results)) return;
      batch.forEach((item, index) => { if (typeof results[index] === 'string' && results[index]) item.apply(results[index]); });
    }
  } catch {
    // The app said why; the page goes back to its own text.
    restore();
  } finally {
    sending = false;
    ready();
  }
};

const visible = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    visible.unobserve(entry.target);
    pending.push(...(waiting.get(entry.target) ?? []));
    waiting.delete(entry.target);
  }
  if (pending.length) flush(); else ready();
}, { rootMargin: '50% 0px' });

// Throttled: an infinite list or a ticking clock is read at most a few times a second.
const catchUp = () => {
  timer = 0;
  const roots = dirty;
  dirty = new Set();
  // One kept node holds its whole removed subtree: a single-page site would otherwise keep every
  // view it ever showed until Show Original. Moved nodes are connected again by now and stay.
  if (removed) {
    removed = false;
    for (const node of texts.keys()) if (!node.isConnected) texts.delete(node);
    for (const element of attrs.keys()) if (!element.isConnected) attrs.delete(element);
    for (const [element, items] of waiting) {
      if (element.isConnected) continue;
      visible.unobserve(element);
      waiting.delete(element);
      // Put back later, its text is read again.
      for (const item of items) if (item.node) queued.delete(item.node);
    }
  }
  for (const node of roots) if (node.isConnected) add(node);
};

const onChange = (records) => {
  for (const record of records) {
    if (record.type === 'childList') {
      record.addedNodes.forEach((node) => dirty.add(node));
      if (record.removedNodes.length) removed = true;
    } else if (record.type === 'characterData') {
      const node = record.target;
      if (texts.get(node)?.translated === node.data) continue;
      texts.delete(node);
      dirty.add(node);
    } else {
      const entry = attrs.get(record.target)?.get(record.attributeName);
      const value = record.target.getAttribute(record.attributeName);
      if (entry && (entry.translated === value || entry.queued === value)) continue;
      attrs.get(record.target)?.delete(record.attributeName);
      dirty.add(record.target);
    }
  }
  if ((dirty.size || removed) && !timer) timer = setTimeout(catchUp, 300);
};
const changed = new MutationObserver(onChange);

const restore = () => {
  if (stopped) return;
  // Copies of translated text made since the last pass (the reader's) are put back too.
  onChange(changed.takeRecords());
  clearTimeout(timer);
  catchUp();
  stopped = true;
  removeEventListener('pagehide', restore);
  visible.disconnect();
  changed.disconnect();
  for (const [node, entry] of texts) if (node.data === entry.translated) node.data = entry.original;
  for (const [element, entries] of attrs) {
    for (const [name, entry] of entries) if (entry.translated !== undefined && element.getAttribute(name) === entry.translated) element.setAttribute(name, entry.original);
  }
  delete window.__lithiumPageTranslation;
  ready();
};

// `held`: how many nodes the translation keeps a hold on, for the tests.
window.__lithiumPageTranslation = { restore, held: () => texts.size + attrs.size + waiting.size };
// Into the back/forward cache in its own text: back on screen, the app sees the page as it is
// and translates it again if the tab still translates.
addEventListener('pagehide', restore);
// The reader's body comes first and the page's waits behind it: both are the document's.
for (const body of document.querySelectorAll('body')) add(body);
changed.observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: attributes });
if (!waiting.size) ready();
// What is in view is translated before this returns; a page that never draws (hidden) doesn't hold it up.
await Promise.race([first, new Promise((resolve) => setTimeout(resolve, 3000))]);
return !stopped;
