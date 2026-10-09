// Run before an extension's background (ExtensionCompatibility). Chrome Web Store builds use
// Chrome APIs WebKit doesn't have yet without checking for them: 1Password's background stopped at
// chrome.notifications.onClicked. These are inert stand-ins, added only where missing, so WebKit's
// own APIs win once it has them.

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

  // A `types.ChromeSetting` the extension can set, which changes nothing.
  const setting = (value) => ({
    get: answer({ value, levelOfControl: 'controllable_by_this_extension' }), set: answer(undefined), clear: answer(undefined), onChange: event(),
  });
  // Chrome has these only for an extension that asks for them.
  const byPermission = {
    notifications: () => ({
      onClicked: event(), onButtonClicked: event(), onClosed: event(), onPermissionLevelChanged: event(), onShowSettings: event(),
      create: answer(''), update: answer(false), clear: answer(false), getAll: answer({}), getPermissionLevel: answer('denied'),
    }),
    privacy: () => ({
      services: { passwordSavingEnabled: setting(false), autofillAddressEnabled: setting(false), autofillCreditCardEnabled: setting(false) },
      network: { networkPredictionEnabled: setting(false), webRTCIPHandlingPolicy: setting('default') },
      websites: { thirdPartyCookiesAllowed: setting(false), hyperlinkAuditingEnabled: setting(false), doNotTrackEnabled: setting(false) },
    }),
    // Lithium tells `locked` and `active` through a port (Extensions.listenForIdle); `idle` is never
    // told. Without native messaging the state stays `active`.
    idle: (api) => {
      const listeners = new Set();
      let state = 'active';
      let connected;
      const connect = () => connected ??= new Promise((resolve) => {
        let port;
        try { port = api.runtime.connectNative('lithium.idle'); } catch { return resolve(); }
        port.onMessage.addListener((message) => {
          if (typeof message?.state !== 'string') return;
          const changed = message.state !== state;
          state = message.state;
          resolve();
          if (changed) for (const listener of [...listeners]) listener(state);
        });
        port.onDisconnect.addListener(() => {
          connected = undefined;
          resolve();
        });
      });
      return {
        onStateChanged: {
          addListener(listener) { listeners.add(listener); connect(); },
          removeListener(listener) { listeners.delete(listener); },
          hasListener(listener) { return listeners.has(listener); },
          hasListeners() { return listeners.size > 0; },
        },
        queryState: (...args) => {
          const result = connect().then(() => state);
          const callback = args.findLast((arg) => typeof arg === 'function');
          if (!callback) return result;
          result.then(callback);
        },
        setDetectionInterval() {}, getAutoLockDelay: answer(0),
      };
    },
    management: (api) => {
      const manifest = api.runtime.getManifest();
      const self = { id: api.runtime.id, name: manifest.name, shortName: manifest.short_name ?? manifest.name, version: manifest.version, enabled: true, type: 'extension', installType: 'normal', mayDisable: true };
      return { onInstalled: event(), onUninstalled: event(), onEnabled: event(), onDisabled: event(), getSelf: answer(self), getAll: answer([self]) };
    },
  };

  for (const api of new Set([globalThis.browser, globalThis.chrome])) {
    if (!api) continue;
    const permissions = api.runtime?.getManifest?.().permissions ?? [];
    for (const [name, make] of Object.entries(byPermission)) {
      if (permissions.includes(name)) fill(api, { [name]: make(api) });
    }
    fill(api.runtime, { setUninstallURL: answer(undefined) });
    fill(api.webNavigation, { onCreatedNavigationTarget: event() });
    fill(api.storage, { managed: { get: answer({}), getBytesInUse: answer(0), onChanged: event() } });
  }
  Object.defineProperty(globalThis, Symbol('lithium.compat'), { value: held });
})();
