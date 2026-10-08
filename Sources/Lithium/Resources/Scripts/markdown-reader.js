(() => {
  // A page whose address ends in .md can be an ordinary web page (a GitHub file view): leave those alone.
  if (!/^text\/(plain|markdown|x-markdown)$/.test(document.contentType) || !document.body) return;
  const source = document.body.textContent;

  // The rendered HTML lives in the file's origin. The file may be untrusted, so none of it may run:
  // the policy has to be in place before any rendered node joins the document.
  const policy = document.createElement('meta');
  policy.httpEquiv = 'Content-Security-Policy';
  policy.content = "script-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";
  const style = document.createElement('style');
  style.textContent = __LITHIUM_MARKDOWN_CSS__;
  document.head.append(policy, style);

  const parsed = new DOMParser().parseFromString(marked.parse(source, { gfm: true }), 'text/html');
  parsed.querySelectorAll('script, style, link, meta, base, iframe, frame, object, embed, form').forEach((node) => node.remove());
  for (const box of parsed.querySelectorAll('input[type=checkbox]')) box.disabled = true;

  const used = new Map();
  for (const heading of parsed.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
    if (heading.id) continue;
    const slug = heading.textContent.trim().toLowerCase().replace(/[^\p{L}\p{N}\s-]/gu, '').replace(/\s+/g, '-');
    const count = used.get(slug) ?? 0;
    used.set(slug, count + 1);
    heading.id = count ? `${slug}-${count}` : slug;
  }

  const article = document.createElement('article');
  article.append(...parsed.body.childNodes);
  document.body.replaceChildren(article);
  // A bare `%` (`100%.md`, `#a%`) stays as it is in an address, and doesn't decode.
  const decode = (text) => { try { return decodeURIComponent(text); } catch { return text; } };
  document.title = article.querySelector('h1')?.textContent.trim() || decode(location.pathname.split('/').pop());
  if (location.hash) document.getElementById(decode(location.hash.slice(1)))?.scrollIntoView();
})();
