"""The link check follows relative links and heading anchors, and leaves other sites and code alone."""

import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("doc_links", ROOT / ".github/scripts/doc_links.py")
doc_links = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(doc_links)

GUIDE = "# Guide\n\n## Before you open a pull request\n\n## Connecting agents (`lithium-mcp`)\n"
TRACKED = {"README.md", "docs/guide.md", "docs/design/plan.md", "scripts/test", "Sources/App/main.swift"}


def dead(text, path="docs/page.md"):
    docs = {"README.md": "# Lithium\n", "docs/guide.md": GUIDE, path: text}
    return doc_links.dead_links(path, docs, TRACKED | {path})


class DocLinksTest(unittest.TestCase):
    def test_links_to_tracked_files_and_folders_pass(self):
        text = ("[a](guide.md) [b](../README.md) [c](design/) [d](../scripts/test) [e](/Sources/App/main.swift#L12)\n"
                "[f](https://example.com/x.md) [g](mailto:x@example.com) [h](#here)\n\n## Here\n")
        self.assertEqual(dead(text), [])

    def test_a_link_to_a_missing_file_is_reported_with_its_line(self):
        self.assertEqual(dead("fine\n\nSee [the data](../.tools/final/summary.json).\n"), [(3, "../.tools/final/summary.json")])

    def test_heading_anchors_are_checked(self):
        text = "[a](guide.md#before-you-open-a-pull-request) [b](guide.md#connecting-agents-lithium-mcp) [c](guide.md#gone)\n"
        self.assertEqual(dead(text), [(1, "guide.md#gone")])

    def test_an_anchor_of_the_page_itself_is_checked(self):
        self.assertEqual(dead("# Title\n\n[up](#title) [nowhere](#missing)\n"), [(3, "#missing")])

    def test_code_is_not_read_as_links(self):
        text = "Write `[text](missing.md)` to link.\n\n```md\n[text](missing.md)\n```\n"
        self.assertEqual(dead(text), [])


if __name__ == "__main__":
    unittest.main()
