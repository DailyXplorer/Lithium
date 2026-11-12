"""The page-script check accepts scripts and async function bodies, and names what does not parse."""

from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def check(files):
    with tempfile.TemporaryDirectory() as folder:
        for name, text in files.items():
            Path(folder, name).write_text(text)
        run = subprocess.run(["node", str(ROOT / ".github/scripts/page_scripts.mjs"), folder],
                             capture_output=True, text=True)
        return run.returncode, run.stdout.replace(folder + "/", "")


class PageScriptsTest(unittest.TestCase):
    def test_scripts_function_bodies_pages_and_json_pass(self):
        code, out = check({
            "script.js": "(() => { const a = 1; })();\n",
            "body.js": "const text = await read();\nreturn text;\n",
            "page.html": "<p>hi</p>\n<script src=\"x.js\"></script>\n<script>\nconst b = 2;\n</script>\n",
            "data.json": "{\"a\": [1, 2]}\n",
            "notes.txt": "not checked (\n",
        })
        self.assertEqual((code, out), (0, "4 files parse.\n"))

    def test_a_broken_script_is_named_with_its_line(self):
        code, out = check({"good.js": "let a = 1;\n", "broken.js": "let a = 1;\nlet b = ;\n"})
        self.assertEqual(code, 1)
        self.assertIn("broken.js:2: ", out)
        self.assertNotIn("good.js", out)

    def test_a_broken_inline_script_keeps_the_line_of_its_page(self):
        code, out = check({"page.html": "<html>\n<body>\n<script>\nlet a = 1;\nlet b = (;\n</script>\n</body>\n"})
        self.assertEqual(code, 1)
        self.assertIn("page.html:5: ", out)

    def test_broken_json_fails(self):
        code, out = check({"data.json": "{\"a\": 1,}\n"})
        self.assertEqual(code, 1)
        self.assertIn("data.json: ", out)

    def test_a_folder_with_nothing_to_check_fails(self):
        self.assertEqual(check({"notes.txt": "x"})[0], 1)


if __name__ == "__main__":
    unittest.main()
