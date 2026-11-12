"""The pull-request size nudge counts reviewable lines and speaks only above the budget."""

import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("pr_size", ROOT / ".github/scripts/pr_size.py")
pr_size = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pr_size)


class PrSizeTest(unittest.TestCase):
    def test_the_lockfile_and_fixtures_are_not_counted(self):
        files = [
            ("Sources/Lithium/Model/Browser.swift", 100, 20),
            ("Package.resolved", 40, 12),
            ("Tests/LithiumTests/Fixtures/reader/article.html", 900, 0),
        ]
        self.assertEqual(pr_size.counted(files), 120)

    def test_vendored_and_generated_resources_are_not_counted(self):
        files = [
            ("Sources/Lithium/Resources/Scripts/marked.min.js", 81, 80),
            ("Sources/Lithium/Resources/Scripts/scriptlets.ubo.json", 1, 1),
            ("Sources/Lithium/Resources/Scripts/scriptlets.corelibs.json", 860, 700),
            ("Sources/Lithium/Resources/Icons/airplane.svg", 1, 0),
            ("Sources/Lithium/Resources/SpaceIcons.tsv", 335, 0),
            ("Sources/Lithium/Resources/Scripts/page-font.js", 25, 5),
        ]
        self.assertEqual(pr_size.counted(files), 30)

    def test_scripts_documentation_and_tests_are_counted(self):
        files = [("docs/design/agent-mcp.md", 30, 0), ("Tests/LithiumTests/BrowserTests.swift", 50, 10),
                 ("Sources/Lithium/Resources/Scripts/reader.js", 20, 0), ("Sources/Lithium/Resources/FilterSources.json", 4, 1),
                 ("Tests/LithiumTests/FixturesTests.swift", 5, 0)]
        self.assertEqual(pr_size.counted(files), 120)

    def test_comment_flags_only_what_is_over_the_budget(self):
        over = pr_size.render(pr_size.BUDGET + 1, "o/r")
        self.assertIn(f"**{pr_size.BUDGET + 1}** lines", over)
        self.assertIn("nudge, not a check that blocks", over)
        self.assertIn("https://github.com/o/r/blob/main/CONTRIBUTING.md#before-you-open-a-pull-request", over)
        self.assertTrue(over.startswith(pr_size.MARKER))
        under = pr_size.render(pr_size.BUDGET, "o/r")
        self.assertIn("within the soft budget", under)
        self.assertTrue(under.startswith(pr_size.MARKER))

    def test_the_comment_links_to_a_heading_that_exists(self):
        headings = [line.strip() for line in (ROOT / "CONTRIBUTING.md").read_text().splitlines() if line.startswith("#")]
        self.assertIn("## Before you open a pull request", headings)


if __name__ == "__main__":
    unittest.main()
