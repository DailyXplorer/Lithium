// Max: a button in the text field being written in, and ⌥⌘K, that fix its spelling and grammar
// (TextCorrections.swift). Runs in Lithium's own content world: pages can't see or press it.
(() => {
  const handler = window.webkit?.messageHandlers?.lithiumCorrect;
  if (!handler || window.lithiumTextCorrection) return;

  const SIZE = 22;
  const INSET = 6;
  const MINIMUM_WORDS = 3;
  // Quoted replies, signatures and code blocks aren't the person's prose to correct.
  const SKIPPED = 'blockquote, pre, [contenteditable="false"], .gmail_quote, .gmail_signature, [data-smartmail="gmail_signature"], script, style, noscript, template';
  const BLOCKS = new Set(['ADDRESS', 'ARTICLE', 'ASIDE', 'BLOCKQUOTE', 'BR', 'DD', 'DIV', 'DL', 'DT', 'FIGCAPTION', 'FIGURE', 'FOOTER', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'HEADER', 'HR', 'LI', 'MAIN', 'NAV', 'OL', 'P', 'PRE', 'SECTION', 'TABLE', 'TD', 'TH', 'TR', 'UL']);

  // A field is a textarea (plain) or the root of a rich text editor. One-line inputs, code
  // editors and hidden helper textareas don't count. Spellchecking being off says nothing:
  // Gmail turns it off in its message body, since it has its own.
  const CODE_EDITORS = '.cm-editor, .CodeMirror, .monaco-editor, .ace_editor';
  const CODE_FONT = /^(monospace|menlo|monaco|consolas|courier( new)?|lucida console|fira code|source code pro|cascadia (code|mono))$|\bmono$/i;
  const isCode = (element) => !!element.closest(CODE_EDITORS)
    || getComputedStyle(element).fontFamily.split(',').some((family) => CODE_FONT.test(family.trim().replace(/^["']|["']$/g, '')));
  const fieldOf = (node) => {
    let element = node instanceof Element ? node : node?.parentElement;
    if (!element) return null;
    if (element instanceof HTMLTextAreaElement) {
      return element.readOnly || element.disabled || isCode(element) ? null : { kind: 'plain', element };
    }
    if (!element.isContentEditable) return null;
    while (element.parentElement?.isContentEditable) element = element.parentElement;
    return isCode(element) ? null : { kind: 'rich', element };
  };

  // A rich editor's text nodes in order, with null where a block or line break falls. Inline
  // code comes as a string: the model reads it with its sentence, but no change lands in it.
  function* walk(node) {
    for (let child = node.firstChild; child; child = child.nextSibling) {
      if (child.nodeType === Node.TEXT_NODE) {
        // Whitespace from the HTML source between blocks isn't text anyone typed.
        if (child.data && !(child.data.includes('\n') && !child.data.trim())) yield child;
      } else if (child.nodeType === Node.ELEMENT_NODE) {
        const skipped = child.matches(SKIPPED);
        if (!skipped && child.tagName === 'CODE') {
          if (child.textContent) yield child.textContent;
          continue;
        }
        const block = skipped || BLOCKS.has(child.tagName);
        if (block) yield null;
        if (!skipped) yield* walk(child);
        if (block) yield null;
      }
    }
  }

  // A rich editor's text, one line per block or line break, and where each text node sits in it.
  const readRich = (root) => {
    const segments = [];
    let text = '';
    let broken = false;
    for (const node of walk(root)) {
      if (!node) {
        broken = true;
        continue;
      }
      if (broken && text) text += '\n';
      broken = false;
      if (typeof node === 'string') {
        text += node;
        continue;
      }
      segments.push({ node, start: text.length, end: text.length + node.data.length });
      text += node.data;
    }
    return { text, segments };
  };

  const read = (field) => (field.kind === 'plain' ? field.element.value : readRich(field.element).text);

  const same = (a, b) => a.replace(/ /g, ' ') === b.replace(/ /g, ' ');

  // Counts only what gets corrected (a signature or a quoted reply alone shows no button), and
  // stops at the third word, since a rich editor can hold a long document.
  const hasWords = (field) => {
    let count = 0;
    for (const text of field.kind === 'plain' ? [field.element.value] : walk(field.element)) {
      if (!text) continue;
      for (const _ of (typeof text === 'string' ? text : text.data).matchAll(/[\p{L}\p{N}]+/gu)) {
        if (++count >= MINIMUM_WORDS) return true;
      }
    }
    return false;
  };

  // A textarea takes every change at once, from the first to the last, so one ⌘Z undoes them.
  const applyPlain = (element, text, edits) => {
    const from = edits[0][0];
    const to = edits[edits.length - 1][1];
    let replacement = '';
    let cursor = from;
    for (const [start, end, value] of edits) {
      replacement += text.slice(cursor, start) + value;
      cursor = end;
    }
    replacement += text.slice(cursor, to);
    const moved = (offset) => {
      let delta = 0;
      for (const [start, end, value] of edits) {
        if (end <= offset) delta += value.length - (end - start);
        else if (start < offset) return start + delta + value.length;
      }
      return offset + delta;
    };
    const { selectionStart, selectionEnd, scrollTop } = element;
    element.setSelectionRange(from, to);
    if (!document.execCommand('insertText', false, replacement)) {
      element.setRangeText(replacement, from, to);
      element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText' }));
    }
    element.setSelectionRange(moved(selectionStart), moved(selectionEnd));
    element.scrollTop = scrollTop;
    return { count: edits.length, ranges: [] };
  };

  // A rich editor gets each change on its own, as typed text, so formatting, links and the
  // editor's own model stay intact. Last to first: earlier offsets stay valid.
  const applyRich = async (root, original, edits) => {
    const selection = getSelection();
    const caret = selection.rangeCount && root.contains(selection.anchorNode) ? selection.getRangeAt(0).cloneRange() : null;
    const ranges = [];
    let count = 0;
    let asked = false;
    let grouped = false;
    for (let index = edits.length - 1; index >= 0; index--) {
      const [from, to, value] = edits[index];
      const { text, segments } = readRich(root);
      if (!same(text.slice(0, to), original.slice(0, to))) continue;
      const segment = segments.find((candidate) => candidate.start <= from && to <= candidate.end);
      if (!segment) continue;
      if (!asked) {
        asked = true;
        grouped = (await handler.postMessage({ undo: 'begin' })) === true;
      }
      const range = document.createRange();
      range.setStart(segment.node, from - segment.start);
      range.setEnd(segment.node, to - segment.start);
      selection.removeAllRanges();
      selection.addRange(range);
      if (!document.execCommand(value ? 'insertText' : 'delete', false, value)) continue;
      count += 1;
      const after = selection.rangeCount ? selection.getRangeAt(0) : null;
      if (value && after?.collapsed && after.startContainer.nodeType === Node.TEXT_NODE && after.startOffset >= value.length) {
        const inserted = document.createRange();
        inserted.setStart(after.startContainer, after.startOffset - value.length);
        inserted.setEnd(after.startContainer, after.startOffset);
        ranges.push(inserted);
      }
      // Editors that redraw after the input event get to do it before the next change.
      await new Promise((resolve) => setTimeout(resolve));
    }
    if (grouped) await handler.postMessage({ undo: 'end' });
    if (caret && caret.startContainer.isConnected) {
      selection.removeAllRanges();
      selection.addRange(caret);
    }
    return { count, ranges };
  };

  const flash = (ranges) => {
    if (!ranges.length || !window.CSS?.highlights || !window.Highlight) return;
    if (!flash.sheet) {
      flash.sheet = new CSSStyleSheet();
      flash.sheet.replaceSync('::highlight(lithium-corrected) { background-color: rgb(52 199 89 / 0.3); }');
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, flash.sheet];
    }
    CSS.highlights.set('lithium-corrected', new Highlight(...ranges));
    clearTimeout(flash.timer);
    flash.timer = setTimeout(() => CSS.highlights.delete('lithium-corrected'), 1600);
  };

  const activeElement = () => {
    let active = document.activeElement;
    while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement;
    return active;
  };

  const focused = (field) => {
    const active = activeElement();
    return !!active && (active === field.element || field.element.contains(active));
  };

  let field = null;
  // idle, working, or a note after a correction: { text, good }.
  let state = 'idle';
  let noteTimer = 0;

  const run = async (target) => {
    if (state === 'working') return null;
    const text = read(target);
    if (!/\p{L}/u.test(text)) return null;
    setState('working');
    let reply;
    try {
      reply = await handler.postMessage({ text });
    } catch {
      reply = { error: 'The correction didn’t work this time.' };
    }
    let note;
    if (reply?.error) note = { text: reply.error, good: false };
    else if (!focused(target)) note = null;
    else if (!same(read(target), text)) note = { text: 'The text changed meanwhile. Try again.', good: false };
    else if (!reply?.edits?.length) note = { text: 'No mistakes found', good: true };
    else {
      const { count, ranges } = target.kind === 'plain' ? applyPlain(target.element, text, reply.edits) : await applyRich(target.element, text, reply.edits);
      flash(ranges);
      note = count ? { text: count === 1 ? '1 fix' : `${count} fixes`, good: true } : { text: 'Couldn’t change this text', good: false };
    }
    setState(note ?? 'idle');
    return note?.text ?? null;
  };

  // Made the first time a field is focused: most pages and frames never need it.
  let view = null;
  const makeView = () => {
    const host = document.createElement('lithium-text-correction');
    const style = { all: 'initial', position: 'fixed', inset: 'auto', margin: '0', padding: '0', border: '0', background: 'transparent', overflow: 'visible', width: `${SIZE}px`, height: `${SIZE}px`, 'z-index': '2147483647' };
    for (const [name, value] of Object.entries(style)) host.style.setProperty(name, value, 'important');
    host.setAttribute('popover', 'manual');
    const shadow = host.attachShadow({ mode: 'closed' });
    // A constructed sheet, which a page's content security policy can't turn away.
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(`
      button {
        all: initial; box-sizing: border-box; width: ${SIZE}px; height: ${SIZE}px; border-radius: 50%;
        display: grid; place-items: center; cursor: default; color: #3c3c43;
        background: rgb(255 255 255 / 0.92); box-shadow: 0 0 0 0.5px rgb(0 0 0 / 0.18), 0 1px 3px rgb(0 0 0 / 0.14);
        opacity: 0.8; transition: opacity 0.15s, transform 0.15s;
      }
      button:hover { opacity: 1; transform: scale(1.06); }
      svg { width: 13px; height: 13px; }
      .spinner { display: none; width: 11px; height: 11px; border-radius: 50%; border: 1.6px solid currentColor; border-right-color: transparent; animation: spin 0.7s linear infinite; }
      .working svg { display: none; }
      .working .spinner { display: block; }
      .note {
        position: absolute; right: ${SIZE + 5}px; top: 50%; transform: translateY(-50%); white-space: nowrap;
        font: 500 11.5px/1 -apple-system, system-ui, sans-serif; padding: 5px 8px; border-radius: 11px;
        color: #fff; background: rgb(40 40 44 / 0.92); pointer-events: none; opacity: 0; transition: opacity 0.2s;
      }
      .note.shown { opacity: 1; }
      .note.good::before { content: "✓ "; color: #5de07c; }
      @keyframes spin { to { transform: rotate(360deg); } }
      @media (prefers-color-scheme: dark) {
        button { color: #ebebf5; background: rgb(58 58 62 / 0.94); box-shadow: 0 0 0 0.5px rgb(255 255 255 / 0.16), 0 1px 3px rgb(0 0 0 / 0.4); }
      }
    `);
    shadow.adoptedStyleSheets = [sheet];
    shadow.innerHTML = `
      <button title="Fix spelling and grammar (⌥⌘K)" aria-label="Fix spelling and grammar">
        <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
          <path d="M1.5 12.5 4.5 3.5l3 9M2.6 9.4h3.8"/><path d="m9.5 10.5 2 2 3.5-5"/>
        </svg>
        <span class="spinner"></span>
      </button>
      <span class="note"></span>`;
    const button = shadow.querySelector('button');
    button.addEventListener('mousedown', (event) => event.preventDefault());
    button.addEventListener('click', (event) => {
      event.preventDefault();
      if (field && event.isTrusted) run(field);
    });
    return { host, button, note: shadow.querySelector('.note') };
  };

  function setState(next) {
    state = next;
    clearTimeout(noteTimer);
    if (typeof next === 'object') noteTimer = setTimeout(() => setState('idle'), next.good ? 1800 : 3500);
    render();
    update();
  }

  function render() {
    if (!view) return;
    const note = typeof state === 'object' ? state : null;
    view.button.classList.toggle('working', state === 'working');
    view.note.textContent = note?.text ?? '';
    view.note.classList.toggle('shown', !!note);
    view.note.classList.toggle('good', !!note?.good);
  }

  let frame = 0;
  function update() {
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      place();
    });
  }

  const hide = () => view?.host.remove();

  function place() {
    if (field?.changed) {
      field.changed = false;
      field.wordy = hasWords(field);
    }
    if (!field || !field.element.isConnected || (state === 'idle' && !field.wordy)) return hide();
    const element = field.element;
    const rect = element.getBoundingClientRect();
    if (rect.width < 120 || rect.height < 18 || rect.bottom <= 0 || rect.top >= innerHeight) return hide();
    // Inside the borders and the scroll bar, clear of a textarea's resize grip.
    const right = rect.left + element.clientLeft + (element.clientWidth || rect.width);
    const bottom = Math.min(rect.top + element.clientTop + (element.clientHeight || rect.height), innerHeight);
    const grip = field.kind === 'plain' && getComputedStyle(element).resize !== 'none' ? 10 : 0;
    const short = bottom - Math.max(rect.top, 0) < SIZE + INSET * 2;
    const top = short ? Math.max(rect.top, 0) + (bottom - Math.max(rect.top, 0) - SIZE) / 2 : bottom - SIZE - INSET;
    if (!view) {
      view = makeView();
      render();
    }
    const { host } = view;
    host.style.setProperty('left', `${Math.round(right - SIZE - INSET - grip)}px`, 'important');
    host.style.setProperty('top', `${Math.round(top)}px`, 'important');
    if (!host.isConnected) {
      document.documentElement.append(host);
      try { host.showPopover(); } catch {}
    }
  }

  // The words are counted again on the next frame after the field's text changes, including
  // when the page changes it itself (a chat box emptied once its message is sent).
  const changed = () => {
    if (!field) return;
    field.changed = true;
    update();
  };

  let resizes = null;
  let edits = null;
  let polling = 0;
  const setField = (next) => {
    if (next?.element === field?.element) return;
    if (field) resizes.unobserve(field.element);
    edits?.disconnect();
    clearInterval(polling);
    field = next;
    if (field) {
      field.changed = true;
      (resizes ??= new ResizeObserver(update)).observe(field.element);
      if (field.kind === 'rich') {
        (edits ??= new MutationObserver(changed)).observe(field.element, { childList: true, subtree: true, characterData: true });
      } else {
        // A script setting a textarea's value leaves no trace in the page to observe.
        let value = field.element.value;
        polling = setInterval(() => {
          if (field?.element.value === value) return;
          value = field?.element.value;
          changed();
        }, 500);
      }
    }
    if (state !== 'working') setState('idle');
    update();
  };

  const target = (event) => event.composedPath()[0];
  document.addEventListener('focusin', (event) => setField(fieldOf(target(event))), true);
  document.addEventListener('focusout', () => setTimeout(() => setField(fieldOf(activeElement()))), true);
  document.addEventListener('input', changed, true);
  addEventListener('scroll', () => field && update(), { capture: true, passive: true });
  addEventListener('resize', () => field && update());
  document.addEventListener('keydown', (event) => {
    if (event.code !== 'KeyK' || !event.metaKey || !event.altKey || event.ctrlKey || event.shiftKey || !event.isTrusted) return;
    const current = fieldOf(target(event));
    if (!current) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    setField(current);
    run(current);
  }, true);

  window.lithiumTextCorrection = { run: (element) => { const found = fieldOf(element); return found ? run(found) : null; }, read: (element) => read(fieldOf(element)) };
})();
