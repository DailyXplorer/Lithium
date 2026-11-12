"""Soft size nudge for pull requests: warn, never block.

Counts the lines a reviewer actually reads (added + deleted) and, above the budget in
CONTRIBUTING.md, keeps one comment on the pull request saying so. The comment is updated in
place on later pushes and never duplicated.

  pr_size.py   reads $GH_TOKEN, $REPO and $PR_NUMBER and calls the GitHub API with `gh`;
               the unit tests import counted() and render()

Excluded from the count: `Package.resolved`, test fixtures, the license texts of other
projects, and the resources a script vendors or generates (minified libraries, scriptlet
bundles, icons, fonts).
"""

import os
import re
import subprocess
import sys

BUDGET = 600
MARKER = "<!-- pr-size-check -->"
BOT = "github-actions[bot]"
EXCLUDED = re.compile(
    r"(^|/)Package\.resolved$"
    r"|(^|/)Fixtures/|^LICENSES/"
    # written by scripts/update-ubo-scriptlets.mjs, scripts/update-space-icons.py and
    # scripts/make-web-font.py, or copied whole from their upstream
    r"|\.min\.js$|(^|/)Resources/Scripts/scriptlets\.[^/]+\.json$"
    r"|(^|/)Resources/(Icons|Fonts)/|(^|/)Resources/SpaceIcons\.tsv$"
)


def counted(files):
    """Changed lines in `files`, a list of (path, additions, deletions)."""
    return sum(added + deleted for path, added, deleted in files if not EXCLUDED.search(path))


def render(lines, repo):
    over = lines > BUDGET
    if over:
        verdict = (
            f"This pull request changes **{lines}** lines (`Package.resolved`, fixtures and vendored or "
            f"generated resources excluded), above the soft budget of **{BUDGET}**. Smaller pull requests are "
            "reviewed and merged faster: consider a small refactor PR first, then the feature in slices that "
            "each build and pass on their own."
        )
    else:
        verdict = f"This pull request is now within the soft budget: {lines} of {BUDGET} changed lines."
    return (
        f"{MARKER}\n{verdict}\n\n"
        "This is a nudge, not a check that blocks: generated code or a mechanical rename can justify "
        "going over, say so in the description. See "
        f"[Before you open a pull request](https://github.com/{repo}/blob/main/CONTRIBUTING.md#before-you-open-a-pull-request)."
    )


def gh(*args):
    try:
        return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout
    except subprocess.CalledProcessError as e:
        print(e.stderr, file=sys.stderr)
        raise


def main():
    # int(): the number may come from a hand-typed workflow input, and goes into API paths.
    repo, number = os.environ["REPO"], int(os.environ["PR_NUMBER"])
    tsv = gh("api", "--paginate", f"repos/{repo}/pulls/{number}/files",
             "--jq", r'.[] | [.filename, .additions, .deletions] | @tsv')
    files = []
    for row in tsv.splitlines():
        path, added, deleted = row.rsplit("\t", 2)
        files.append((path, int(added), int(deleted)))
    lines = counted(files)

    existing = gh("api", "--paginate", f"repos/{repo}/issues/{number}/comments",
                  "--jq", f'.[] | select(.user.login == "{BOT}" and (.body | startswith("{MARKER}"))) | .id')
    comment_id = existing.split()[0] if existing.split() else None

    print(f"{lines} counted lines, budget {BUDGET}, existing comment: {comment_id}")
    if comment_id:
        gh("api", "--method", "PATCH", f"repos/{repo}/issues/comments/{comment_id}", "-f", f"body={render(lines, repo)}")
    elif lines > BUDGET:
        gh("api", "--method", "POST", f"repos/{repo}/issues/{number}/comments", "-f", f"body={render(lines, repo)}")


if __name__ == "__main__":
    sys.exit(main())
