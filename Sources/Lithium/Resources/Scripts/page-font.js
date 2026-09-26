// DM Sans on every element of the page, except where the site's own font does a job DM Sans
// can't: icon fonts (Font Awesome, Material Symbols, fontello…), code and math.
// A layered !important rule sets DM Sans everywhere; elements to leave alone get KEEP and are
// excluded, with everything inside them. Deciding needs the font the site chose, so new content
// briefly gets PROBE, which lifts the rule for it alone, while it is checked: at most once per
// frame, before it paints, and without restyling the rest of the page.
(() => {
  'use strict';
  const FAMILY = 'Lithium DM Sans';
  const KEEP = 'data-lithium-font-keep';
  const PROBE = 'data-lithium-font-probe';
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
      [${KEEP}], [${KEEP}] *, [${PROBE}], [${PROBE}] *) {
      font-family: "${FAMILY}", -apple-system, sans-serif !important;
    }
  }`);

  const keepsOwnFont = (element) => {
    const families = getComputedStyle(element).fontFamily.toLowerCase();
    const first = families.split(',')[0].trim().replace(/^["']|["']$/g, '');
    if (ICON_FONT.test(first) || CODE_FONT.test(first) || MATH_FONT.test(first)) return true;
    if (/(^|,)\s*(ui-)?monospace\s*(,|$)/.test(families)) return true;
    if (element.firstElementChild || element.textContent.trim().length > 2) return false;
    return PRIVATE_USE.test(element.textContent)
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
  let scheduled = false;

  const flush = () => {
    if (!scheduled) return;
    scheduled = false;
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

  const queue = (node) => {
    if (!node) return;
    pending.add(node);
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(flush);
    // Pages in background tabs get no animation frames.
    setTimeout(flush, 100);
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
        queue(record.target);
      }
    }
  });

  adopt(document);
  observer.observe(document, OPTIONS);
  document.addEventListener('load', (event) => {
    if (event.target.localName === 'link') queueTreeOf(event.target);
  }, true);
  // Custom elements defined late attach shadow roots that no mutation reports.
  addEventListener('load', () => queue(document.documentElement));
  queue(document.documentElement);
})();
