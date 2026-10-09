// Body of an async function run by ReaderMode in Lithium's own content world, once per page shown:
// 'reading' when the page shows the reader (one back from the cache may), 'article' when it looks
// like one, 'none' otherwise. Stops at the first few long paragraphs, so it stays cheap on any page.

if (window.__lithiumReader) return 'reading';
if (!document.body) return 'none';
// Asked when the page has nothing else to do, after its own work: its layout is done by then, so
// the visibility checks below read it rather than force it. WebKit without requestIdleCallback
// waits for the tasks already queued.
await new Promise((resolve) => window.requestIdleCallback ? requestIdleCallback(resolve, { timeout: 1000 }) : setTimeout(resolve));
if (!document.body) return 'none';
const unlikely = /comment|sidebar|related|share|social|promo|newsletter|subscribe|sponsor|advert|cookie|footer|menu/i;
const likely = /article|content|story|post|entry|main|body|text/i;
// A page that says it is something else (a website, a product) needs twice the text: a landing
// page's blurbs add up too.
const kind = document.querySelector('meta[property="og:type"]')?.content.trim().toLowerCase();
const enough = kind && !kind.startsWith('article') ? 40 : 20;
// A lone paragraph under a heading of its own, as on a landing page's cards, counts half. Lone in
// its box, not between its siblings: an article's paragraphs, cut by code or figures, share theirs.
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
// Text some pages break with blank lines (<br><br>) instead of paragraphs, as Readability's own
// check counts it: looked for only when the paragraphs weren't enough.
const seen = new Set();
for (const br of document.body.querySelectorAll('br + br')) {
  const block = br.parentElement;
  if (seen.has(block) || block.matches(blocks)) continue;
  seen.add(block);
  if (isEnough(block)) return 'article';
}
return 'none';
