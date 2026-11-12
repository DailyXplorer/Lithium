// Syntax check for the scripts Lithium injects in pages and the scripts of its own pages.
// A script that does not parse never runs, and nothing says so: the page just loses the feature.
//   node .github/scripts/page_scripts.mjs [folder]   (default: Sources/Lithium/Resources)
// Checks every .js file, the inline scripts of every .html file, and that every .json file parses.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

// Parses as a script, or as the body of an async function: WebKit's callAsyncJavaScript runs
// some of them that way, with `return` and `await` at the top. Which ones is not known here,
// so a stray top-level `return` in an ordinary script passes.
function syntaxError(source, filename) {
  try {
    new vm.Script(source, { filename });
    return null;
  } catch {
    try {
      new vm.Script(`(async function () {${source}\n})`, { filename });
      return null;
    } catch (error) {
      return error;
    }
  }
}

// An inline script keeps its line numbers: the lines above it become empty lines.
function inlineScripts(html) {
  const scripts = [];
  for (const match of html.matchAll(/<script(?![^>]*\ssrc=)[^>]*>([\s\S]*?)<\/script>/g)) {
    const before = html.slice(0, match.index + match[0].indexOf('>') + 1);
    scripts.push('\n'.repeat(before.split('\n').length - 1) + match[1]);
  }
  return scripts;
}

function* files(folder) {
  for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
    const full = path.join(folder, entry.name);
    if (entry.isDirectory()) yield* files(full);
    else yield full;
  }
}

const root = process.argv[2] ?? 'Sources/Lithium/Resources';
let checked = 0;
const problems = [];
for (const file of files(root)) {
  const kind = path.extname(file);
  if (!['.js', '.html', '.json'].includes(kind)) continue;
  const text = fs.readFileSync(file, 'utf8');
  checked++;
  if (kind === '.json') {
    try {
      JSON.parse(text);
    } catch (error) {
      problems.push(`${file}: ${error.message}`);
    }
    continue;
  }
  for (const source of kind === '.html' ? inlineScripts(text) : [text]) {
    const error = syntaxError(source, file);
    // The stack of a syntax error starts with `file:line`.
    if (error) problems.push(`${error.stack.split('\n')[0]}: ${error.message}`);
  }
}
for (const problem of problems) console.log(problem);
console.log(problems.length ? `${problems.length} file(s) do not parse.` : `${checked} files parse.`);
process.exit(problems.length || checked === 0 ? 1 : 0);
