// DM Sans on every element of the page, except where the site's own font does a job DM Sans
// can't: icon fonts (Font Awesome, Material Symbols, fontello…), code and math.
// A layered !important rule sets DM Sans everywhere; elements to leave alone get KEEP and are
// excluded, with everything inside them. Deciding needs the font the site chose, so new content
// briefly gets PROBE, which lifts the rule for it alone, while it is checked: at most once per
// frame, before it paints, and without restyling the rest of the page. A class or style change
// on a large element rechecks that element alone (PROBE_SELF) and the elements the page's font
// rules for that class select; restyling its whole subtree twice on every toggle made class
// changes three times slower than with DM Sans off.
(() => {
  'use strict';
  const FAMILY = 'Lithium DM Sans';
  const KEEP = 'data-lithium-font-keep';
  const PROBE = 'data-lithium-font-probe';
  // Lifts the rule for the element alone, not its subtree.
  const PROBE_SELF = 'data-lithium-font-self';
  const ICON_FONT = /icon|awesome|glyph|symbol|fontello|icomoon|feather|lucide|phosphor|themify|entypo|dings|emoji|\bfa\b/;
  const CODE_FONT = /mono|consol|courier|menlo|monaco|\bcode\b|inconsolata|cascadia/;
  const MATH_FONT = /katex|mathjax|mjx|\bmath\b|stix/;
  // Icon fonts with names we don't know still put their glyphs in the Private Use Area.
  const PRIVATE_USE = /[\uE000-\uF8FF]|[\u{F0000}-\u{10FFFD}]/u;
  const UNRENDERED = new Set(['head', 'script', 'style', 'link', 'meta', 'title', 'noscript', 'template', 'br', 'wbr', 'svg', 'math']);

  const base64 = '__LITHIUM_FONT__';
  const bytes = Uint8Array.fromBase64
    ? Uint8Array.fromBase64(base64)
    : Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
  // Built from bytes rather than a url() so the page's Content-Security-Policy can't block it.
  document.fonts.add(new FontFace(FAMILY, bytes, { weight: '100 1000' }));

  const sheet = new CSSStyleSheet();
  // A layer's !important beats every unlayered !important of the site, whatever its specificity.
  sheet.replaceSync(`@layer lithium-font {
    :not(code, pre, kbd, samp, svg, math, code *, pre *, kbd *, samp *, svg *, math *,
      [${KEEP}], [${KEEP}] *, [${PROBE}], [${PROBE}] *, [${PROBE_SELF}]) {
      font-family: "${FAMILY}", -apple-system, sans-serif !important;
    }
  }`);

  // A page uses a handful of font stacks: each one is classified once.
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
  const shadowRoots = new WeakSet();
  const probed = [];
  let observer;

  // A shadow tree's rule can't see attributes outside it, so its top elements are probed.
  const probe = (root) => {
    for (const element of root.nodeType === Node.ELEMENT_NODE ? [root] : root.children) {
      element.setAttribute(PROBE, '');
      probed.push(element);
    }
  };

  const adopt = (root) => {
    if (!root.adoptedStyleSheets.includes(sheet)) root.adoptedStyleSheets = [...root.adoptedStyleSheets, sheet];
  };

  // Returns whether to look inside the element.
  const visit = (element, seen) => {
    if (seen.has(element) || UNRENDERED.has(element.localName)) return false;
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
  let scheduled = false;

  // An element that stops keeping its font hands its subtree back, which then needs a full scan.
  const recheck = (elements) => {
    const targets = elements.filter((element) => element.isConnected && !UNRENDERED.has(element.localName)
      && !element.closest(`[${KEEP}]:not(:scope), [${PROBE}]`));
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

  const flush = () => {
    if (!scheduled) return;
    scheduled = false;
    if (changed.size) {
      const elements = [...changed];
      changed.clear();
      recheck(elements);
    }
    // Pages sometimes replace document.adoptedStyleSheets wholesale.
    adopt(document);
    // Content added inside other new content is covered by its ancestor's probe and scan.
    const roots = [...pending].filter((root) => {
      if (!root.isConnected) return false;
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
    requestAnimationFrame(flush);
    // Pages in background tabs get no animation frames.
    setTimeout(flush, 100);
  };

  const queue = (node) => {
    if (!node) return;
    pending.add(node);
    schedule();
  };

  const queueChange = (element) => {
    changed.add(element);
    schedule();
  };

  // Selectors of the rules that set a font, from the stylesheets of `root` the page can read.
  // A stylesheet from another origin can't be read: its rules are unknown.
  const fontRules = new WeakMap();
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
    const read = (rules) => {
      for (const rule of rules) {
        if (rule.cssRules) read(rule.cssRules);
        if (rule.selectorText && rule.style && (rule.style.getPropertyValue('font-family') || rule.style.getPropertyValue('font'))) {
          selectors.push(rule.selectorText.replace(/::?(before|after|marker|first-line|first-letter)\b/g, ''));
        }
      }
    };
    for (const other of sheets) {
      try { read(other.cssRules); } catch (_) { opaque = true; }
    }
    const rules = { stamp, selectors, opaque };
    fontRules.set(root, rules);
    return rules;
  };

  // Where the rules can't be read, the subtree is rechecked once the changes settle, a slice at a
  // time: the old full rescan, without blocking the page and once per burst of changes.
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

  // A class change on a large element: the element itself, what the font rules naming a class
  // that came or went select inside it, and what inside it keeps its own font (a rule that no
  // longer applies selects nothing).
  const classChanged = (element, oldValue) => {
    queueChange(element);
    const before = new Set((oldValue || '').split(/\s+/));
    const after = new Set(element.classList);
    const toggled = [...before, ...after].filter((name) => name && before.has(name) !== after.has(name));
    if (!toggled.length) return;
    element.querySelectorAll(`[${KEEP}]`).forEach(queueChange);
    const rules = fontRulesOf(element.getRootNode());
    for (const name of toggled) {
      const token = `.${CSS.escape(name)}`;
      for (const selector of rules.selectors) {
        if (!selector.includes(token)) continue;
        try { element.querySelectorAll(selector).forEach(queueChange); } catch (_) {}
      }
    }
    if (rules.opaque) recheckSubtreeLater(element);
  };

  // New styles can change any element's font: check the whole tree they apply to.
  const queueTreeOf = (node) => {
    const root = node.getRootNode();
    queue(root === document ? document.documentElement : root);
  };

  observer = new MutationObserver((records) => {
    for (const record of records) {
      if (record.type === 'childList') {
        for (const node of record.addedNodes) {
          if (node.nodeType !== Node.ELEMENT_NODE) continue;
          if (node.localName === 'style' || node.localName === 'link') queueTreeOf(node);
          else queue(node);
        }
      } else if (record.attributeName === 'class'
        || `${record.oldValue} ${record.target.getAttribute('style')}`.includes('font')) {
        // A small component is rescanned whole; a large one (a page's body, a feed, a video player) isn't.
        if (record.target.getElementsByTagName('*').length <= 64) queue(record.target);
        else if (record.attributeName === 'class') classChanged(record.target, record.oldValue);
        else queueChange(record.target);
      }
    }
  });

  adopt(document);
  observer.observe(document, OPTIONS);
  document.addEventListener('load', (event) => {
    if (event.target.localName === 'link') queueTreeOf(event.target);
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
})();
