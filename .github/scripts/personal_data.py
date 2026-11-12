"""Keeps personal data out of the repository: home-folder paths, e-mail addresses, machine names.

  personal_data.py                  scans every file git tracks
  personal_data.py --commits A..B   also checks the author and committer address of those commits

Prints one line per finding and exits 1 when there is any. The unit tests import
findings_in() and machine_address().

To let through something that is not personal (an upstream contact in a vendored file), add
it to the lists below: the change then shows in review.
"""

import re
import subprocess
import sys

HOME = re.compile(r"/Users/([A-Za-z0-9._-]+)")
# Placeholders the docs and tests may use, and the macOS folder every account shares.
PLACEHOLDER_USERS = {"me", "you", "Shared"}

EMAIL = re.compile(r"([A-Za-z0-9._%+-]+)@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)")
# `icon@2x.png` and `git@github.com:owner/repo` are not addresses.
FILE_EXTENSIONS = {"png", "jpg", "jpeg", "pdf"}
RESERVED_TLDS = {"test", "invalid", "localhost"}  # RFC 2606, like the `example` label
ALLOWED_DOMAINS = ("users.noreply.github.com",)

# Domains git makes up from the machine's name when no address is configured.
MACHINE_SUFFIXES = (".local", ".home", ".lan", ".localdomain", ".internal", ".(none)")


def personal_address(local, domain):
    labels = domain.lower().split(".")
    tld = labels[-1]
    if not tld.isalpha() or len(tld) < 2:  # an IP address, a version (`pkg@1.2.3`), `a@b.c`
        return False
    if tld in FILE_EXTENSIONS or tld in RESERVED_TLDS or "example" in labels:
        return False
    return local != "git" and not domain.lower().endswith(ALLOWED_DOMAINS)


def findings_in(text):
    """(line number, what was found) for each home-folder path or address in `text`."""
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        for match in HOME.finditer(line):
            if match.group(1) not in PLACEHOLDER_USERS:
                found.append((number, f"home-folder path {match.group(0)}"))
        for match in EMAIL.finditer(line):
            if personal_address(match.group(1), match.group(2)):
                found.append((number, f"e-mail address {match.group(0)}"))
    return found


def machine_address(email):
    """True when a commit address names a machine, as git's fallback `login@hostname` does."""
    domain = email.rpartition("@")[2].lower()
    return "." not in domain or domain.endswith(MACHINE_SUFFIXES)


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True).stdout


def main(argv):
    problems = []
    for path in filter(None, git("ls-files", "-z").decode().split("\0")):
        with open(path, "rb") as file:
            data = file.read()
        if b"\0" in data[:8000]:  # binary
            continue
        for number, what in findings_in(data.decode("utf-8", "replace")):
            problems.append(f"{path}:{number}: {what}")
    if len(argv) == 2 and argv[0] == "--commits":
        for row in git("log", "--format=%h%x09%ae%x09%ce", argv[1]).decode().splitlines():
            commit, *addresses = row.split("\t")
            for address in sorted({a for a in addresses if machine_address(a)}):
                problems.append(
                    f"commit {commit}: {address} names a machine. Set `git config user.email` (GitHub's "
                    "noreply address works), then `git rebase -r <base> --exec 'git commit --amend --no-edit --reset-author'`")
    elif argv:
        sys.exit(__doc__)
    for problem in problems:
        print(problem)
    print(f"{len(problems)} finding(s)." if problems else "No personal data found.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
