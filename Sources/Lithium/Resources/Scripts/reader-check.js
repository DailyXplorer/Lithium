// Body of an async function run by ReaderMode in Lithium's own content world, once per page shown:
// 'reading' when the page shows the reader (one back from the cache may), 'article' when it looks
// like one, 'none' otherwise. Stops at the first few long paragraphs, so it stays cheap on any page.

if (window.__lithiumReader) return 'reading';
if (!document.body) return 'none';
const unlikely = /comment|sidebar|related|share|social|promo|newsletter|subscribe|sponsor|advert|cookie|footer|menu/i;
const likely = /article|content|story|post|entry|main|body|text/i;
let score = 0;
const isEnough = (node) => {
  const length = node.textContent.trim().length;
  if (length < 140) return false;
  const name = `${node.className} ${node.id}`;
  if (unlikely.test(name) && !likely.test(name)) return false;
  if (node.closest('nav, aside, footer, [role=navigation], [role=complementary]') || !node.checkVisibility()) return false;
  score += Math.sqrt(length - 140);
  return score > 20;
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
