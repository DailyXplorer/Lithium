// The Chrome Web Store's Add to Chrome button, in Lithium. Runs in the store's own page world,
// since the store's code calls `chrome.webstorePrivate` and `chrome.management` itself. Lithium
// answers through `WebstoreBridge`, asks before adding anything and downloads from Google.
(() => {
  const bridge = window.webkit?.messageHandlers?.lithiumWebstore;
  if (!bridge || window.top !== window) return;

  // Below Chrome 142.0.7430 the store judges the browser by its user agent alone.
  const major = '__CHROME_VERSION__'.split('.')[0];
  const userAgent = `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${major}.0.0.0 Safari/537.36`;
  Object.defineProperty(navigator, 'userAgent', { configurable: true, get: () => userAgent });
  Object.defineProperty(navigator, 'appVersion', { configurable: true, get: () => userAgent.slice('Mozilla/'.length) });

  const chrome = window.chrome ?? (window.chrome = {});
  const runtime = chrome.runtime ?? (chrome.runtime = {});

  const listeners = {};
  const event = (name) => {
    const set = listeners[name] = new Set();
    return {
      addListener: (listener) => { set.add(listener); },
      removeListener: (listener) => { set.delete(listener); },
      hasListener: (listener) => set.has(listener),
      hasListeners: () => set.size > 0,
    };
  };
  const emit = (name, payload) => listeners[name].forEach((listener) => {
    try { listener(payload); } catch (error) { console.error(error); }
  });

  // Chrome's calling convention: a trailing callback gets the value, with `chrome.runtime.lastError`
  // set while it runs; without one, the call returns a promise. `then` runs after a success.
  const method = (member, then) => (...args) => {
    const callback = typeof args[args.length - 1] === 'function' ? args.pop() : null;
    const reply = bridge.postMessage({ member, args: JSON.parse(JSON.stringify(args)) }).then(async (answer) => {
      if (!answer.error && then) await then(args);
      return answer;
    });
    if (!callback) {
      return reply.then((answer) => {
        if (answer.error && answer.value === undefined) throw new Error(answer.error);
        return answer.value;
      });
    }
    reply.then((answer) => {
      if (answer.error) runtime.lastError = { message: answer.error };
      try {
        if (answer.value === undefined) callback(); else callback(answer.value);
      } finally {
        delete runtime.lastError;
      }
    });
  };

  const getInfo = method('management.get');
  const announce = (name) => ([id]) => getInfo(id).then((info) => emit(name, info), () => {});

  chrome.webstorePrivate = Object.fromEntries([
    'beginInstallWithManifest3', 'enableAppLauncher', 'getBrowserLogin', 'getExtensionStatus',
    'getFullChromeVersion', 'getIsLauncherEnabled', 'getMV2DeprecationStatus', 'getReferrerChain',
    'getStoreLogin', 'getWebGLStatus', 'isInIncognitoMode', 'isPendingCustodianApproval',
    'logEnterprisePromoShown', 'onEnterprisePromoClick', 'setStoreLogin', 'shouldShowEnterprisePromotionBanner',
  ].map((name) => [name, method(`webstorePrivate.${name}`)]));
  chrome.webstorePrivate.completeInstall = method('webstorePrivate.completeInstall', announce('onInstalled'));

  chrome.management = {
    getAll: method('management.getAll'),
    get: getInfo,
    setEnabled: method('management.setEnabled', (args) => announce(args[1] ? 'onEnabled' : 'onDisabled')(args)),
    uninstall: method('management.uninstall', ([id]) => emit('onUninstalled', id)),
    onInstalled: event('onInstalled'),
    onUninstalled: event('onUninstalled'),
    onEnabled: event('onEnabled'),
    onDisabled: event('onDisabled'),
  };
})();
