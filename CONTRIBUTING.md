# Contributing to Lithium

Thanks for helping. These rules keep Lithium light, private and easy to review.

## Prerequisites

- A Mac with Xcode 27 (Swift 6.4), the toolchain Lithium is developed with. The app runs on macOS 15.4 and later.
- Python 3, which comes with Xcode's command line tools. The first build runs `scripts/update-filters.py` to download and convert the filter lists.
- Node, only to refresh the bundled uBlock Origin scriptlets (`scripts/update-ubo-scriptlets.mjs`).

No account, key or paid service is needed to build, run or test Lithium.

## Commands

Every command runs from the repository root.

| Command | What it does |
|---|---|
| `./scripts/build-app.sh` | Builds and signs `.build/Lithium.app`, and touches nothing else. |
| `./scripts/build-app.sh --run` | Also opens it. A running Lithium quits first. |
| `./scripts/build-app.sh --install` | Also replaces the copy in `/Applications`. A running Lithium quits first. |
| `./scripts/test --filter <Suite>` | Runs one suite, for example `--filter PasswordVaultTests`. A filter that matches no test fails the run. |
| `./scripts/test-fast` | Runs every suite in shards side by side, in about 75 seconds. For iterating. |
| `./scripts/test` | The reference run before a merge: one test at a time, in about 5 minutes. |
| `python3 -m unittest discover -s .github/tests` | Tests the scripts behind the pull request checks. |
| `python3 scripts/update-filters.py` | Refreshes the filter lists. Rebuild afterwards. |

Never run plain `swift test`: side by side, the suites that run a whole browser share one settings folder and break each other. The README's [Running tests](README.md#running-tests) section says more. `scripts/test` ends by naming the tests it skipped because they only run when asked (real network, real model, real sites).

## Conventions

- **Branches**: cut from `main`, named after what they do (`fix/…`, `feat/…`, `docs/…`, `ci/…`).
- **Commits**: a subject in the imperative that says what changes ("Open a favorite's context menu on right-click"), and a body that says why when the subject can't. Commit with an address you accept to see in public history: GitHub's `noreply` address works (GitHub › Settings › Emails).
- **Language**: code, comments, docs, commits and UI text are in English.
- **Code style**: match the code around yours. Comment only to explain *why*, never to repeat what the code says.
- **Personal data**: none in code, commits, docs, issues or pull requests. No names, email addresses, account ids, machine names or paths to your home folder. Use `example.com` addresses and `/Users/me/…` paths in tests and examples.
- **Dependencies**: Lithium uses Swift Package Manager. `Package.resolved` is committed on purpose: it pins the exact version of each package, so every checkout builds the same code. Change it only in a pull request that means to change a dependency.

## Tests

- Every bug fix and every feature comes with a new or updated test in `Tests/LithiumTests` (Swift Testing). A fix starts with a test that fails without it.
- A test never shows a window, plays sound, or opens another app on the screen of whoever runs it. Windows are `OffscreenWindow`s (`Tests/LithiumTests/Support`), and `scripts/test` fails a run that launched an app.
- Tests that need the network, a real model or a real site are gated behind their own variables (`LITHIUM_NETWORK_TESTS`, `LITHIUM_MODEL_TESTS`, `LITHIUM_LIVE_TESTS`) and stay off by default. A test must not depend on today's date or on how fast the machine is.
- UI snapshot tests are opt-in: they write PNGs only when `LITHIUM_SNAPSHOT_DIR` is set, for example `LITHIUM_SNAPSHOT_DIR=/tmp/shots ./scripts/test --filter UISnapshotTests`.

## Before you open a pull request

The pull requests that merge fastest are small, focused, in sync with `main` and tested when review starts. [The pull request template](.github/pull_request_template.md) repeats this list.

1. **One concern per pull request.** A fix, a feature, a refactor and a dependency bump are four pull requests. Do not mix a mechanical change (rename, move, reformat) with a change of behavior.
2. **Stay under about 600 changed lines**, not counting `Package.resolved`, test fixtures and vendored or generated resources (minified libraries, scriptlet bundles, icons, fonts). It is a soft budget: a workflow comments on a ready pull request above it, and never blocks it. If the work is bigger, land a small refactor first, then the feature in slices that each build and pass on their own. If it cannot be split, say why in the description.
3. **Discuss first** what is not a bug fix. Open an issue for a feature, a change to the interface or a new dependency, and agree on the approach before writing it.
4. **Sync with `main`** right before you open the pull request, and again before you ask for another round. Open a draft while something is still red.
5. **Test what you changed**: `./scripts/test --filter <Suite>` for the suites that cover it, then `./scripts/test` (or `./scripts/test-fast`) before asking for a merge.
6. **Check what your change costs when nobody uses it.** A feature that is off or unused adds no timers, observers, page scripts or web views until it is used, and nothing on the paths every page or tab goes through. For a change on those paths, measure before and after and put the numbers in the description.
7. **Docs travel with the code.** A change a user can see updates the matching section of the README.
8. **Read your own diff** as a reviewer would, and check it holds no personal data.

### Contributing with a coding agent

Most pull requests here are written with a coding agent. The agent reads [`AGENTS.md`](AGENTS.md), which points back to this page. The loop below is what makes its output reviewable. You stay responsible for every line you push.

- **Settle the design before the code.** Have the agent interview you about the plan (inputs, edge cases, what is out of scope) until no decision is left implicit, then write the decisions into the pull request description.
- **Impact analysis first.** Before editing, list the callers, tests, page scripts and docs the change touches.
- **Fix the whole bug class**, not the reported line. Search for the same pattern elsewhere, and cover each fixed instance with a test.
- **Prove it works.** A claim in the description comes with what showed it: the test that fails without the change, the measurement before and after. Say what was not tested.
- **Self-review loop, before opening and after every push.** Run a reviewer agent on the full diff against `main` (for example Claude Code's `/code-review`, or any reviewer you trust), fix what it reports, and run it again until it reports no blocking issue. Treat CodeRabbit the same way: answer or fix every thread before requesting the maintainer.
- **Do not weaken a rule to pass.** If a test, a check or a convention gets in the way, say so in the description instead of editing the rule in the same diff.

Optional, open-source tools that fit this loop. They are recommendations, not requirements:

- [pstack](https://github.com/cursor/plugins/tree/main/pstack), rigorous engineering playbooks by poteto. With Claude Code, install [its port](https://github.com/michael-denyer/pstack-claude) (`/plugin marketplace add michael-denyer/pstack-claude`, then `/plugin install pstack@pstack-claude`) and use its `poteto-mode` skill.
- The [`grilling` skill](https://github.com/mattpocock/skills/tree/main/skills/productivity/grilling) from `mattpocock/skills`, to settle design decisions before coding.

If you used them, list them in the pull request description.

### Opening the pull request

- Fork, branch from `main`, and open the pull request against `main`.
- Fill in the [template](.github/pull_request_template.md): what and why, the issue it closes, how you tested it, and what a self-review found.
- The maintainer merges with a merge commit, so your commits land as you wrote them. Keep each one buildable and its message honest.

## Reporting a bug

Open an issue with:

- the steps to reproduce it, starting from a new tab if you can;
- what you expected to happen;
- what happened instead;
- a screenshot or a screen recording when it shows the problem, and your macOS and Lithium versions.

Check that a screenshot shows nothing private (tabs, bookmarks, account names) before you attach it.

## Security issues

Do not open a public issue for a vulnerability. [`SECURITY.md`](SECURITY.md) says how to report it privately.

## License

Lithium is under GPL-3.0 (see `LICENSE`). By contributing, you agree that your contributions are licensed under GPL-3.0 too.
