// Body of an async function run by ReaderMode once per page shown: 'reading', 'article' or 'none'.
// Stops at the first few long paragraphs, so it stays cheap on any page.

if (window.__lithiumReader) return 'reading';
if (!document.body) return 'none';
// When idle, so the visibility checks below read the layout rather than force it.
await new Promise((resolve) => window.requestIdleCallback ? requestIdleCallback(resolve, { timeout: 1000 }) : setTimeout(resolve));
if (!document.body) return 'none';
const unlikely = /comment|sidebar|related|share|social|promo|newsletter|subscribe|sponsor|advert|cookie|footer|menu/i;
const likely = /article|content|story|post|entry|main|body|text/i;
// A page that says it is something else needs twice the text: a landing page's blurbs add up too.
const kind = document.querySelector('meta[property="og:type"]')?.content.trim().toLowerCase();
const enough = kind && !kind.startsWith('article') ? 40 : 20;
// A lone paragraph under a heading of its own, as on a landing page's cards, counts half.
const isBlurb = (node) => node.localName === 'p' && node.parentElement?.querySelector(':scope > :is(h2, h3, h4, h5, h6)')
  && !node.parentElement.querySelector(':scope > p ~ p');
let score = 0;
const isEnough = (node) => {
  const length = node.textContent.trim().length;
  if (length < 140) return false;
  const name = `${node.className} ${node.id}`;
  if (unlikely.test(name) && !likely.test(name)) return false;
  if (node.closest('nav, aside, footer, [role=navigation], [role=complementary]') || !node.checkVisibility()) return false;
  score += Math.sqrt(length - 140) / (isBlurb(node) ? 2 : 1);
  return score > enough;
};
const blocks = 'p, pre, article';
for (const node of document.body.querySelectorAll(blocks)) if (isEnough(node)) return 'article';
// Text broken with <br><br> instead of paragraphs, as Readability's own check counts it.
const seen = new Set();
for (const br of document.body.querySelectorAll('br + br')) {
  const block = br.parentElement;
  if (seen.has(block) || block.matches(blocks)) continue;
  seen.add(block);
  if (isEnough(block)) return 'article';
}
return 'none';
