// Helpers shared by Lithium's internal pages.
const call = (action, value) => window.webkit.messageHandlers.lithium.postMessage({ action, value });
const $ = (selector) => document.querySelector(selector);
const el = (tag, props = {}, children = []) => {
  const node = Object.assign(document.createElement(tag), props);
  node.append(...children);
  return node;
};

document.querySelectorAll('nav a[data-icon]').forEach((link) => {
  const icon = el('div', { className: 'icon' });
  icon.style.setProperty('--src', `url(lithium://pages/icon/${link.dataset.icon})`);
  link.prepend(icon);
});
