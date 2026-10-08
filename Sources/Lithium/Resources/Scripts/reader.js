// Body of an async function run by ReaderMode in Lithium's own content world, only when the user
// asks for the reader. Swaps the page's document for one holding its article alone, and back: the
// page's own stays as it was, detached, so leaving returns to it without a reload.
// Arguments: action ('enter', 'exit' or 'style'), style ({ size, theme, font }), css (for 'enter').

const applyStyle = (root) => {
  root.dataset.theme = style.theme;
  root.dataset.font = style.font;
  root.style.setProperty('--reader-size', `${style.size}px`);
};

const saved = window.__lithiumReader;
if (action === 'exit') {
  if (!saved) return false;
  document.replaceChild(saved.root, document.documentElement);
  document.adoptedStyleSheets = saved.sheets;
  delete window.__lithiumReader;
  scrollTo(saved.x, saved.y);
  return true;
}
if (action === 'style') {
  if (saved) applyStyle(document.documentElement);
  return Boolean(saved);
}
if (saved) return true;
if (!document.body) return false;

// Read from the page, never changed: the article is rebuilt from new elements, so no page script,
// handler or custom element comes along, and the page is the same when the reader is left.
const skipped = [
  'script', 'style', 'link', 'meta', 'noscript', 'template', 'iframe', 'frame', 'object', 'embed', 'canvas', 'svg',
  'video', 'audio', 'source', 'track', 'map', 'form', 'input', 'button', 'select', 'textarea', 'label', 'nav', 'aside',
  'footer', 'dialog', 'menu', '[hidden]', '[aria-hidden=true]', '[role=navigation]', '[role=complementary]',
  '[role=dialog]', '[role=alertdialog]', '[role=banner]', '[role=contentinfo]',
].join(',');
const unlikely = /comment|sidebar|related|share|social|promo|newsletter|subscribe|sponsor|advert|cookie|popup|modal|breadcrumb|pagination|recommend|footer|menu/i;
const likely = /article|content|story|post|entry|main|body|text/i;

const textLength = (element) => element.textContent.replace(/\s+/g, ' ').trim().length;
const linkDensity = (element) => {
  const total = textLength(element);
  if (!total) return 1;
  let links = 0;
  for (const link of element.querySelectorAll('a')) links += textLength(link);
  return links / total;
};
const isUnlikely = (element) => {
  const name = `${typeof element.className === 'string' ? element.className : ''} ${element.id}`;
  return unlikely.test(name) && !likely.test(name);
};
const isHidden = (element) => {
  const computed = getComputedStyle(element);
  return computed.display === 'none' || computed.visibility === 'hidden';
};

// Paragraphs score their containers, the closest most; the best container, weighed down by its
// share of link text, is the article.
const scores = new Map();
for (const paragraph of document.body.querySelectorAll('p, pre, td, blockquote')) {
  const length = textLength(paragraph);
  if (length < 25 || paragraph.closest(skipped) || !paragraph.checkVisibility()) continue;
  const points = 1 + (paragraph.textContent.match(/[,،、，]/g)?.length ?? 0) + Math.min(Math.floor(length / 100), 3);
  let ancestor = paragraph.parentElement;
  for (let level = 1; ancestor && level <= 3; level++, ancestor = ancestor.parentElement) {
    if (isUnlikely(ancestor)) continue;
    scores.set(ancestor, (scores.get(ancestor) ?? 0) + points / level);
  }
}
const weighed = [...scores].sort((a, b) => b[1] - a[1]).slice(0, 10)
  .map(([element, score]) => [element, score * (1 - linkDensity(element))])
  .sort((a, b) => b[1] - a[1]);
if (!weighed.length) return false;
const [best, bestScore] = weighed[0];
// Its siblings that read like part of it too: an article split across several blocks.
const threshold = Math.max(10, bestScore * 0.2);
const parts = best.parentElement && best.parentElement !== document.documentElement
  ? [...best.parentElement.children].filter((sibling) => sibling === best
    || (scores.get(sibling) ?? 0) * (1 - linkDensity(sibling)) >= threshold
    || sibling.localName === 'p' && textLength(sibling) > 80 && linkDensity(sibling) < 0.25)
  : [best];

const tags = Object.assign(Object.create(null), {
  p: 'p', h1: 'h2', h2: 'h2', h3: 'h3', h4: 'h4', h5: 'h5', h6: 'h6', a: 'a', img: 'img', figure: 'figure',
  figcaption: 'figcaption', blockquote: 'blockquote', q: 'q', cite: 'cite', pre: 'pre', code: 'code', kbd: 'kbd',
  samp: 'samp', var: 'var', em: 'em', i: 'i', strong: 'strong', b: 'b', u: 'u', s: 's', del: 'del', ins: 'ins',
  mark: 'mark', small: 'small', sub: 'sub', sup: 'sup', abbr: 'abbr', time: 'time', br: 'br', hr: 'hr', ul: 'ul',
  ol: 'ol', li: 'li', dl: 'dl', dt: 'dt', dd: 'dd', table: 'table', caption: 'caption', thead: 'thead',
  tbody: 'tbody', tfoot: 'tfoot', tr: 'tr', th: 'th', td: 'td', div: 'div', section: 'div', article: 'div',
  main: 'div', header: 'div', hgroup: 'div', address: 'div', details: 'div', summary: 'p', center: 'div',
});
// Web addresses only: never javascript:, nor a data: one but for images.
const address = (value, isImage) => {
  if (!value) return null;
  try {
    const url = new URL(value, document.baseURI);
    if (url.protocol === 'http:' || url.protocol === 'https:' || !isImage && url.protocol === 'mailto:') return url.href;
    if (isImage && /^data:image\/(png|jpeg|gif|webp|avif);/i.test(url.href)) return url.href;
  } catch {}
  return null;
};
// The picture the page shows, or the one a lazy page has yet to load rather than its placeholder.
const imageSource = (image) => {
  const found = [image.currentSrc, image.dataset.src, image.dataset.lazySrc, image.dataset.original, image.getAttribute('src')]
    .map((value) => address(value, true)).filter(Boolean);
  return found.find((url) => !url.startsWith('data:')) ?? found[0];
};
const isClutter = (element) => isUnlikely(element) && textLength(element) < 1000
  || ['ul', 'ol', 'div'].includes(element.localName) && textLength(element) < 300 && linkDensity(element) > 0.5;

const build = (node, into) => {
  for (const child of node.childNodes) {
    if (child.nodeType === Node.TEXT_NODE) {
      into.append(child.data);
      continue;
    }
    if (child.nodeType !== Node.ELEMENT_NODE || child.matches(skipped) || isHidden(child) || isClutter(child)) continue;
    const tag = tags[child.localName];
    if (!tag) {
      build(child, into);
      continue;
    }
    const copy = document.createElement(tag);
    if (tag === 'a') {
      const href = address(child.getAttribute('href'), false);
      if (href) copy.href = href;
    } else if (tag === 'img') {
      const source = imageSource(child);
      // Icons and tracking pixels.
      if (!source || child.complete && child.naturalWidth > 0 && child.naturalWidth < 32 && child.naturalHeight < 32) continue;
      copy.src = source;
      copy.alt = child.alt;
    } else if (tag === 'td' || tag === 'th') {
      for (const name of ['colspan', 'rowspan']) if (/^\d+$/.test(child.getAttribute(name) ?? '')) copy.setAttribute(name, child.getAttribute(name));
    } else if (tag === 'ol' && /^-?\d+$/.test(child.getAttribute('start') ?? '')) {
      copy.setAttribute('start', child.getAttribute('start'));
    }
    build(child, copy);
    into.append(copy);
  }
};

const content = document.createElement('div');
build({ childNodes: parts }, content);
for (const element of [...content.querySelectorAll('p, div, li, a, figure, h2, h3, h4, h5, h6, blockquote')].reverse()) {
  if (!element.textContent.trim() && !element.querySelector('img, br, hr')) element.remove();
}
if (textLength(content) < 200) return false;

const clean = (text) => (text ?? '').replace(/\s+/g, ' ').trim();
const meta = (...names) => names.map((name) => clean(document.querySelector(`meta[property="${name}"], meta[name="${name}"]`)?.content)).find(Boolean) ?? '';
const heading = [...document.querySelectorAll('h1')].find((h1) => clean(h1.textContent).length > 3 && !h1.closest(skipped) && h1.checkVisibility());
const title = clean(heading?.textContent) || meta('og:title', 'twitter:title') || clean(document.title);
const repeated = content.querySelector('h2');
if (repeated && clean(repeated.textContent) === title) repeated.remove();
const byline = meta('author') || [...document.querySelectorAll('[rel=author], [itemprop=author], .byline, .author')]
  .map((element) => clean(element.textContent)).find((text) => text && text.length < 100) || '';
const site = meta('og:site_name') || location.hostname.replace(/^www\./, '');
const minutes = Math.max(1, Math.round(clean(content.textContent).split(' ').length / 230));

const root = document.createElement('html');
root.lang = document.documentElement.lang;
root.dir = document.documentElement.dir;
const head = document.createElement('head');
const pageTitle = document.createElement('title');
pageTitle.textContent = document.title;
const sheet = document.createElement('style');
sheet.textContent = css;
head.append(pageTitle, sheet);
const header = document.createElement('header');
const about = document.createElement('p');
about.className = 'site';
about.textContent = [site, `${minutes} min read`].filter(Boolean).join(' · ');
const h1 = document.createElement('h1');
h1.textContent = title;
header.append(about, h1);
if (byline) {
  const by = document.createElement('p');
  by.className = 'byline';
  by.textContent = byline;
  header.append(by);
}
const article = document.createElement('article');
article.append(header, content);
const body = document.createElement('body');
body.append(article);
root.append(head, body);
applyStyle(root);

window.__lithiumReader = { root: document.documentElement, sheets: document.adoptedStyleSheets, x: scrollX, y: scrollY };
document.adoptedStyleSheets = [];
document.replaceChild(root, document.documentElement);
scrollTo(0, 0);
return true;
