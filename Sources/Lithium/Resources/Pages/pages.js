// Helpers shared by Lithium's internal pages.
const call = (action, value) => window.webkit.messageHandlers.lithium.postMessage({ action, value });
const $ = (selector) => document.querySelector(selector);
const el = (tag, props = {}, children = []) => {
  const node = Object.assign(document.createElement(tag), props);
  node.append(...children);
  return node;
};

// The sidebar every internal page shares: settings sections, and History, a page of its own.
const NAV = [
  ['appearance', 'paint-brush', 'Appearance'],
  ['search', 'magnifying-glass', 'Search'],
  ['privacy', 'shield-check', 'Privacy & Security'],
  ['extensions', 'puzzle-piece', 'Extensions'],
  ['max', 'sparkle', 'Max'],
  ['permissions', 'video-camera', 'Site Permissions'],
  ['history', 'clock-counter-clockwise', 'History', 'lithium://history'],
  ['about', 'info', 'About Lithium'],
];

document.querySelector('nav')?.replaceChildren(
  el('div', { className: 'brand' }, [el('img', { src: 'lithium://pages/app-icon', alt: '' }), el('h1', { textContent: 'Settings' })]),
  ...NAV.map(([id, icon, label, page]) => {
    // On the settings page itself, sections are same-page anchors that settings.html switches between.
    const href = page ?? (location.host === 'settings' ? `#${id}` : `lithium://settings#${id}`);
    const link = el('a', { href, className: page && location.href.startsWith(page) ? 'active' : '' }, [el('span', { textContent: label })]);
    const image = el('div', { className: 'icon' });
    image.style.setProperty('--src', `url(lithium://pages/icon/${icon})`);
    link.prepend(image);
    return link;
  }),
);
