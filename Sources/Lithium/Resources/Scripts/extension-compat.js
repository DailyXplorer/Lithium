// Run by Lithium before an extension's background (ExtensionCompatibility). Chrome Web Store
// builds use Chrome APIs WebKit doesn't have yet as soon as they start, without checking for
// them: 1Password's background stopped at chrome.notifications.onClicked, and nothing answered
// its content scripts. These are added as Chrome has them for an extension that gets nothing
// from them: notifications never show, no managed policy, no window opened from a page reported.
// Only what is missing is added, so WebKit's own APIs win once it has them.

(() => {
  const event = () => ({ addListener() {}, removeListener() {}, hasListener() { return false; }, hasListeners() { return false; } });
  // Chrome's functions take a callback or return a promise.
  const answer = (value) => (...args) => {
    const callback = args.findLast((arg) => typeof arg === 'function');
    if (!callback) return Promise.resolve(value);
    setTimeout(() => callback(value));
  };

  // WebKit makes a namespace's object again once nothing holds it, without what was added to it.
  const held = [];
  const fill = (object, members) => {
    if (!object) return;
    held.push(object);
    for (const [key, value] of Object.entries(members)) {
      if (object[key] === undefined) Object.defineProperty(object, key, { value, configurable: true, writable: true });
    }
  };

  for (const api of new Set([globalThis.browser, globalThis.chrome])) {
    if (!api) continue;
    // Chrome has it only for an extension that asks for it.
    if (api.runtime?.getManifest?.().permissions?.includes('notifications')) {
      fill(api, {
        notifications: {
          onClicked: event(), onButtonClicked: event(), onClosed: event(), onPermissionLevelChanged: event(), onShowSettings: event(),
          create: answer(''), update: answer(false), clear: answer(false), getAll: answer({}), getPermissionLevel: answer('denied'),
        },
      });
    }
    fill(api.webNavigation, { onCreatedNavigationTarget: event() });
    fill(api.storage, { managed: { get: answer({}), getBytesInUse: answer(0), onChanged: event() } });
  }
  Object.defineProperty(globalThis, Symbol('lithium.compat'), { value: held });
})();
