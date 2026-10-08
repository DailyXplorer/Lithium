// Body of an async function run by ReaderMode in Lithium's own content world, once per page shown:
// 'reading' when the page shows the reader (one back from the cache may), 'article' when it looks
// like one, 'none' otherwise. Stops at the first few long paragraphs, so it stays cheap on any page.

if (window.__lithiumReader) return 'reading';
if (!document.body) return 'none';
const unlikely = /comment|sidebar|related|share|social|promo|newsletter|subscribe|sponsor|advert|cookie|footer|menu/i;
const likely = /article|content|story|post|entry|main|body|text/i;
let score = 0;
for (const node of document.body.querySelectorAll('p, pre, article')) {
  const length = node.textContent.trim().length;
  if (length < 140) continue;
  const name = `${node.className} ${node.id}`;
  if (unlikely.test(name) && !likely.test(name)) continue;
  if (node.closest('nav, aside, footer, [role=navigation], [role=complementary]') || !node.checkVisibility()) continue;
  score += Math.sqrt(length - 140);
  if (score > 20) return 'article';
}
return 'none';
