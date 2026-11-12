"""Relative links in the Markdown docs lead to files, and to headings, that exist.

  doc_links.py   checks every tracked *.md and prints `path:line: target` for each dead link

Inline links only (`[text](target)`), and links to other sites are not fetched. The unit
tests import dead_links() and slug().
"""

import posixpath
import re
import subprocess
import sys
from urllib.parse import unquote

LINK = re.compile(r"\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
ELSEWHERE = re.compile(r"^([a-z][a-z0-9+.-]*:|//)", re.IGNORECASE)
CODE_SPAN = re.compile(r"`[^`]*`")


def slug(heading):
    """The anchor GitHub gives a heading: lowercase, punctuation dropped, spaces to hyphens."""
    text = re.sub(r"`|\[([^\]]*)\]\([^)]*\)", r"\1", heading).strip().lower()
    return re.sub(r"[^\w\- ]", "", text).replace(" ", "-")


def prose_lines(text):
    """(line number, line) outside fenced code blocks."""
    fenced = False
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
        elif not fenced:
            yield number, line


def anchors(text):
    return {slug(line.lstrip("#")) for _, line in prose_lines(text) if line.startswith("#")}


def dead_links(path, docs, tracked):
    """(line, target) for each relative link of `docs[path]` that leads nowhere.

    `docs` maps each Markdown path to its text, `tracked` holds every tracked path.
    """
    folders = {posixpath.dirname(p) for p in tracked}
    folders |= {parent for folder in folders for parent in iter_parents(folder)} | {"."}  # the root
    dead = []
    for number, line in prose_lines(docs[path]):
        for target in LINK.findall(CODE_SPAN.sub("", line)):
            if ELSEWHERE.match(target):
                continue
            file, _, fragment = target.partition("#")
            file = unquote(file.partition("?")[0])
            if file.startswith("/"):
                resolved = posixpath.normpath(file.lstrip("/"))
            else:
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), file)) if file else path
            if resolved not in tracked and resolved not in folders:
                dead.append((number, target))
            elif fragment and resolved in docs and fragment.lower() not in anchors(docs[resolved]):
                dead.append((number, target))
    return dead


def iter_parents(folder):
    while folder:
        folder = posixpath.dirname(folder)
        yield folder


def main():
    listed = subprocess.run(["git", "ls-files", "-z"], check=True, capture_output=True).stdout.decode()
    tracked = {p for p in listed.split("\0") if p}
    docs = {}
    for path in tracked:
        if path.lower().endswith(".md"):
            with open(path, encoding="utf-8") as file:
                docs[path] = file.read()
    problems = [f"{path}:{line}: {target}" for path in sorted(docs) for line, target in dead_links(path, docs, tracked)]
    for problem in problems:
        print(problem)
    print(f"{len(problems)} dead link(s)." if problems else f"The relative links of {len(docs)} Markdown files lead somewhere.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
