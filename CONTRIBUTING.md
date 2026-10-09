# Contributing to Lithium

Thanks for helping. These rules keep Lithium light, private and easy to review.

## Branches and pull requests

- One topic per pull request: a fix, a feature or a cleanup, not several.
- Branch from `main` and give the branch a name that says what it is (`fix/…`, `feat/…`).
- Give the pull request a descriptive title. Its description says what changes and why, and how you tested it.

## Before you open a pull request

- Read your own diff first, as a reviewer would.
- Build and run the tests that cover what you changed: `./scripts/test --filter <Suite>` (or `./scripts/test-fast` while iterating). Run `./scripts/test` before asking for a merge.
- Check what your change costs when nobody uses it. A feature that is off or unused adds no timers, observers, page scripts or web views until it is used, and nothing on the paths every page or tab goes through.

## Code style

- Code, comments, docs and UI text are in English.
- Match the code around yours. Comment only to explain *why*, never to repeat what the code says.
- Keep personal data out of code, commits and docs: no names, email addresses, account ids or paths to your home folder.

## Tests

- Every bug fix and every feature comes with a new or updated test in `Tests/LithiumTests` (Swift Testing).
- UI snapshot tests are opt-in: they write PNGs only when `LITHIUM_SNAPSHOT_DIR` is set, for example `LITHIUM_SNAPSHOT_DIR=/tmp/shots ./scripts/test --filter UISnapshotTests`.
- Tests that need the network or a real model are gated behind their own variables (see the README), and stay off by default.

## Dependencies

Lithium uses Swift Package Manager. `Package.resolved` is committed on purpose: it pins the exact version of each package, so every checkout builds the same code. Update it only in a pull request that means to change a dependency.

## Reporting a bug

Open an issue with:

- the steps to reproduce it, starting from a new tab if you can;
- what you expected to happen;
- what happened instead;
- a screenshot or a screen recording when it shows the problem, and your macOS and Lithium versions.

## License

Lithium is under GPL-3.0 (see `LICENSE`). By contributing, you agree that your contributions are licensed under GPL-3.0 too.
