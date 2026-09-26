// Body of an async function run by PageReader in Lithium's own content world.
// Returns the selected text and the page's readable text, without menus and footers.
// Argument: limit, the most characters worth returning.

const fieldSelection = () => {
  const field = document.activeElement;
  const editable = field && (field.tagName === 'TEXTAREA' ||
    (field.tagName === 'INPUT' && /^(text|search|url|email|)$/i.test(field.type)));
  if (!editable || field.selectionEnd <= field.selectionStart) return '';
  return field.value.slice(field.selectionStart, field.selectionEnd);
};

const length = (element) => (element.innerText || '').length;

// The article or main element when it holds the page's content; the whole body otherwise.
const pickRoot = () => {
  const body = document.body;
  const total = length(body);
  const holdsContent = (element) => element && length(element) >= 500 && length(element) >= total * 0.25;
  const articles = [...document.querySelectorAll('article')].filter((article) => !article.parentElement.closest('article'));
  if (articles.length === 1 && holdsContent(articles[0])) return articles[0];
  const main = document.querySelector('main, [role=main]');
  if (holdsContent(main)) return main;
  return body;
};

const excluded = [
  // Not form: ASP.NET pages wrap everything in one.
  'nav', 'footer', 'aside', 'header', 'button', 'dialog', 'menu',
  '[role=navigation]', '[role=contentinfo]', '[role=complementary]', '[role=search]', '[role=banner]',
  '[role=dialog]', '[role=alertdialog]', '[aria-modal=true]',
].join(',');

const readableText = (root) => {
  const full = root.innerText || '';
  let text = full;
  let removed = 0;
  for (const element of root.querySelectorAll(excluded)) {
    if (removed >= 300) break;
    // A header inside the content is the article's own title and byline.
    if (element.matches('header') && element.closest('article, main')) continue;
    if (element.parentElement.closest(excluded) && root.contains(element.parentElement.closest(excluded))) continue;
    // innerText of an element that isn't rendered is its raw text, which the page's innerText doesn't contain.
    if (!element.checkVisibility()) continue;
    const part = (element.innerText || '').trim();
    if (part.length < 2) continue;
    const index = text.indexOf(part);
    if (index === -1) continue;
    text = text.slice(0, index) + '\n' + text.slice(index + part.length);
    removed++;
  }
  // A page built entirely from these elements still has something to summarize.
  return text.trim().length >= full.trim().length * 0.2 ? text : full;
};

const tidy = (text) => text
  .split('\n')
  .map((line) => line.replace(/\s+/g, ' ').trim())
  .filter(Boolean)
  .join('\n');

const selection = tidy(fieldSelection() || String(getSelection()));
const text = document.body ? tidy(readableText(pickRoot())) : '';
return {
  title: document.title || '',
  selection: selection.slice(0, limit),
  text: text.slice(0, limit),
  truncated: text.length > limit,
};
