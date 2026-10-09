// Injected for pinned tabs only, in the page's own world, for the Badging API and notifications.
// The app trusts none of its messages: any script of the page can post the same. A notification
// only puts a dot on the tab.
(() => {
  const key = Symbol.for('lithium.pinnedPage');
  // Taken now, before the page can replace it.
  const channel = globalThis.webkit?.messageHandlers?.lithiumPinned;
  if (!channel) return;
  // Pinned again without a reload: the first run posts to the new channel.
  if (globalThis[key]) return globalThis[key](channel);
  let post = channel.postMessage.bind(channel);
  const send = (message) => { try { post(message); } catch {} };
  const define = (target, name, value) => Object.defineProperty(target, name, { value, configurable: true, writable: true });

  define(Navigator.prototype, 'setAppBadge', function setAppBadge(contents) {
    if (contents === undefined) {
      send({ type: 'badge', count: null });
      return Promise.resolve();
    }
    const count = Number(contents);
    if (!Number.isFinite(count) || count < 0) return Promise.reject(new TypeError('The badge must be a non-negative number.'));
    send({ type: 'badge', count: Math.floor(count) });
    return Promise.resolve();
  });
  define(Navigator.prototype, 'clearAppBadge', function clearAppBadge() {
    send({ type: 'clearBadge' });
    return Promise.resolve();
  });

  // WebKit's own is there but denies every page; one that can show notifications is left alone.
  if (globalThis.Notification?.permission !== 'granted') {
    class Notification extends EventTarget {
      onclick = null;
      onshow = null;
      onerror = null;
      onclose = null;

      constructor(title, options = {}) {
        if (arguments.length === 0) throw new TypeError('Notification needs a title.');
        super();
        this.title = String(title);
        this.body = String(options?.body ?? '');
        this.tag = String(options?.tag ?? '');
        this.icon = String(options?.icon ?? '');
        this.data = options?.data ?? null;
        send({ type: 'notification' });
      }

      static get permission() { return 'granted'; }

      static requestPermission(callback) {
        if (typeof callback === 'function') callback('granted');
        return Promise.resolve('granted');
      }

      close() {}
    }
    define(globalThis, 'Notification', Notification);
  }

  let lastIcon = '';
  const reportIcon = () => {
    const links = document.head?.querySelectorAll('link[rel~="icon" i]') ?? [];
    const href = links.length ? links[links.length - 1].href : '';
    if (!href || href === lastIcon) return;
    lastIcon = href;
    // Sites that draw their unread count into the icon change the title with it.
    send({ type: 'icon', href, title: document.title });
  };
  define(globalThis, key, (next) => {
    post = next.postMessage.bind(next);
    lastIcon = '';
    reportIcon();
  });
  const isLink = (node) => node.nodeName === 'LINK';
  const touchesLink = (record) => isLink(record.target) || [...record.addedNodes].some(isLink) || [...record.removedNodes].some(isLink);
  const watch = () => {
    reportIcon();
    if (!document.head) return;
    new MutationObserver((records) => { if (records.some(touchesLink)) reportIcon(); })
      .observe(document.head, { childList: true, subtree: true, attributes: true, attributeFilter: ['href', 'rel'] });
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', watch, { once: true });
  else watch();
})();
