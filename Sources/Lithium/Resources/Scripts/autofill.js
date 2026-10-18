// Lithium's passwords, in a world of their own the page can neither see nor call. At rest it only
// listens for focus and submit; it reads the page once a sign-in field is focused. It never fills
// by itself: `lithiumFill` is called by Lithium alone, after a click on its own list.
(() => {
  const post = (message) => webkit.messageHandlers.lithiumPasswords.postMessage(message);
  const TEXT_TYPES = new Set(['text', 'email', 'tel']);
  const SIGN_UP = /sign.?up|regist|create.?account|new.?account|change.?password|new.?password/i;
  let current = null;
  let watching = false;
  let listening = false;

  const target = (event) => event.composedPath()[0];
  const autocomplete = (field) => (field.getAttribute('autocomplete') || '').toLowerCase();
  const visible = (field) => {
    if (!field.isConnected || field.type === 'hidden' || field.disabled || field.readOnly) return false;
    const rect = field.getBoundingClientRect();
    return rect.width >= 1 && rect.height >= 1 && field.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
  };
  const rootOf = (field) => field.form || document;
  const passwords = (root) => [...root.querySelectorAll('input[type=password]')].filter(visible);

  // Two or more password fields are a new one and its confirmation; three start with the current one.
  const isNew = (field, all) => {
    const hint = autocomplete(field);
    if (hint.includes('new-password')) return true;
    if (hint.includes('current-password')) return false;
    if (all.length >= 3) return field !== all[0];
    if (all.length === 2) return true;
    const form = field.form;
    return !!form && SIGN_UP.test([form.id, form.name, form.className, form.getAttribute('action') || ''].join(' '));
  };

  // The field marked for it, else the last text field before the first password field.
  const usernameIn = (root, all) => {
    if (!all.length) return null;
    const inputs = [...root.querySelectorAll('input')];
    const marked = inputs.find((field) => /\b(username|email)\b/.test(autocomplete(field)) && visible(field));
    if (marked) return marked;
    for (let index = inputs.indexOf(all[0]) - 1; index >= 0; index--) {
      if (TEXT_TYPES.has(inputs[index].type) && visible(inputs[index])) return inputs[index];
    }
    return null;
  };

  const kindOf = (field) => {
    if (!(field instanceof HTMLInputElement) || !visible(field)) return null;
    const all = passwords(rootOf(field));
    if (field.type === 'password') return isNew(field, all) ? 'new-password' : 'password';
    if (!TEXT_TYPES.has(field.type) || !all.length) return null;
    return usernameIn(rootOf(field), all) === field ? 'username' : null;
  };

  const hide = () => {
    if (!watching) return;
    watching = false;
    removeEventListener('scroll', hide, true);
    removeEventListener('resize', hide);
    removeEventListener('input', typed, true);
    post({ type: 'blur' });
  };
  // Typing means the user isn't picking from the list. Lithium's own fill isn't typing.
  const typed = (event) => {
    if (event.isTrusted && current && target(event) === current.field) hide();
  };

  const submitted = (root) => {
    const all = passwords(root).filter((field) => field.value);
    if (!all.length) return;
    const fresh = all.find((field) => isNew(field, all));
    const user = usernameIn(root, passwords(root));
    post({ type: 'submit', username: user ? user.value : '', password: (fresh || all[0]).value });
  };

  // A sign-in sent by script, without a form submit: Return in its field, or a click on its button.
  const keyed = (event) => {
    if (!event.isTrusted || event.key !== 'Enter') return;
    const field = target(event);
    if (field instanceof HTMLInputElement && kindOf(field)) submitted(rootOf(field));
  };
  const clicked = (event) => {
    if (!event.isTrusted || !(event.target instanceof Element)) return;
    const button = target(event).closest?.('button, input[type=submit], input[type=button], [role=button]');
    if (!button) return;
    const root = button.form || button.closest('form') || document;
    if (passwords(root).length) submitted(root);
  };

  addEventListener('focusin', (event) => {
    if (!event.isTrusted) return;
    const field = target(event);
    const kind = kindOf(field);
    if (!kind) {
      hide();
      return;
    }
    current = { field, kind };
    if (!listening) {
      listening = true;
      addEventListener('keydown', keyed, true);
      addEventListener('click', clicked, true);
    }
    const rect = field.getBoundingClientRect();
    post({
      type: 'focus', kind,
      rect: { x: rect.x, y: rect.y, w: rect.width, h: rect.height },
      viewport: { x: visualViewport.offsetLeft, y: visualViewport.offsetTop, scale: visualViewport.scale },
    });
    if (!watching) {
      watching = true;
      addEventListener('scroll', hide, { capture: true, passive: true });
      addEventListener('resize', hide, { passive: true });
      addEventListener('input', typed, true);
    }
  }, true);

  addEventListener('submit', (event) => {
    const form = target(event);
    if (form instanceof HTMLFormElement) submitted(form);
  }, true);

  // Fills the focused field's form. Hidden fields stay empty, and a page on another host gets nothing.
  globalThis.lithiumFill = (host, username, password, generated) => {
    if (location.hostname !== host || !current || !current.field.isConnected) return false;
    const root = rootOf(current.field);
    const all = passwords(root);
    let filled = 0;
    const set = (field, value) => {
      if (!field || !visible(field)) return;
      field.value = value;
      field.dispatchEvent(new Event('input', { bubbles: true }));
      field.dispatchEvent(new Event('change', { bubbles: true }));
      filled += 1;
    };
    if (generated) {
      const fresh = all.filter((field) => isNew(field, all));
      (fresh.length ? fresh : [current.field]).forEach((field) => set(field, password));
    } else {
      set(current.kind === 'password' ? current.field : all.find((field) => !isNew(field, all)) || all[0], password);
      if (username) set(usernameIn(root, all), username);
    }
    hide();
    return filled > 0;
  };
})();
