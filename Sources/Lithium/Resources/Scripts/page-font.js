// The user's font on every element of the page, except icon fonts, code and math.
// A layered !important rule sets the font everywhere; elements to leave alone get KEEP. Deciding
// needs the site's font, so new content briefly gets PROBE, which lifts the rule for it alone,
// at most once per frame, before it paints. A class change on a large element rechecks only it
// (PROBE_SELF) and what the page's font rules for that class select: restyling its subtree made
// class changes three times slower.
// Nothing is written inside an editable region: rich-text editors re-render on any attribute
// change in their content, which would be probed again, forever.
(() => {
  'use strict';
  const FAMILY = __LITHIUM_FAMILY__;
  const BUNDLED = 'Lithium DM Sans';
  // Empty for any family other than the bundled one: it is installed on the Mac.
  const BASE64 = '__LITHIUM_FONT__';
  // Run again in an open page when the font changes in Settings: the running copy takes it.
  if (window.__lithiumFont) {
    window.__lithiumFont.use(FAMILY, BASE64);
    return;
  }
  const KEEP = 'data-lithium-font-keep';
  const PROBE = 'data-lithium-font-probe';
  const PROBE_SELF = 'data-lithium-font-self';
  const ICON_FONT = /icon|awesome|glyph|symbol|fontello|icomoon|feather|lucide|phosphor|themify|entypo|dings|emoji|\bfa\b/;
  const CODE_FONT = /mono|consol|courier|menlo|monaco|\bcode\b|inconsolata|cascadia/;
  const MATH_FONT = /katex|mathjax|mjx|\bmath\b|stix/;
  // Icon fonts with names we don't know still put their glyphs in the Private Use Area.
  const PRIVATE_USE = /[\uE000-\uF8FF]|[\u{F0000}-\u{10FFFD}]/u;
  const UNRENDERED = new Set(['head', 'script', 'style', 'link', 'meta', 'title', 'noscript', 'template', 'br', 'wbr', 'svg', 'math']);
  // Inside an editor the rule alone decides: code keeps its font, icon fonts don't.
  const EDITABLE = '[contenteditable]:not([contenteditable="false" i])';
  const inEditor = (node) => Boolean((node.host ?? node).closest?.(EDITABLE));

  let bundled = false;
  const addBundled = (base64) => {
    if (!base64 || bundled) return;
    bundled = true;
    const bytes = Uint8Array.fromBase64
      ? Uint8Array.fromBase64(base64)
      : Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
    // Built from bytes rather than a url() so the page's Content-Security-Policy can't block it.
    document.fonts.add(new FontFace(BUNDLED, bytes, { weight: '100 1000' }));
  };
  addBundled(BASE64);

  const sheet = new CSSStyleSheet();
  // A layer's !important beats every unlayered !important of the site, whatever its specificity.
  const rule = (family) => `@layer lithium-font {
    :not(code, pre, kbd, samp, svg, math, code *, pre *, kbd *, samp *, svg *, math *,
      [${KEEP}], [${KEEP}] *, [${PROBE}], [${PROBE}] *, [${PROBE_SELF}]) {
      font-family: "${family.replace(/["\\]/g, '\\$&')}", -apple-system, sans-serif !important;
    }
  }`;
  sheet.replaceSync(rule(FAMILY));

  const specialStacks = new Map();
  const isSpecialStack = (stack) => {
    let special = specialStacks.get(stack);
    if (special === undefined) {
      const families = stack.toLowerCase();
      const first = families.split(',')[0].trim().replace(/^["']|["']$/g, '');
      special = ICON_FONT.test(first) || CODE_FONT.test(first) || MATH_FONT.test(first)
        || /(^|,)\s*(ui-)?monospace\s*(,|$)/.test(families);
      specialStacks.set(stack, special);
    }
    return special;
  };
  // Replaced and form elements draw no glyph of their own and have no ::before or ::after.
  const NO_GLYPHS = new Set(['img', 'input', 'textarea', 'select', 'video', 'audio', 'canvas', 'iframe', 'embed', 'object', 'picture', 'source', 'track', 'hr']);

  const keepsOwnFont = (element) => {
    if (isSpecialStack(getComputedStyle(element).fontFamily)) return true;
    if (element.firstElementChild || NO_GLYPHS.has(element.localName)) return false;
    const text = element.textContent;
    if (text.trim().length > 2) return false;
    return PRIVATE_USE.test(text)
      || PRIVATE_USE.test(getComputedStyle(element, '::before').content)
      || PRIVATE_USE.test(getComputedStyle(element, '::after').content);
  };

  const OPTIONS = { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'style'], attributeOldValue: true };
  let shadowRoots = new WeakSet();
  let running = true;
  const probed = [];
  let observer;

  // A shadow tree's rule can't see attributes outside it, so its top elements are probed.
  const probe = (root) => {
    for (const element of root.nodeType === Node.ELEMENT_NODE ? [root] : root.children) {
      if (element.matches(EDITABLE)) continue;
      element.setAttribute(PROBE, '');
      probed.push(element);
    }
  };

  const adopt = (root) => {
    if (!root.adoptedStyleSheets.includes(sheet)) root.adoptedStyleSheets = [...root.adoptedStyleSheets, sheet];
  };

  const visit = (element, seen) => {
    if (seen.has(element) || UNRENDERED.has(element.localName) || element.matches(EDITABLE)) return false;
    seen.add(element);
    const keep = keepsOwnFont(element);
    if (keep !== element.hasAttribute(KEEP)) element.toggleAttribute(KEEP, keep);
    if (keep) return false;
    const shadow = element.shadowRoot;
    if (shadow) {
      adopt(shadow);
      if (!shadowRoots.has(shadow)) { shadowRoots.add(shadow); observer.observe(shadow, OPTIONS); }
      probe(shadow);
      scan(shadow, seen);
    }
    return true;
  };

  const scan = (root, seen) => {
    if (root.nodeType === Node.ELEMENT_NODE && !visit(root, seen)) return;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, {
      acceptNode: (element) => (visit(element, seen) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT),
    });
    while (walker.nextNode());
  };

  const pending = new Set();
  const changed = new Set();
  // Large elements whose class changed, with their class at the last flush: their selector
  // queries wait for it too, under its throttle.
  const classChanges = new Map();
  let scheduled = false;

  // An element that stops keeping its font hands its subtree back, which then needs a full scan.
  const recheck = (elements) => {
    const targets = elements.filter((element) => element.isConnected && !UNRENDERED.has(element.localName)
      && !element.closest(`[${KEEP}]:not(:scope), [${PROBE}], ${EDITABLE}`));
    for (const element of targets) element.setAttribute(PROBE_SELF, '');
    try {
      for (const element of targets) {
        const keep = keepsOwnFont(element);
        const kept = element.hasAttribute(KEEP);
        if (keep !== kept) element.toggleAttribute(KEEP, keep);
        if (kept && !keep) pending.add(element);
      }
    } finally {
      for (const element of targets) element.removeAttribute(PROBE_SELF);
    }
  };

  // A page that changes all the time is checked at most every THROTTLE ms: past BUSY bursts in two
  // seconds without user input, until the next input or SILENCE ms without change. A burst count
  // can't lift it, as the throttle itself lowers the count. Changes accumulate meanwhile.
  const BUSY = 30;
  const SILENCE = 4000;
  const THROTTLE = 500;
  let windowStart = 0;
  let bursts = 0;
  let lastBurst = -Infinity;
  let throttled = false;
  let lastFlush = -Infinity;
  let frame = 0;
  let timer = 0;
  const countBurst = () => {
    if (document.readyState !== 'complete') return;
    const now = performance.now();
    if (now - lastBurst > SILENCE) throttled = false;
    lastBurst = now;
    if (now - windowStart > 2000) {
      windowStart = now;
      bursts = 0;
    }
    if (++bursts > BUSY) throttled = true;
  };
  for (const type of ['keydown', 'pointerdown', 'pointermove', 'wheel', 'touchstart']) {
    addEventListener(type, () => {
      bursts = 0;
      windowStart = performance.now();
      throttled = false;
      if (scheduled) {
        cancelAnimationFrame(frame);
        frame = requestAnimationFrame(flush);
      }
    }, { capture: true, passive: true });
  }

  const flush = () => {
    if (!scheduled) return;
    scheduled = false;
    // A callback left waiting would flush the next pass early, piling up until every frame flushed.
    cancelAnimationFrame(frame);
    clearTimeout(timer);
    lastFlush = performance.now();
    // The reader shows its own document in its own font.
    if (window.__lithiumReader) {
      changed.clear();
      pending.clear();
      classChanges.clear();
      addedSheets.clear();
      return;
    }
    if (addedSheets.size) {
      const sheets = [...addedSheets];
      addedSheets.clear();
      sheets.forEach(sheetAdded);
    }
    if (classChanges.size) {
      const changes = [...classChanges];
      classChanges.clear();
      for (const [element, oldValue] of changes) if (element.isConnected) classChanged(element, oldValue);
    }
    if (changed.size) {
      const elements = [...changed];
      changed.clear();
      recheck(elements);
    }
    // Pages sometimes replace document.adoptedStyleSheets wholesale.
    adopt(document);
    const roots = [...pending].filter((root) => {
      if (!root.isConnected || inEditor(root)) return false;
      for (let node = root.parentNode; node; node = node.parentNode) if (pending.has(node)) return false;
      return true;
    });
    pending.clear();
    const seen = new Set();
    try {
      roots.forEach(probe);
      for (const root of roots) scan(root, seen);
    } finally {
      for (const element of probed) element.removeAttribute(PROBE);
      probed.length = 0;
    }
  };

  const schedule = () => {
    if (scheduled) return;
    scheduled = true;
    if (throttled) {
      timer = setTimeout(flush, lastFlush + THROTTLE - performance.now());
      return;
    }
    frame = requestAnimationFrame(flush);
    // Pages in background tabs get no animation frames.
    timer = setTimeout(flush, 100);
  };

  const queue = (node) => {
    if (!node || !running) return;
    pending.add(node);
    schedule();
  };

  const queueChange = (element) => {
    if (!running) return;
    changed.add(element);
    schedule();
  };

  // A stylesheet from another origin can't be read: its rules are unknown.
  const fontRules = new WeakMap();
  const readFontSelectors = (rules, selectors) => {
    for (const rule of rules) {
      if (rule.cssRules) readFontSelectors(rule.cssRules, selectors);
      if (rule.selectorText && rule.style && (rule.style.getPropertyValue('font-family') || rule.style.getPropertyValue('font'))) {
        selectors.push(rule.selectorText.replace(/::?(before|after|marker|first-line|first-letter)\b/g, ''));
      }
    }
    return selectors;
  };
  const fontRulesOf = (root) => {
    const sheets = [...root.styleSheets, ...root.adoptedStyleSheets].filter((other) => other !== sheet);
    let stamp = String(sheets.length);
    for (const other of sheets) {
      try { stamp += `,${other.cssRules.length}`; } catch (_) { stamp += ',-'; }
    }
    const known = fontRules.get(root);
    if (known && known.stamp === stamp) return known;
    const selectors = [];
    let opaque = false;
    for (const other of sheets) {
      try { readFontSelectors(other.cssRules, selectors); } catch (_) { opaque = true; }
    }
    const rules = { stamp, selectors, opaque };
    fontRules.set(root, rules);
    return rules;
  };

  // Where the rules can't be read, the subtree is rechecked once the changes settle, a slice at a
  // time, so the page isn't blocked.
  const settling = new Map();
  const recheckSubtreeLater = (root) => {
    clearTimeout(settling.get(root));
    settling.set(root, setTimeout(() => {
      settling.delete(root);
      if (!root.isConnected) return;
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, {
        acceptNode: (element) => (element.hasAttribute(KEEP) || UNRENDERED.has(element.localName)
          ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
      });
      const slice = () => {
        const elements = [];
        while (elements.length < 256 && walker.nextNode()) elements.push(walker.currentNode);
        recheck(elements);
        if (pending.size) schedule();
        if (elements.length === 256) setTimeout(slice, 0);
      };
      slice();
    }, 500));
  };

  // Also what inside keeps its own font: a rule that no longer applies selects nothing. Run by
  // `flush`, which rechecks `changed` right after.
  const classChanged = (element, oldValue) => {
    const mark = (node) => changed.add(node);
    mark(element);
    const before = new Set((oldValue || '').split(/\s+/));
    const after = new Set(element.classList);
    const toggled = [...before, ...after].filter((name) => name && before.has(name) !== after.has(name));
    if (!toggled.length) return;
    element.querySelectorAll(`[${KEEP}]`).forEach(mark);
    const rules = fontRulesOf(element.getRootNode());
    for (const name of toggled) {
      const token = `.${CSS.escape(name)}`;
      for (const selector of rules.selectors) {
        if (!selector.includes(token)) continue;
        try { element.querySelectorAll(selector).forEach(mark); } catch (_) {}
      }
    }
    if (rules.opaque) recheckSubtreeLater(element);
  };

  const queueClassChange = (element, oldValue) => {
    if (!running) return;
    // A class toggled back and forth before the flush comes to no change.
    if (!classChanges.has(element)) classChanges.set(element, oldValue);
    schedule();
  };

  // A new sheet changes only what its font rules select (an element whose font it names keeps its
  // subtree): those are rechecked, not the whole page, which a CSS-in-JS or lazy-CSS site adds
  // sheets to all the time. Run by `flush`, which rechecks `changed` right after.
  const sheetAdded = (node) => {
    if (!node.isConnected || !node.sheet) return;
    const root = node.getRootNode();
    let selectors;
    try { selectors = readFontSelectors(node.sheet.cssRules, []); } catch (_) {
      recheckSubtreeLater(root === document ? document.documentElement : root);
      return;
    }
    for (const selector of selectors) {
      try { root.querySelectorAll(selector).forEach((element) => changed.add(element)); } catch (_) {}
    }
  };

  // A <link>'s sheet comes once it loads, a <style>'s once its text is in: both by the flush.
  const addedSheets = new Set();
  const queueSheet = (node) => {
    if (!running) return;
    addedSheets.add(node);
    schedule();
  };

  observer = new MutationObserver((records) => {
    countBurst();
    for (const record of records) {
      if (inEditor(record.target)) continue;
      if (record.type === 'childList') {
        for (const node of record.addedNodes) {
          if (node.nodeType !== Node.ELEMENT_NODE) continue;
          if (node.localName === 'style' || node.localName === 'link') queueSheet(node);
          else queue(node);
        }
      } else if (record.attributeName === 'class'
        || `${record.oldValue} ${record.target.getAttribute('style')}`.includes('font')) {
        // A small component is rescanned whole; a large one (a page's body, a feed, a video player) isn't.
        if (record.target.getElementsByTagName('*').length <= 64) queue(record.target);
        else if (record.attributeName === 'class') queueClassChange(record.target, record.oldValue);
        else queueChange(record.target);
      }
    }
  });

  adopt(document);
  observer.observe(document, OPTIONS);
  document.addEventListener('load', (event) => {
    if (event.target.localName === 'link') queueSheet(event.target);
  }, true);
  // Custom elements defined late attach shadow roots that no mutation reports.
  const findLateShadowRoots = (root) => {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, {
      acceptNode: (element) => (element.hasAttribute(KEEP) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
    });
    for (let element = walker.nextNode(); element; element = walker.nextNode()) {
      const shadow = element.shadowRoot;
      if (!shadow) continue;
      if (shadowRoots.has(shadow)) findLateShadowRoots(shadow);
      else queue(element);
    }
  };
  addEventListener('load', () => findLateShadowRoots(document));
  queue(document.documentElement);

  window.__lithiumFont = {
    use(family, base64) {
      addBundled(base64);
      sheet.replaceSync(rule(family));
      if (running) return;
      running = true;
      shadowRoots = new WeakSet();
      observer.observe(document, OPTIONS);
      queue(document.documentElement);
    },
    // Marks stay; the next start checks them all again.
    stop() {
      if (!running) return;
      running = false;
      observer.disconnect();
      sheet.replaceSync('');
      scheduled = false;
      cancelAnimationFrame(frame);
      clearTimeout(timer);
      pending.clear();
      changed.clear();
      classChanges.clear();
      addedSheets.clear();
      settling.forEach((id) => clearTimeout(id));
      settling.clear();
    },
  };
})();
