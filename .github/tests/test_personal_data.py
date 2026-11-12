"""The personal-data check flags real paths and addresses, and lets placeholders through."""

import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("personal_data", ROOT / ".github/scripts/personal_data.py")
personal_data = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(personal_data)

# The check scans this file too: the samples it must flag are assembled here, never written whole.
AT = "@"
USERS = "/Users/"


def found(text):
    return [what for _, what in personal_data.findings_in(text)]


class PersonalDataTest(unittest.TestCase):
    def test_a_home_folder_path_is_flagged_with_its_line(self):
        text = f"first line\nlet path = \"{USERS}jdoe/Documents/notes.txt\"\n"
        self.assertEqual(personal_data.findings_in(text), [(2, f"home-folder path {USERS}jdoe")])

    def test_placeholder_paths_pass(self):
        self.assertEqual(found(f"{USERS}me/Downloads {USERS}you/x {USERS}Shared/y ~/Library /users/api"), [])

    def test_a_real_address_is_flagged(self):
        self.assertEqual(found(f"contact: jane.doe{AT}mail.org"), [f"e-mail address jane.doe{AT}mail.org"])

    def test_example_addresses_and_lookalikes_pass(self):
        samples = ["alice@example.com", "alice@mail.example", "android://hash@com.example.app", "bob@site.test",
                   "1+someone@users.noreply.github.com", "https://admin@192.168.1.1/", "jquery@3.7.1", "a@b.c",
                   "icon@2x.png", "git@github.com:owner/repo.git", "@MainActor", "@media (min-width: 10px)"]
        for sample in samples:
            self.assertEqual(found(sample), [], sample)

    def test_commit_addresses_naming_a_machine_are_flagged(self):
        for address in [f"dev{AT}my-mac.local", f"dev{AT}box.home", f"dev{AT}laptop", f"dev{AT}host.(none)"]:
            self.assertTrue(personal_data.machine_address(address), address)
        for address in ["1+someone@users.noreply.github.com", f"jane{AT}mail.org", "noreply@example.com"]:
            self.assertFalse(personal_data.machine_address(address), address)


if __name__ == "__main__":
    unittest.main()
