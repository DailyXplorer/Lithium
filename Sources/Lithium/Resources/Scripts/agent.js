// Agent perception, installed by PageProbe in a frame the first time an agent reads it. Runs in
// the lithium-agent content world: the page's world can't see its globals, its observers or its
// listeners. Every answer is a JSON string, read by PageProbe. Values of password and card
// fields never leave this script; hidden text (display, visibility, opacity, aria-hidden,
// clipped, under 6 px) is left out, as it is a common carrier of prompt injection.
(() => {
  // Installed already: a second copy would number the document's elements again from 1.
  if (globalThis.lithiumAgent) return;
  const frame = globalThis.lithiumAgentFrame ?? (() => {
    // A frame open before agent access was turned on has no bootstrap.
    const bytes = crypto.getRandomValues(new Uint8Array(12));
    const token = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
    return (globalThis.lithiumAgentFrame = { token, passwords: new WeakSet() });
  })();

  // Refs: a number per element, never reused within the document, held weakly.
  const ids = new WeakMap();
  const elements = new Map();
  // An element collected takes its entry with it, so a long-lived document's map doesn't keep
  // one per element ever numbered. Ids aren't reused: a live ref is never the one removed.
  const collected = new FinalizationRegistry((id) => elements.delete(id));
  let nextID = 1;
  const idOf = (element) => {
    let id = ids.get(element);
    if (!id) {
      id = nextID++;
      ids.set(element, id);
      elements.set(id, new WeakRef(element));
      collected.register(element, id);
    }
    return id;
  };
  const elementOf = (id) => {
    const element = elements.get(id)?.deref();
    if (!element) elements.delete(id);
    return element?.isConnected ? element : null;
  };

  // Anything that can change what a snapshot shows bumps the generation; an unchanged one lets
  // a snapshot answer without walking the document.
  let generation = 1;
  const dirty = () => { generation++; };
  const observedRoots = new WeakSet();
  const observe = (root) => {
    if (observedRoots.has(root)) return;
    observedRoots.add(root);
    new MutationObserver(dirty).observe(root, { subtree: true, childList: true, attributes: true, characterData: true });
  };
  observe(document);
  for (const type of ['scroll', 'resize', 'input', 'change', 'focusin', 'focusout', 'toggle', 'transitionend', 'animationend', 'load']) {
    addEventListener(type, dirty, { capture: true, passive: true });
  }
  // A menu that CSS :hover alone reveals changes no node, rule or box the checks below see;
  // only the real pointer moves :hover.
  for (const type of ['pointerover', 'pointerout']) {
    addEventListener(type, (event) => { if (event.isTrusted) dirty(); }, { capture: true, passive: true });
  }
  // Layout also changes with no mutation: a web font arriving, the page growing.
  document.fonts?.addEventListener('loadingdone', dirty);
  const resizes = new ResizeObserver(dirty);
  resizes.observe(document.documentElement);
  if (document.body) resizes.observe(document.body);

  const collapse = (text) => (text || '').replace(/\s+/g, ' ').trim();
  // Slices on code points: half of an emoji's surrogate pair isn't text, and Swift's JSON
  // decoder refuses an answer that holds one.
  const head = (text, length) => text.slice(0, /[\uD800-\uDBFF]/.test(text[length - 1] ?? '') ? length - 1 : length);
  const tail = (text, start) => text.slice(/[\uDC00-\uDFFF]/.test(text[start] ?? '') ? start + 1 : start);
  const cut = (text, length) => (text.length > length ? `${head(text, length - 1)}…` : text);
  const plain = (text) => (text || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[_.[\]]/g, ' ');
  const round = (rect) => [Math.round(rect.x), Math.round(rect.y), Math.round(rect.width), Math.round(rect.height)];

  // Elements whose own text is never page text, or never rendered.
  const skipped = new Set(['script', 'style', 'noscript', 'template', 'head', 'meta', 'link', 'title', 'datalist']);
  const textless = new Set(['input', 'select', 'textarea', 'option', 'optgroup', 'svg', 'canvas', 'iframe', 'frame', 'object', 'embed', 'video', 'audio', 'img']);
  // Password managers draw their menus inside pages; they are UI, not the page.
  const isExtensionUI = (element) => element.localName.startsWith('com-1password');
  // WebKit shows pages an extension frame's address as webkit-masked-url://hidden/.
  const isExtensionFrame = (element) => /^(webkit-extension|webkit-masked-url):/i.test(element.src || element.getAttribute('src') || '');
  // An SVG link's href is an SVGAnimatedString; users follow it all the same.
  const hrefOf = (element) => {
    if (typeof element.href === 'string') return element.href;
    const raw = element.href?.baseVal;
    if (!raw) return '';
    try { return new URL(raw, document.baseURI).href; } catch { return ''; }
  };

  // An element a page makes in another namespace (createElementNS) can share an HTML control's
  // name but has none of its properties (`value`, `selectedOptions`, `cells`, `elements`): these
  // names count only on HTML elements. A namespace, not instanceof, so it holds in the
  // same-origin child documents `guards` and text waits read, whose elements have their own.
  const htmlNamed = new Set(['input', 'select', 'textarea', 'tr', 'form']);
  const tagOf = (element) => (htmlNamed.has(element.localName) && element.namespaceURI !== 'http://www.w3.org/1999/xhtml' ? '' : element.localName);

  // Roles
  const inputRoles = {
    button: 'button', submit: 'button', reset: 'button', image: 'button', file: 'button', color: 'button',
    checkbox: 'checkbox', radio: 'radio', range: 'slider', number: 'spinbutton', search: 'searchbox',
  };
  const implicitRole = (element) => {
    switch (tagOf(element)) {
      case 'a': case 'area': return element.hasAttribute('href') ? 'link' : null;
      case 'button': case 'summary': return 'button';
      case 'input':
        if (element.type === 'hidden') return null;
        if (element.type === 'checkbox' && element.hasAttribute('switch')) return 'switch';
        return inputRoles[element.type] ?? 'textbox';
      case 'select': return element.multiple || element.size > 1 ? 'listbox' : 'combobox';
      case 'textarea': return 'textbox';
      case 'img': return element.getAttribute('alt') ? 'img' : null;
      case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
      case 'dialog': return 'dialog';
      case 'table': return 'table';
      case 'tr': return 'row';
      case 'nav': return 'navigation';
      case 'main': return 'main';
      case 'form': return 'form';
      case 'search': return 'search';
      case 'iframe': case 'frame': return 'frame';
    }
    if (element.isContentEditable && !element.parentElement?.isContentEditable) return 'textbox';
    return null;
  };
  const roleOf = (element) => {
    const explicit = (element.getAttribute('role') || '').trim().split(/\s+/)[0].toLowerCase();
    if (explicit && !['none', 'presentation', 'generic'].includes(explicit)) return explicit;
    return implicitRole(element);
  };
  const interactive = new Set(['link', 'button', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox', 'listbox', 'option',
    'slider', 'spinbutton', 'switch', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'treeitem']);
  const structural = new Set(['heading', 'img', 'dialog', 'alertdialog', 'alert', 'status', 'log', 'table', 'row',
    'navigation', 'main', 'form', 'search']);
  // Named by their text, which then isn't repeated as a text block.
  const namedByContent = new Set(['link', 'button', 'heading', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio',
    'option', 'treeitem', 'checkbox', 'radio', 'switch', 'row', 'clickable', 'alert', 'status', 'log']);

  // Names go through the same rules as page text, so hidden text in a link or a button stays out.
  const textOf = (element) => collapse(lines(element).map((item) => item.text).join(' '));
  const iconName = (element) => {
    for (const icon of element.querySelectorAll('img[alt], [aria-label], svg title')) {
      const title = icon.localName === 'title';
      if (!isVisible(title ? icon.parentElement : icon)) continue;
      const name = collapse(title ? icon.textContent : icon.getAttribute('alt') || icon.getAttribute('aria-label'));
      if (name) return name;
    }
    return '';
  };

  // A simplified accessible name: labelledby, aria-label, labels, alt, title, placeholder, text.
  const nameOf = (element, role) => {
    const labelledBy = element.getAttribute('aria-labelledby');
    if (labelledBy) {
      const root = element.getRootNode();
      const text = collapse(labelledBy.split(/\s+/).map((id) => (root.getElementById?.(id) ?? document.getElementById(id))).filter(Boolean).map(textOf).join(' '));
      if (text) return text;
    }
    const label = collapse(element.getAttribute('aria-label'));
    if (label) return label;
    if (element.labels?.length) {
      const text = collapse([...element.labels].map(textOf).join(' '));
      if (text) return text;
    }
    if (element.localName === 'input') {
      if (['button', 'submit', 'reset'].includes(element.type)) return collapse(element.value) || (element.type === 'submit' ? 'Submit' : element.type === 'reset' ? 'Reset' : '');
      if (element.type === 'image') return collapse(element.alt) || 'Submit';
    }
    if (['img', 'area'].includes(element.localName)) {
      const alt = collapse(element.getAttribute('alt'));
      if (alt) return alt;
    }
    if (role === 'table') {
      const caption = element.caption && textOf(element.caption);
      if (caption) return caption;
    }
    if (role === 'row') return collapse([...element.children].map(textOf).filter(Boolean).join(' | '));
    if (namedByContent.has(role)) {
      const text = textOf(element) || iconName(element);
      if (text) return text;
    }
    if (role === 'dialog' || role === 'alertdialog') {
      const heading = element.querySelector('h1, h2, h3, h4, h5, h6, [role=heading]');
      if (heading) return textOf(heading);
    }
    return collapse(element.getAttribute('title')) || collapse(element.getAttribute('placeholder'));
  };

  // Sensitive fields (design section 7.3)
  const cardWords = /\b(card ?number|cardnumber|cc-?num|numero de (la )?carte|kartennummer|numero de tarjeta|numero (della )?carta|cvc|cvv2?|csc|security code|cryptogramme|code de securite|prufnummer|expiry|expiration|date d'?expiration|ablaufdatum|caducidad|scadenza|iban)\b/;
  const cardNumberWords = /\b(card ?number|cardnumber|cc-?num|numero de (la )?carte|kartennummer|numero de tarjeta|numero (della )?carta)\b/;
  const isField = (element) => ['input', 'select', 'textarea'].includes(tagOf(element));
  const autocomplete = (element) => (element.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
  const fieldWords = (element) => plain([
    element.getAttribute('name'), element.id, element.getAttribute('aria-label'), element.getAttribute('placeholder'),
    ...[...(element.labels ?? [])].map((label) => label.textContent),
  ].filter(Boolean).join(' '));
  const isPassword = (element) => {
    if (tagOf(element) !== 'input') return false;
    if (frame.passwords.has(element)) return true;
    // Inside shadow roots the bootstrap's observer sees no type change: note it while it shows.
    if (element.type === 'password') {
      frame.passwords.add(element);
      return true;
    }
    if (autocomplete(element).some((token) => ['current-password', 'new-password', 'one-time-code'].includes(token))) return true;
    if (/passw|pwd/i.test(`${element.getAttribute('name') || ''} ${element.id}`)) return true;
    // A field the page draws as discs itself (a PIN, a password in a text field) holds a secret
    // too, and stays one when a "show" toggle turns the masking off. The style is inherited, so
    // only fields one types in count.
    if (!textTypes.has(element.type)) return false;
    const security = getComputedStyle(element).webkitTextSecurity;
    if (security && security !== 'none') {
      frame.passwords.add(element);
      return true;
    }
    return false;
  };
  const isCard = (element) => isField(element)
    && (autocomplete(element).some((token) => token.startsWith('cc-') || token === 'transaction-amount') || cardWords.test(fieldWords(element)));
  const isCardNumber = (element) => autocomplete(element).includes('cc-number') || cardNumberWords.test(fieldWords(element));
  const guardOf = (element) => (isPassword(element) ? 'password' : isCard(element) ? 'payment' : null);
  // Apple Pay and Google Pay buttons: activating one starts a payment.
  const isWallet = (element, style) => element.localName === 'apple-pay-button' || element.localName === 'gpay-button'
    || element.classList.contains('gpay-button') || /-apple-pay-button/.test(style.webkitAppearance || style.appearance || '');

  // Digit runs that pass the Luhn check, wherever a field holds one.
  const luhn = (digits) => {
    let sum = 0;
    for (let i = 0; i < digits.length; i++) {
      let digit = Number(digits[digits.length - 1 - i]);
      if (i % 2 === 1) { digit *= 2; if (digit > 9) digit -= 9; }
      sum += digit;
    }
    return sum % 10 === 0;
  };
  const maskCards = (text) => text.replace(/\d(?:[ -]?\d){12,18}/g, (run) => (luhn(run.replace(/\D/g, '')) ? '[card]' : run));

  // The field's value as an agent may see it, or null for controls without one.
  const valueOf = (element, role) => {
    const guard = guardOf(element);
    if (guard) {
      const filled = tagOf(element) === 'select' ? element.selectedIndex > 0 : element.value !== '';
      if (guard === 'payment' && filled && tagOf(element) !== 'select' && isCardNumber(element)) {
        const digits = element.value.replace(/\D/g, '');
        if (digits.length >= 12) return { value: `•••• ${digits.slice(-4)}`, filled };
      }
      return { value: '[redacted]', filled };
    }
    if (tagOf(element) === 'select') {
      const labels = [...element.selectedOptions].map((option) => collapse(option.label || option.text));
      return { value: cut(labels.join(', '), 80) };
    }
    if (tagOf(element) === 'input') {
      if (['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'hidden'].includes(element.type)) return null;
      return { value: cut(maskCards(element.value), 200) };
    }
    if (tagOf(element) === 'textarea') return { value: cut(maskCards(element.value), 200) };
    if (role === 'textbox' && element.isContentEditable) return { value: cut(maskCards(textOf(element)), 200) };
    return null;
  };

  const safeMatches = (element, selector) => {
    try { return element.matches(selector); } catch { return false; }
  };
  const stateOf = (element, role, focused) => {
    const state = [];
    const aria = (name) => element.getAttribute(`aria-${name}`);
    if (element.disabled || aria('disabled') === 'true' || safeMatches(element, ':disabled')) state.push('disabled');
    if (((element.readOnly && ['input', 'textarea'].includes(element.localName)) || aria('readonly') === 'true')) state.push('readonly');
    if (element.required || aria('required') === 'true') state.push('required');
    if (element.indeterminate || aria('checked') === 'mixed') state.push('mixed');
    else if ((element.checked === true && ['checkbox', 'radio', 'switch'].includes(role)) || aria('checked') === 'true') state.push('checked');
    if ((role === 'option' && element.selected) || aria('selected') === 'true') state.push('selected');
    const expanded = aria('expanded') ?? (element.localName === 'summary' ? String(Boolean(element.parentElement?.open)) : null);
    if (expanded === 'true') state.push('expanded');
    else if (expanded === 'false') state.push('collapsed');
    if (aria('pressed') === 'true') state.push('pressed');
    if (element === focused) state.push('focused');
    if ((aria('invalid') && aria('invalid') !== 'false') || safeMatches(element, ':user-invalid')) state.push('invalid');
    if (aria('busy') === 'true') state.push('busy');
    if (role === 'textbox' && element.isContentEditable && !isField(element)) state.push('editable');
    return state;
  };

  const deepFocus = () => {
    let focused = document.activeElement;
    while (focused?.shadowRoot?.activeElement) focused = focused.shadowRoot.activeElement;
    return focused;
  };
  const isInline = (style) => style.display.startsWith('inline') || style.display === 'contents';
  // Visually hidden on purpose (the "screen reader only" pattern), so out like any hidden text.
  const clippedAway = (element, style) => {
    if (style.clip.startsWith('rect(') && /rect\((0|1)px,? (0|1)px,? (0|1)px,? (0|1)px\)/.test(style.clip)) return true;
    if (style.clipPath.includes('inset(50%')) return true;
    if (style.overflow !== 'visible' && !isInline(style)) {
      const rect = element.getBoundingClientRect();
      if (rect.width < 2 || rect.height < 2) return true;
    }
    return false;
  };
  // Children of every element, through open shadow roots; closed ones are out of reach.
  const childrenOf = (element) => {
    if (element.shadowRoot) {
      observe(element.shadowRoot);
      return [...element.shadowRoot.children, ...element.children];
    }
    return element.children;
  };
  const allElements = function* (root) {
    for (const child of root.children) {
      yield child;
      if (child.shadowRoot) yield* allElements(child.shadowRoot);
      yield* allElements(child);
    }
  };
  const hiddenByAncestor = (element) => {
    for (let node = element; node; node = node.parentElement ?? node.getRootNode()?.host) {
      if (node.getAttribute?.('aria-hidden') === 'true' || isExtensionUI(node)) return true;
    }
    return false;
  };
  const isVisible = (element) => element.checkVisibility({ opacityProperty: true, visibilityProperty: true }) && !hiddenByAncestor(element);

  // Controls follow Playwright's actionability rather than the text rules: one with a box is
  // there to act on even at opacity 0 (TodoMVC's toggle, which its label draws), and a field
  // hidden on purpose behind a styled label (clipped to a pixel, zero size, off the page) is
  // reached through that label, as the user's click on the label reaches it. Text stays under
  // the text rules, so a control's name never comes from text the user can't see.
  const isControl = (element) => interactive.has(roleOf(element));
  const tiny = (rect) => rect.width < 2 || rect.height < 2;
  const offPage = (rect) => rect.right + scrollX <= 0 || rect.bottom + scrollY <= 0;
  const shownLabel = (element) => [...(element.labels ?? [])].find((label) => {
    const rect = label.getBoundingClientRect();
    return isVisible(label) && !tiny(rect) && !offPage(rect) && !clippedAway(label, getComputedStyle(label));
  });
  // What stands for the control on screen: itself, its label, or nothing when it is hidden.
  // `clipped`: an ancestor clips it away, so only a label outside can stand for it.
  const controlFace = (element, style = getComputedStyle(element), clipped = false) => {
    if (!element.checkVisibility({ visibilityProperty: true }) || hiddenByAncestor(element)) return null;
    const rect = element.getBoundingClientRect();
    if (!clipped && !tiny(rect) && !offPage(rect) && !clippedAway(element, style)) return element;
    return isField(element) ? shownLabel(element) ?? null : null;
  };
  // A control the user can't see named only by what they can (its visible labels) or what the
  // page gives assistive technology, never by its own transparent text.
  const unseenName = (element) => {
    const labelledBy = (element.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean)
      .map((id) => element.getRootNode().getElementById?.(id) ?? document.getElementById(id)).filter((label) => label && isVisible(label));
    return collapse(labelledBy.map(textOf).join(' ')) || collapse(element.getAttribute('aria-label'))
      || collapse([...(element.labels ?? [])].filter(isVisible).map(textOf).join(' ')) || collapse(element.getAttribute('title'));
  };
  const controlName = (element, role) => cut(isVisible(element) ? nameOf(element, role) : unseenName(element), 80);
  // An element as the snapshot, waits and forms see it.
  const isShown = (element) => (isControl(element) ? Boolean(controlFace(element)) : isVisible(element) && element.getBoundingClientRect().width > 0);

  // Challenges a whole page is made of; widgets in frames are told by their address, in Lithium.
  const pageChallenge = () => {
    const has = (selector) => document.querySelector(selector) !== null;
    if (has('#challenge-form, #challenge-running, #challenge-stage, #cf-challenge-running, .cf-browser-verification')
      || (has('script[src*="/cdn-cgi/challenge-platform/"]') && /just a moment|checking your browser|attention required|un instant/i.test(document.title))) return 'cloudflare';
    if (has('#px-captcha')) return 'perimeterx';
    if (has('#captcha-container') && has('script[src*="awswaf"]')) return 'aws-waf';
    if (has('#ddv1-captcha-container') || has('script[src*="captcha-delivery.com"]')) return 'datadome';
    return null;
  };

  const viewport = () => ({
    w: innerWidth, h: innerHeight, sx: Math.round(scrollX), sy: Math.round(scrollY),
    pw: document.documentElement.scrollWidth, ph: document.documentElement.scrollHeight,
    dpr: devicePixelRatio, vx: visualViewport?.offsetLeft ?? 0, vy: visualViewport?.offsetTop ?? 0, vs: visualViewport?.scale ?? 1,
  });

  // This frame's place among its ancestors' frames: an index into parent.frames per level.
  // Cross-origin parents still expose their frames list and its windows for comparison.
  const framePath = () => {
    const path = [];
    try {
      for (let current = window; current !== current.parent; current = current.parent) {
        const parent = current.parent;
        let index = -1;
        for (let i = 0; i < parent.length; i++) {
          if (parent.frames[i] === current) { index = i; break; }
        }
        path.unshift(index);
      }
    } catch {
      return null;
    }
    return path.join('.');
  };
  const frameIndexes = () => {
    const indexes = new Map();
    for (let i = 0; i < window.length; i++) indexes.set(window.frames[i], i);
    return indexes;
  };
  // The frame's content box in this frame's viewport, where its own viewport starts.
  const frameFacts = (element, style, indexes) => {
    const rect = element.getBoundingClientRect();
    const scale = element.offsetWidth ? rect.width / element.offsetWidth : 1;
    const left = rect.left + (parseFloat(style.borderLeftWidth) + parseFloat(style.paddingLeft)) * scale;
    const top = rect.top + (parseFloat(style.borderTopWidth) + parseFloat(style.paddingTop)) * scale;
    const width = element.clientWidth * scale - (parseFloat(style.paddingLeft) + parseFloat(style.paddingRight)) * scale;
    const height = element.clientHeight * scale - (parseFloat(style.paddingTop) + parseFloat(style.paddingBottom)) * scale;
    return {
      id: idOf(element), index: indexes.get(element.contentWindow) ?? -1, box: round(rect),
      content: [left, top, Math.max(0, width), Math.max(0, height), scale], src: element.src || '',
    };
  };

  // A page script setting value, checked or selected fires no event and no mutation: the
  // controls the last snapshot showed are read again each time.
  const controlState = (element) => (tagOf(element) === 'select'
    ? [...element.selectedOptions].map((option) => option.index).join(',')
    : `${element.checked} ${element.indeterminate} ${element.value}`);
  const controlStates = () => (frame.controls ?? []).map(controlState).join('\u0000');
  // Nor does a layout change: the boxes of what the last snapshot showed are read again, rules
  // added through the CSSOM counted, and nothing is taken as unchanged while something animates.
  // A custom element shown without a shadow root may attach one and render into it, which no
  // observer sees: whether each has one is read again too.
  const boxStates = () => (frame.shown ?? []).map((element) => (element?.isConnected
    ? round(element.getBoundingClientRect()).join(' ') + (element.shadowRoot ? ' s' : '') : '')).join(',');
  const sheetStates = () => [...document.styleSheets, ...(document.adoptedStyleSheets ?? [])].map((sheet) => {
    try { return sheet.cssRules.length; } catch { return -1; }
  }).join(',');
  const animating = () => document.getAnimations().some((animation) => animation.playState === 'running');

  // Snapshot
  const snapshot = ({ scope, since, key, of }) => {
    // `of`: the document Lithium's cached report came from, which a page Back restored may not be.
    // Focus going into a frame fires no focusin in its parent, whose activeElement still changes.
    // Nor does pushState fire anything, so the address is compared too.
    if (since === generation && key === frame.lastKey && of === frame.token && location.href === frame.url && controlStates() === frame.controlStates
      && sheetStates() === frame.sheetStates && !animating() && boxStates() === frame.boxStates && deepFocus() === frame.focused) {
      return { token: frame.token, unchanged: true, gen: generation, path: framePath() };
    }
    frame.lastKey = key;
    const controls = [];
    const view = viewport();
    const bottom = scope === 'page' ? Infinity : view.h * 2;
    const inScope = (box) => box[2] >= 1 && box[3] >= 1 && box[1] < bottom
      && (scope === 'page' || (box[1] + box[3] > 0 && box[0] < view.w && box[0] + box[2] > 0));
    const nodes = [];
    const frames = [];
    // Whether the document is a payment page (design section 7.3), in or out of scope.
    const pay = {};
    const focused = deepFocus();
    const indexes = frameIndexes();
    const styles = new Map();
    const styleOf = (element) => {
      let style = styles.get(element);
      if (!style) styles.set(element, (style = getComputedStyle(element)));
      return style;
    };
    // Text and inline elements of a block, up to its next block: all of it, and the part outside
    // links and buttons, which have nodes of their own. A block of links only repeats them.
    const inlineText = (element, inControl = false) => {
      let all = '';
      let own = '';
      for (const child of element.childNodes) {
        if (child.nodeType === Node.TEXT_NODE) {
          all += child.data;
          if (!inControl) own += child.data;
        } else if (child.nodeType === Node.ELEMENT_NODE) {
          if (skipped.has(child.localName) || textless.has(child.localName) || isExtensionUI(child) || child.getAttribute('aria-hidden') === 'true') continue;
          const style = styleOf(child);
          if (style.display === 'none' || style.opacity === '0' || style.visibility !== 'visible' || parseFloat(style.fontSize) < 6) continue;
          if (!isInline(style)) {
            all += ' ';
            continue;
          }
          const inner = inlineText(child, inControl || interactive.has(roleOf(child)));
          all += inner.all;
          own += inner.own;
        }
      }
      return { all, own };
    };
    const limit = 5000;
    const describe = (element, role, box, name) => {
      const node = { id: idOf(element), role, box };
      if (name) node.name = name;
      if (role === 'heading') {
        // An integer from 1 to 9, as Swift decodes it: aria-level="2.5" or "1e30" fails the whole snapshot.
        const level = Math.trunc(Number(element.getAttribute('aria-level')));
        node.level = level >= 1 ? Math.min(level, 9) : Number(element.localName[1]) || 2;
      }
      if (role === 'link' && element.getAttribute('href')) node.href = cut(element.getAttribute('href'), 160);
      const value = valueOf(element, role);
      if (value?.value) node.value = value.value;
      if (value?.filled) node.filled = true;
      const state = stateOf(element, role, focused);
      if (state.length) node.state = state;
      if (tagOf(element) === 'select') node.options = element.options.length;
      const guard = isField(element) ? guardOf(element) : null;
      if (guard) node.guard = guard;
      if (isField(element)) controls.push(element);
      return node;
    };
    // Inside text the user can't see (transparent, clipped away), only controls still operable
    // there are listed, never the text.
    const visitUnseen = (element, context) => {
      if (nodes.length >= limit) return;
      const tag = element.localName;
      if (skipped.has(tag) || isExtensionUI(element) || element.getAttribute('aria-hidden') === 'true') return;
      const style = styleOf(element);
      if (style.display === 'none' || style.contentVisibility === 'hidden') return;
      const clipped = context.clipped || clippedAway(element, style);
      const role = roleOf(element);
      const face = interactive.has(role) ? controlFace(element, style, context.clipped) : null;
      if (face) {
        if (isField(element) && isCard(element)) pay.cards = true;
        const box = round(face.getBoundingClientRect());
        if (inScope(box)) nodes.push(describe(element, role, box, controlName(element, role)));
      }
      if (textless.has(tag) || tag === 'svg') return;
      for (const child of childrenOf(element)) visitUnseen(child, { clipped });
    };
    const visit = (element, context) => {
      if (nodes.length >= limit) return;
      const tag = element.localName;
      if (skipped.has(tag) || isExtensionUI(element) || element.getAttribute('aria-hidden') === 'true') return;
      const style = styleOf(element);
      if (style.display === 'none' || style.contentVisibility === 'hidden') return;
      if (style.opacity === '0' || clippedAway(element, style)) {
        visitUnseen(element, { clipped: false });
        return;
      }
      const shown = style.visibility === 'visible';
      let role = roleOf(element);
      // A form or region is a landmark only when it has a name, as ARIA has it.
      if ((role === 'form' || role === 'region') && !element.getAttribute('aria-label') && !element.getAttribute('aria-labelledby') && !element.title) role = null;
      if (!role && shown && style.cursor === 'pointer' && context.cursor !== 'pointer' && !context.interactive) role = 'clickable';
      if (tag === 'iframe' || tag === 'frame') {
        if (!shown || isExtensionFrame(element)) return;
        const facts = frameFacts(element, style, indexes);
        frames.push(facts);
        if (inScope(facts.box)) nodes.push({ id: facts.id, role: 'frame', name: cut(collapse(element.title), 80) || undefined, box: facts.box, frame: facts.index });
        return;
      }
      const next = { ...context, cursor: style.cursor };
      const wallet = shown && isWallet(element, style);
      if (wallet) pay.wallet = true;
      if (shown && isField(element) && isCard(element)) pay.cards = true;
      const emitted = shown && role && (interactive.has(role) || structural.has(role) || role === 'clickable');
      if (emitted) {
        // A field off the page or shrunk to nothing shows through its label, if any.
        const face = isField(element) ? controlFace(element, style) : element;
        const box = face ? round(face.getBoundingClientRect()) : [0, 0, 0, 0];
        if (interactive.has(role) || role === 'clickable') next.interactive = true;
        if (namedByContent.has(role)) next.named = true;
        if (inScope(box)) {
          const node = describe(element, role, box, cut(nameOf(element, role), 80));
          if (wallet) node.wallet = true;
          nodes.push(node);
        }
      } else if (shown && !context.named && !isInline(style) && !textless.has(tag) && parseFloat(style.fontSize) >= 6) {
        const inline = inlineText(element);
        const text = collapse(inline.own) ? collapse(inline.all) : '';
        if (text) {
          const box = round(element.getBoundingClientRect());
          if (inScope(box)) nodes.push({ id: idOf(element), role: 'text', name: cut(text, 160), box });
        }
      }
      if (['select', 'textarea', 'svg', 'canvas', 'video', 'audio', 'object', 'embed'].includes(tag)) return;
      // A custom element that draws something with no children and no reachable shadow root
      // most likely has a closed one: agents act inside it by coordinates.
      if (shown && tag.includes('-') && !element.shadowRoot && element.childElementCount === 0 && !collapse(element.textContent)) {
        const box = round(element.getBoundingClientRect());
        if (box[2] >= 4 && box[3] >= 4 && inScope(box)) nodes.push({ id: idOf(element), role: 'shadow-closed', name: tag, box, wallet: wallet || undefined });
        return;
      }
      for (const child of childrenOf(element)) visit(child, next);
    };
    if (document.body) visit(document.body, { cursor: 'auto' });
    let focusedID;
    let focusedFrame;
    if (focused && focused !== document.body && focused !== document.documentElement) {
      if (focused.localName === 'iframe' || focused.localName === 'frame') focusedFrame = indexes.get(focused.contentWindow);
      else focusedID = idOf(focused);
    }
    frame.focused = focused;
    frame.controls = controls;
    frame.controlStates = controlStates();
    frame.shown = nodes.map((node) => elementOf(node.id));
    frame.boxStates = boxStates();
    frame.sheetStates = sheetStates();
    frame.url = location.href;
    return {
      token: frame.token, gen: generation, path: framePath(), url: frame.url, title: document.title, viewport: view,
      nodes, frames, focused: focusedID, focusedFrame, challenge: pageChallenge(), truncated: nodes.length >= limit, pay,
    };
  };

  // Masks for screenshots: fields that were ever passwords, card fields, and extension UI, in
  // this frame's viewport, plus where its frames sit so their own masks can be placed. With
  // `element` in this document (`of`), that element's box too, read with the masks.
  const masks = ({ element: id, of }) => {
    const rects = [];
    const frames = [];
    const indexes = frameIndexes();
    const claimed = new Set();
    const embeds = [];
    const add = (element) => {
      const rect = element.getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0) rects.push(round(rect));
    };
    for (const element of allElements(document)) {
      const tag = element.localName;
      if (isExtensionUI(element)) add(element);
      else if (isField(element) && guardOf(element)) add(element);
      else if (tag === 'iframe' || tag === 'frame' || (tag === 'object' && element.contentWindow)) {
        if (indexes.has(element.contentWindow)) claimed.add(indexes.get(element.contentWindow));
        if (isExtensionFrame(element)) add(element);
        else frames.push(frameFacts(element, getComputedStyle(element), indexes));
      } else if (tag === 'embed') embeds.push(element);
    }
    // An <embed> showing a document is in window.frames but gives no way to its window: while
    // a frame is unaccounted for, every <embed> counts as a frame that didn't answer.
    if (claimed.size < window.length) {
      for (const element of embeds) frames.push(frameFacts(element, getComputedStyle(element), indexes));
    }
    const element = of === frame.token ? elementOf(id) : null;
    return { token: frame.token, path: framePath(), viewport: viewport(), rects, frames, box: element ? round(element.getBoundingClientRect()) : undefined };
  };

  // Readable text, as lines, each with the block it came from: read_text, find_text, waits.
  const excludedFromMain = 'nav, footer, aside, header, dialog, menu, [role=navigation], [role=contentinfo], [role=complementary], [role=search], [role=banner], [role=dialog], [role=alertdialog], [aria-modal=true]';
  // `sources`: each line also gets `nodes`, the text node each of its characters comes from.
  const lines = (root, { markdown = false, main = false, sources = false } = {}) => {
    const out = [];
    let line = '';
    let pieces = [];
    let block = root;
    // Follows collapse(): a run of whitespace is one space, and none at either end.
    const nodesOf = () => {
      const nodes = [];
      let piece = -1;
      let space = true;
      for (let i = 0; i < line.length; i++) {
        while (piece + 1 < pieces.length && pieces[piece + 1].at <= i) piece++;
        const blank = /\s/.test(line[i]);
        if (!blank || !space) nodes.push(pieces[piece]?.node ?? null);
        space = blank;
      }
      if (space && nodes.length) nodes.pop();
      return nodes;
    };
    const flush = (prefix = '') => {
      const text = collapse(line);
      if (text) out.push(sources ? { text: prefix + text, element: block, nodes: [...prefix].map(() => null).concat(nodesOf()) } : { text: prefix + text, element: block });
      line = '';
      pieces = [];
    };
    const visit = (node, depth) => {
      if (node.nodeType === Node.TEXT_NODE) {
        if (sources) pieces.push({ node, at: line.length });
        line += node.data;
        return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      const element = node;
      const tag = element.localName;
      if (skipped.has(tag) || textless.has(tag) || isExtensionUI(element) || element.getAttribute('aria-hidden') === 'true') return;
      if (main && element !== root && element.matches(excludedFromMain) && !(tag === 'header' && element.closest('article, main'))) return;
      const style = getComputedStyle(element);
      if (style.display === 'none' || style.opacity === '0' || style.visibility !== 'visible' || style.contentVisibility === 'hidden'
        || parseFloat(style.fontSize) < 6 || clippedAway(element, style)) return;
      if (tag === 'br') {
        flush();
        return;
      }
      const isBlock = !isInline(style);
      if (isBlock) {
        flush();
        block = element;
      }
      // Cells and link text go through the same rules, so hidden text in them stays out too.
      const visibleText = (child, inMarkdown) => collapse(lines(child, { markdown: inMarkdown }).map((item) => item.text).join(' '));
      if (tagOf(element) === 'tr') {
        const cellLines = [...element.cells].map((cell) => lines(cell, { markdown, sources }));
        const cells = cellLines.map((items) => items.map((item) => item.text).join(' '));
        // Spacer rows (Hacker News has one between stories) have nothing to read.
        if (!cells.some(Boolean)) return;
        const row = { text: markdown ? `| ${cells.join(' | ')} |` : cells.join(' | '), element };
        if (sources) {
          row.nodes = (markdown ? [null, null] : []).concat(...cellLines.map((items, i) => (i ? [null, null, null] : [])
            .concat(...items.map((item, j) => (j ? [null] : []).concat(item.nodes)))));
        }
        out.push(row);
        return;
      }
      const href = markdown && tag === 'a' ? hrefOf(element) : '';
      if (href && !href.startsWith('javascript:')) {
        const text = visibleText(element, false);
        if (text) line += ` [${text}](${href}) `;
        return;
      }
      const children = element.shadowRoot ? [...element.shadowRoot.childNodes, ...element.childNodes] : element.childNodes;
      for (const child of children) visit(child, depth + 1);
      if (isBlock) {
        let prefix = '';
        if (markdown) {
          if (/^h[1-6]$/.test(tag)) prefix = `${'#'.repeat(Number(tag[1]))} `;
          else if (tag === 'li') prefix = '- ';
          else if (tag === 'blockquote') prefix = '> ';
        }
        flush(prefix);
        block = element.parentElement ?? root;
      }
    };
    visit(root, 0);
    flush();
    return out;
  };

  // The article or main element when it holds the page's content, as page-text.js picks it.
  const mainRoot = () => {
    const body = document.body;
    const length = (element) => (element.innerText || '').length;
    const total = length(body);
    const holdsContent = (element) => element && length(element) >= 500 && length(element) >= total * 0.25;
    const articles = [...document.querySelectorAll('article')].filter((article) => !article.parentElement.closest('article'));
    if (articles.length === 1 && holdsContent(articles[0])) return articles[0];
    const mainElement = document.querySelector('main, [role=main]');
    return holdsContent(mainElement) ? mainElement : body;
  };

  const readText = ({ id, main, format, maxChars }) => {
    const markdown = format === 'markdown';
    let root = document.body;
    if (id) {
      root = elementOf(id);
      if (!root) return { token: frame.token, gone: true };
    } else if (!root) {
      return { token: frame.token, text: '', truncated: false, title: document.title };
    }
    let found = lines(id ? root : main ? mainRoot() : root, { markdown, main: main && !id });
    // A page built only from what main leaves out still has text to read.
    if (main && !id) {
      const everything = lines(document.body, { markdown });
      const size = (list) => list.reduce((sum, item) => sum + item.text.length, 0);
      if (size(found) < size(everything) * 0.2) found = everything;
    }
    const text = found.map((item) => item.text).join('\n');
    return { token: frame.token, title: document.title, url: location.href, text: head(text, maxChars), truncated: text.length > maxChars };
  };

  const links = ({ filter }) => {
    const wanted = (filter || '').toLowerCase();
    const found = [];
    for (const element of allElements(document)) {
      const href = ['a', 'area'].includes(element.localName) ? hrefOf(element) : '';
      if (!href || !isVisible(element)) continue;
      const text = cut(nameOf(element, 'link'), 80);
      if (wanted && !text.toLowerCase().includes(wanted) && !href.toLowerCase().includes(wanted)) continue;
      found.push({ id: idOf(element), text, href });
      if (found.length >= 1000) break;
    }
    return { token: frame.token, links: found };
  };

  const fieldFacts = (element) => {
    const role = roleOf(element);
    const field = { id: idOf(element), role, name: controlName(element, role), type: element.type || element.localName };
    const value = valueOf(element, role);
    if (value?.value) field.value = value.value;
    if (value?.filled) field.filled = true;
    if (element.required) field.required = true;
    const guard = guardOf(element);
    if (guard) field.guard = guard;
    if (tagOf(element) === 'select') {
      // A card field's choices (expiry months and years) are fine; which one is chosen isn't.
      field.options = [...element.options].slice(0, 100).map((option) => {
        const item = { label: cut(collapse(option.label || option.text), 80) };
        if (option.selected && !guard) item.selected = true;
        return item;
      });
      if (element.options.length > 100) field.moreOptions = element.options.length - 100;
    }
    return field;
  };
  const isFormField = (element) => isField(element) && element.type !== 'hidden' && (isVisible(element) || Boolean(controlFace(element)));
  const isSubmit = (element) => (element.localName === 'button' && (element.type || 'submit') === 'submit')
    || (element.localName === 'input' && ['submit', 'image'].includes(element.type));
  const forms = () => {
    const found = [];
    const loose = [];
    for (const element of allElements(document)) {
      if (tagOf(element) === 'form') {
        if (!isVisible(element) && ![...element.elements].some(isFormField)) continue;
        let action = '';
        try { action = new URL(element.action, location.href).host; } catch {}
        found.push({
          id: idOf(element), name: cut(collapse(element.getAttribute('aria-label') || element.getAttribute('name') || element.id), 80),
          action, method: (element.method || 'get').toLowerCase(),
          fields: [...element.elements].filter(isFormField).map(fieldFacts),
          submits: [...element.elements].filter((control) => isSubmit(control) && isVisible(control)).map(idOf),
        });
      } else if (isFormField(element) && !element.form) {
        loose.push(fieldFacts(element));
      }
    }
    return { token: frame.token, forms: found, loose };
  };

  // The link or button a text node is in, up to the block its line comes from (often the list
  // item or paragraph around it), so a match's ref is one to click.
  const controlOf = (node, block) => {
    for (let element = node?.parentElement ?? node?.getRootNode?.()?.host; element; element = element.parentElement ?? element.getRootNode()?.host) {
      if (isControl(element)) return element;
      if (element === block) break;
    }
    return null;
  };
  const find = ({ text, caseSensitive, limit }) => {
    const matches = [];
    let count = 0;
    if (document.body && text) {
      // Matched in the line's own text, never a lowercased copy: 'İ' lowercases to two units,
      // which would shift every index after it onto the wrong node.
      const pattern = new RegExp(text.replace(/[\\^$.*+?()[\]{}|/]/g, '\\$&'), caseSensitive ? 'gu' : 'giu');
      for (const line of lines(document.body, { sources: true })) {
        for (const found of line.text.matchAll(pattern)) {
          const at = found.index;
          const length = found[0].length;
          count++;
          if (matches.length < limit) {
            // About 80 characters around the match, and the whole match with 10 on each side when it is longer.
            const around = Math.max(10, Math.floor((80 - length) / 2));
            const start = Math.max(0, at - around);
            // Nil for a match outside a control, or across two.
            const first = controlOf(line.nodes[at], line.element);
            const control = first === controlOf(line.nodes[at + length - 1], line.element) ? first : null;
            const match = { id: idOf(control ?? line.element), context: head(tail(line.text, start), Math.max(start + 80, at + length + around) - start) };
            if (control) match.role = roleOf(control);
            matches.push(match);
          }
        }
      }
    }
    return { token: frame.token, count, matches };
  };

  // What a point hits, through open shadow roots, and what covers an element there.
  const hitAt = (x, y) => {
    let hit = document.elementFromPoint(x, y);
    while (hit?.shadowRoot) {
      const inner = hit.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === hit) break;
      hit = inner;
    }
    return hit;
  };
  const contains = (outer, inner) => {
    for (let node = inner; node; node = node.parentElement ?? node.getRootNode()?.host) if (node === outer) return true;
    return false;
  };
  const inExtensionUI = (element) => {
    for (let node = element; node; node = node.parentElement ?? node.getRootNode()?.host) if (isExtensionUI(node)) return true;
    return false;
  };
  const cover = (hit) => {
    let owner = hit;
    for (let node = hit; node; node = node.parentElement ?? node.getRootNode()?.host) if (isExtensionUI(node)) owner = node;
    return {
      id: idOf(owner), tag: owner.localName + (owner.id ? `#${owner.id}` : ''),
      text: cut(textOf(owner), 40), extension: isExtensionUI(owner) || (/^i?frame$/.test(owner.localName) && isExtensionFrame(owner)),
    };
  };
  const hiddenReason = (element, rect) => {
    const style = getComputedStyle(element);
    if (!element.checkVisibility()) return style.display === 'none' ? 'display:none' : 'no box (an ancestor has display:none)';
    if (!element.checkVisibility({ visibilityProperty: true })) return 'visibility:hidden';
    if (hiddenByAncestor(element)) return 'aria-hidden';
    if (isControl(element)) {
      if (controlFace(element, style)) return null;
      const reason = tiny(rect) ? 'zero size' : offPage(rect) ? 'a box off the page' : 'clip (visually hidden)';
      return isField(element) ? `${reason} and no visible label` : reason;
    }
    if (!element.checkVisibility({ opacityProperty: true })) return 'opacity:0';
    if (rect.width < 1 || rect.height < 1) return 'zero size';
    return null;
  };

  // Element facts for element_info and the stale-ref check.
  const info = ({ id }) => {
    const element = elementOf(id);
    if (!element) return { token: frame.token, gone: true };
    const role = roleOf(element) || 'text';
    const hidden = hiddenReason(element, element.getBoundingClientRect());
    const face = !hidden && isControl(element) ? controlFace(element) ?? element : element;
    const rect = face.getBoundingClientRect();
    const facts = { token: frame.token, role, name: isControl(element) ? controlName(element, role) : cut(nameOf(element, role), 80), box: round(rect) };
    const guard = isField(element) ? guardOf(element) : null;
    if (guard) facts.guard = guard;
    facts.visible = !hidden;
    if (hidden) facts.hidden = hidden;
    if (!hidden) {
      const x = Math.min(Math.max(rect.left + rect.width / 2, 0), innerWidth - 1);
      const y = Math.min(Math.max(rect.top + rect.height / 2, 0), innerHeight - 1);
      facts.inViewport = rect.right > 0 && rect.bottom > 0 && rect.left < innerWidth && rect.top < innerHeight;
      if (facts.inViewport) {
        const hit = hitAt(x, y);
        if (hit && !contains(element, hit) && !contains(face, hit)) facts.coveredBy = cover(hit);
      }
    }
    return facts;
  };

  // Input (design section 5). Trusted events are counted in the capture phase, so Lithium knows
  // when the page has handled what it sent instead of waiting a fixed time.
  const counts = {};
  const counted = [];
  for (const type of ['mousemove', 'mousedown', 'mouseup', 'keyup', 'beforeinput', 'wheel']) {
    addEventListener(type, (event) => {
      if (!event.isTrusted) return;
      counts[type] = (counts[type] || 0) + 1;
      for (const waiter of [...counted]) waiter();
    }, { capture: true, passive: true });
  }
  // An agent's right click gives the page its contextmenu, never the native menu, which would
  // open on the user's screen and hold Lithium in its loop: the default is prevented on the
  // way back up, once the page's own listeners have run.
  addEventListener('contextmenu', (event) => {
    if (!event.isTrusted || !(frame.agentMenu > Date.now())) return;
    frame.agentMenu = 0;
    event.preventDefault();
  });
  // One rendering update, or a moment where frames don't run (a page out of any window).
  const nextFrame = () => new Promise((resolve) => {
    requestAnimationFrame(() => resolve());
    setTimeout(resolve, 100);
  });

  const textTypes = new Set(['text', 'search', 'email', 'url', 'tel', 'password', 'number', 'date', 'datetime-local', 'month', 'time', 'week']);
  const isEditable = (element) => (element.localName === 'input' && textTypes.has(element.type)) || element.localName === 'textarea' || element.isContentEditable;
  const formOf = (element) => {
    // closest('form') would also take a form of another namespace.
    let form = element.form;
    for (let node = element.parentElement; !form && node; node = node.parentElement) if (tagOf(node) === 'form') form = node;
    if (!form) return undefined;
    const fields = [...form.elements];
    return { id: idOf(form), cards: fields.some((field) => isField(field) && isCard(field)), password: fields.some((field) => isPassword(field) && field.value !== '') };
  };
  // A password field that isn't empty in the target's document, in any of its open shadow roots
  // (a design system's field and button are often in two components), whoever filled it: a
  // sign-in sent by a script from a plain button, a link, or Enter in a field outside any form
  // sends it as a form's submit would (design section 7.3).
  const passwordFilled = (element) => [...new Set([document, element.getRootNode()])].some((root) => {
    for (const field of allElements(root)) if (isPassword(field) && field.value !== '') return true;
    return false;
  });
  // Whether the document is a payment page (design section 7.3): card fields and wallet buttons
  // anywhere in it, and the frames it holds by address.
  const walletSelector = 'apple-pay-button, gpay-button, .gpay-button, button, [role=button], input[type=button], input[type=submit]';
  const payFacts = () => {
    const pay = {};
    for (const element of document.querySelectorAll('input, select, textarea')) {
      if (isCard(element) && (isVisible(element) || controlFace(element))) { pay.cards = true; break; }
    }
    for (const element of document.querySelectorAll(walletSelector)) {
      if (isWallet(element, getComputedStyle(element))) { pay.wallet = true; break; }
    }
    return pay;
  };
  const pay = () => ({
    token: frame.token, path: framePath(), pay: payFacts(), challenge: pageChallenge(),
    frames: [...document.querySelectorAll('iframe, frame')].map((element) => element.src).filter(Boolean),
  });

  // The element an action aims at, by ref (`id`) or by point (`x`, `y`, in this frame's
  // viewport), with every check of design section 5.1 this frame can make: scrolled into view
  // when needed, measured again a frame later when it moved since the last snapshot, the point
  // to press hit-tested. A point on a frame names the frame, for Lithium to look inside it.
  const target = async ({ id, x, y, scroll, known, menu }) => {
    if (menu) frame.agentMenu = Date.now() + 2000;
    const byPoint = id === undefined;
    const element = byPoint ? hitAt(x, y) : elementOf(id);
    const facts = { token: frame.token, path: framePath(), viewport: viewport(), counts: { ...counts } };
    if (!element) return { ...facts, gone: true };
    if (byPoint && /^i?frame$/.test(element.localName)) {
      const index = frameIndexes().get(element.contentWindow);
      if (isExtensionFrame(element)) facts.extensionUI = true;
      else if (index !== undefined) facts.frame = index;
      facts.src = element.src || '';
    }
    const role = roleOf(element) || (element.localName === 'body' ? 'page' : 'text');
    Object.assign(facts, { id: idOf(element), role, name: cut(nameOf(element, role), 80), tag: element.localName, type: element.type || undefined });
    const field = isField(element) ? guardOf(element) : null;
    if (field) facts.field = field;
    if (isWallet(element, getComputedStyle(element))) facts.wallet = true;
    facts.form = formOf(element);
    if (isSubmit(element)) facts.submit = true;
    if (passwordFilled(element)) facts.passwordFilled = true;
    if (isEditable(element)) facts.editable = true;
    if (element.localName === 'textarea' || (element.isContentEditable && element.localName !== 'input')) facts.multiline = true;
    if (element.readOnly && ['input', 'textarea'].includes(element.localName)) facts.readonly = true;
    if (element.disabled || element.getAttribute('aria-disabled') === 'true' || safeMatches(element, ':disabled')) facts.disabled = true;
    if (element === deepFocus()) facts.focused = true;
    if (element.checked === true || element.getAttribute('aria-checked') === 'true') facts.checked = true;
    if (element.closest('[draggable=true]') || (element.draggable && element.getAttribute('draggable') !== 'false' && ['a', 'img'].includes(element.localName))) facts.draggable = true;
    if (inExtensionUI(element)) facts.extensionUI = true;
    Object.assign(facts, pay());
    if (byPoint) {
      facts.point = [x, y];
      facts.box = round(element.getBoundingClientRect());
      return facts;
    }
    const hidden = hiddenReason(element, element.getBoundingClientRect());
    if (hidden) return { ...facts, hidden };
    // A visually hidden field is pressed where its label shows (`controlFace`).
    const face = isControl(element) ? controlFace(element) ?? element : element;
    let rect = face.getBoundingClientRect();
    const showing = (r) => r.right > 0 && r.bottom > 0 && r.left < innerWidth && r.top < innerHeight;
    const center = (r) => [r.left + r.width / 2, r.top + r.height / 2];
    const inside = ([px, py]) => px >= 0 && py >= 0 && px < innerWidth && py < innerHeight;
    if (scroll && !inside(center(rect))) {
      face.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
      rect = face.getBoundingClientRect();
    }
    const box = round(rect);
    // Stable: the same box a frame later, measured only when it differs from the last snapshot's.
    if (!known || known.some((value, index) => Math.abs(value - box[index]) > 1)) {
      await nextFrame();
      const again = round(face.getBoundingClientRect());
      if (again.some((value, index) => Math.abs(value - box[index]) > 1)) return { ...facts, box: again, unstable: true };
    }
    facts.box = box;
    facts.viewport = viewport();
    if (!showing(rect)) return { ...facts, inViewport: false };
    facts.inViewport = true;
    // The center of the largest visible rect, else a point of it that reaches the element.
    const clipped = [...face.getClientRects()].map((r) => {
      const left = Math.max(r.left, 0);
      const top = Math.max(r.top, 0);
      return { left, top, width: Math.min(r.right, innerWidth) - left, height: Math.min(r.bottom, innerHeight) - top };
    }).filter((r) => r.width > 0 && r.height > 0);
    const largest = clipped.sort((a, b) => b.width * b.height - a.width * a.height)[0] ?? rect;
    const points = [center(largest)];
    for (const [fx, fy] of [[0.25, 0.25], [0.75, 0.25], [0.25, 0.75], [0.75, 0.75]]) points.push([largest.left + largest.width * fx, largest.top + largest.height * fy]);
    // A label reaches its field only where no link or button inside it takes the click: its own text.
    const plain = (node) => {
      for (let current = node; current && current !== face; current = current.parentElement ?? current.getRootNode()?.host) if (isControl(current)) return false;
      return true;
    };
    if (face !== element) {
      const walker = document.createTreeWalker(face, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        if (!node.data.trim() || !plain(node.parentElement)) continue;
        const range = document.createRange();
        range.selectNodeContents(node);
        for (const r of range.getClientRects()) if (r.width > 0 && r.height > 0) points.push(center(r));
      }
    }
    const reaches = (hit) => contains(element, hit) || (contains(face, hit) && (face === element || plain(hit)));
    let firstHit = null;
    for (const point of points.filter(inside)) {
      const hit = hitAt(point[0], point[1]);
      firstHit ??= hit;
      if (hit && reaches(hit)) {
        facts.point = point;
        return facts;
      }
    }
    facts.point = points[0];
    if (firstHit && face !== element && contains(face, firstHit)) facts.notActionable = 'its label holds only links or buttons, which would take the click';
    else if (firstHit) facts.coveredBy = cover(firstHit);
    else facts.inViewport = false;
    return facts;
  };

  // In a parent frame: whether a point lands on the frame at `index` of window.frames, or what covers it.
  const frameHit = ({ x, y, index }) => {
    const hit = hitAt(x, y);
    const facts = { token: frame.token };
    if (hit && /^i?frame$/.test(hit.localName) && frameIndexes().get(hit.contentWindow) === index) return facts;
    if (hit) facts.coveredBy = cover(hit);
    return facts;
  };

  // The focused element, or the frame focus went into, for keys sent without a ref: its address,
  // and its origin when known. A frame of another origin is where its address says, unless that
  // is this document's own origin, which it then left.
  const focused = () => {
    const element = deepFocus();
    const facts = { token: frame.token, path: framePath(), counts: { ...counts } };
    if (!element || element === document.body || element === document.documentElement) return facts;
    if (/^i?frame$/.test(element.localName)) {
      let origin;
      try { origin = element.contentWindow.location.origin; } catch {
        try {
          const start = new URL(element.src).origin;
          if (start !== 'null' && start !== location.origin) origin = start;
        } catch {}
      }
      return { ...facts, frame: frameIndexes().get(element.contentWindow) ?? -1, src: element.src || '', origin };
    }
    return { ...facts, id: idOf(element) };
  };

  // Waits until the page has seen `count` trusted events of `type` (or `timeoutMs` passes), then
  // with `frame` one rendering update; with `scrolled`, until the scroll position holds for a
  // frame; with `hold`, until that many milliseconds after the call, so a load the events start
  // has begun (Lithium stops waiting as soon as one does: this document then never answers).
  const settle = async ({ type, count, timeoutMs, scrolled, frame: rendered, hold }) => {
    const called = performance.now();
    const seen = await new Promise((resolve) => {
      const check = () => {
        if ((counts[type] || 0) < count) return false;
        counted.splice(counted.indexOf(check), 1);
        clearTimeout(timer);
        resolve(true);
        return true;
      };
      const timer = setTimeout(() => {
        counted.splice(counted.indexOf(check), 1);
        resolve(false);
      }, timeoutMs);
      counted.push(check);
      check();
    });
    if (rendered) await nextFrame();
    if (scrolled) {
      const deadline = Date.now() + 500;
      let last = `${scrollX} ${scrollY}`;
      while (Date.now() < deadline) {
        await nextFrame();
        const now = `${scrollX} ${scrollY}`;
        if (now === last) break;
        last = now;
      }
    }
    const left = (hold || 0) - (performance.now() - called);
    if (left > 0) await new Promise((resolve) => setTimeout(resolve, left));
    return { token: frame.token, seen, counts: { ...counts } };
  };

  // A <select> without native input (design section 5.2): its pop-up menu would run a tracking
  // loop on the user's screen. Sets the options, then input and change, untrusted.
  const selectOption = ({ id, values, labels }) => {
    const element = elementOf(id);
    if (!element) return { token: frame.token, gone: true };
    if (tagOf(element) !== 'select') return { token: frame.token, notSelect: true };
    const options = [...element.options];
    const label = (option) => collapse(option.label || option.text);
    const wanted = values ?? labels;
    const picked = wanted.map((want) => options.find((option) => (values ? option.value === want : label(option) === collapse(want))));
    const missing = wanted.filter((_, index) => !picked[index]);
    if (missing.length) return { token: frame.token, missing, available: options.slice(0, 100).map(label) };
    if (!element.multiple && picked.length > 1) return { token: frame.token, single: true };
    if (element.multiple) options.forEach((option) => { option.selected = picked.includes(option); });
    else element.selectedIndex = picked[0].index;
    element.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
    return { token: frame.token, selected: [...element.selectedOptions].map(label) };
  };

  // Focus as tabbing into the element gives it: no input event.
  const focus = ({ id }) => {
    const element = elementOf(id);
    if (!element) return { token: frame.token, gone: true };
    element.focus({ preventScroll: false });
    return { token: frame.token, focused: deepFocus() === element };
  };

  // The caret at the end of the field a click just focused, so typing adds to what it holds.
  const caretEnd = ({ id }) => {
    const element = elementOf(id);
    if (!element) return { token: frame.token, gone: true };
    if (element.isContentEditable && element.localName !== 'input' && element.localName !== 'textarea') {
      const range = document.createRange();
      range.selectNodeContents(element);
      range.collapse(false);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
    } else {
      // Number and email fields have no selection to set.
      try { element.setSelectionRange(element.value.length, element.value.length); } catch {}
    }
    return { token: frame.token };
  };

  const scrollTo = ({ id }) => {
    const element = elementOf(id);
    if (!element) return { token: frame.token, gone: true };
    element.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
    return { token: frame.token, box: round(element.getBoundingClientRect()), viewport: viewport() };
  };

  // What a file input holds now, by name only, after an upload.
  const files = ({ id }) => {
    const element = elementOf(id);
    return { token: frame.token, names: element?.files ? [...element.files].map((file) => file.name) : undefined };
  };

  // DOM waits: re-checked when the document changes, never by polling faster than 4 times a
  // second for changes no observer sees (a style animating, say). A text check walks the whole
  // body and those of the frames it reaches, so it runs on that 4-a-second timer alone. Each
  // wait is kept under the key Lithium gave it, so the call that started it can end it.
  const waits = new Map();
  // Text in a document and the shown same-origin frames in it, which this world reaches as
  // `guards` does; a frame of another origin can't be read from here, and is counted instead.
  const textIn = (root, needle, depth) => {
    if (root.body && lines(root.body).some((line) => line.text.toLowerCase().includes(needle))) return { found: true, unread: 0 };
    let unread = 0;
    for (const element of root.querySelectorAll('iframe, frame')) {
      if (isExtensionFrame(element) || !isVisible(element)) continue;
      const inner = element.contentDocument;
      if (!inner) {
        unread++;
      } else if (depth < 4) {
        const framed = textIn(inner, needle, depth + 1);
        if (framed.found) return framed;
        unread += framed.unread;
      }
    }
    return { found: false, unread };
  };
  const wait = ({ id, state, text, present, timeoutMs, key }) => {
    const needle = text?.toLowerCase();
    let unread = 0;
    const check = () => {
      if (needle !== undefined) {
        const read = textIn(document, needle, 0);
        unread = read.unread;
        return read.found === present;
      }
      const element = elementOf(id);
      switch (state) {
        case 'attached': return Boolean(element);
        case 'detached': return !element;
        case 'visible': return Boolean(element) && isShown(element);
        case 'hidden': return !element || !isShown(element);
        // As click judges it: a control in a disabled fieldset is :disabled, not .disabled.
        case 'enabled': return Boolean(element) && !element.disabled && element.getAttribute('aria-disabled') !== 'true'
          && !safeMatches(element, ':disabled');
      }
      return false;
    };
    const answer = (met) => ({ token: frame.token, met, unread: unread || undefined });
    if (check()) return answer(true);
    return new Promise((resolve) => {
      let pending = false;
      const done = (met) => {
        waits.delete(key);
        observer?.disconnect();
        clearInterval(interval);
        clearTimeout(timer);
        resolve(answer(met));
      };
      const schedule = () => {
        if (pending) return;
        pending = true;
        setTimeout(() => {
          pending = false;
          if (check()) done(true);
        }, 30);
      };
      const observer = needle === undefined ? new MutationObserver(schedule) : null;
      observer?.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
      const interval = setInterval(() => { if (check()) done(true); }, 250);
      const timer = setTimeout(() => done(false), timeoutMs);
      if (key !== undefined) waits.set(key, done);
    });
  };
  // The call that started the wait ended (met elsewhere, timed out, stopped): no more checks.
  const cancelWait = ({ key }) => {
    waits.get(key)?.(false);
    return { token: frame.token };
  };

  // What a read checks before it reads: the page-wide check, and the frames a widget could be in.
  const challenge = () => ({
    token: frame.token,
    page: pageChallenge(),
    frames: [...document.querySelectorAll('iframe')].filter((element) => {
      const rect = element.getBoundingClientRect();
      return rect.width >= 20 && rect.height >= 20 && isVisible(element);
    }).map((element) => element.src).filter(Boolean),
  });

  // The network log without Lithium's resource load delegate: the document's performance
  // timeline, read when asked, so it costs nothing until then. No headers, and no status in
  // WebKits that leave `responseStatus` undefined.
  const resources = () => ({
    token: frame.token,
    entries: [...performance.getEntriesByType('navigation'), ...performance.getEntriesByType('resource')].map((entry) => ({
      url: entry.name, type: entry.initiatorType, start: Math.round(entry.startTime), ms: Math.round(entry.duration),
      status: entry.responseStatus || undefined, size: entry.transferSize || undefined,
    })),
  });

  // What `evaluate` needs before and after an agent's script. Any value in a password or card
  // field, a card field in use, or an extension's frame (password managers fill through them)
  // means the script doesn't run; same-origin child documents count, since the script can reach
  // them. The values go to Lithium alone, which also takes them out of what a script returns,
  // and the frames' addresses let it spot a payment provider's.
  const isSecretField = (element) => isField(element) && (isPassword(element) || isCard(element));
  const guards = () => {
    const secrets = new Set();
    const frames = [];
    let card = false;
    let manager = false;
    const visit = (root, depth) => {
      let focused = root.activeElement;
      while (focused?.shadowRoot?.activeElement) focused = focused.shadowRoot.activeElement;
      for (const element of allElements(root)) {
        if (/^i?frame$/.test(element.localName)) {
          if (isExtensionFrame(element)) manager = true;
          if (element.src) frames.push(element.src);
          let inner = null;
          try { inner = element.contentDocument; } catch { /* cross-origin */ }
          if (inner && depth < 4) visit(inner, depth + 1);
        } else if (isSecretField(element)) {
          const value = element.localName === 'select' ? (element.selectedIndex > 0 ? element.value : '') : element.value;
          if (value) secrets.add(value);
          if (!isPassword(element) && (value || element === focused)) card = true;
        }
      }
    };
    visit(document, 0);
    return { token: frame.token, path: framePath(), secrets: [...secrets], card, manager, frames };
  };
  // Hands `evaluate`'s world the element `id` names, by an event only that world listens for (a
  // random name, so the page can't). It goes to `document` when no element is asked for, and to
  // `window` when it is gone or is extension UI. The frame is checked again first, in the same
  // task as the hand-over, so no value typed since Lithium's check reaches the script; a frame
  // that holds one gets no event, and the script never runs.
  const handOver = ({ id, element: name }) => {
    const held = guards();
    if (held.secrets.length || held.card || held.manager) return { token: frame.token, blocked: true };
    if (id === undefined) {
      document.dispatchEvent(new CustomEvent(name));
      return { token: frame.token };
    }
    const element = elementOf(id);
    if (!element || inExtensionUI(element)) {
      window.dispatchEvent(new CustomEvent(name));
      return { token: frame.token, gone: !element, extensionUI: Boolean(element) };
    }
    element.dispatchEvent(new CustomEvent(name, { composed: true }));
    return { token: frame.token, found: true };
  };

  const operations = { snapshot, masks, readText, links, forms, find, info, wait, cancelWait, challenge, pay, target, frameHit, focused, settle, selectOption, focus, caretEnd, scrollTo, files, resources, guards, handOver };
  // A document WebKit parks in its back/forward cache runs no timer and no frame callback, so a
  // call still pending in it (a wait, a settle) would hold Lithium's reply, and the tab's web
  // view with it, until WebKit drops the page, even after the tab closed. It answers as gone.
  const parked = new Set();
  addEventListener('pagehide', (event) => {
    if (!event.persisted) return;
    for (const leave of [...parked]) leave();
    // Nobody waits for them any more: no checks after Back brings the page back.
    for (const done of [...waits.values()]) done(false);
  });
  globalThis.lithiumAgent = {
    run: async (operation, args) => {
      // An element call for a document that is no longer the one shown.
      if (args.token && args.token !== frame.token) return JSON.stringify({ token: frame.token, gone: true });
      let leave;
      const left = new Promise((resolve) => { leave = () => resolve({ token: frame.token, gone: true }); });
      parked.add(leave);
      try {
        const answer = await Promise.race([operations[operation](args), left]);
        // A lone surrogate the page wrote itself comes back replaced, not in an answer Swift refuses.
        return JSON.stringify(answer, (key, value) => (typeof value === 'string' && !value.isWellFormed() ? value.toWellFormed() : value));
      } finally {
        parked.delete(leave);
      }
    },
  };
})();
