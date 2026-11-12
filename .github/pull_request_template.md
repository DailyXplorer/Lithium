<!-- Short on purpose. Details: CONTRIBUTING.md, "Before you open a pull request". -->

## What and why

<!-- What changes, and why. Link the issue: "Closes #123". For a feature or an interface change: the issue where the approach was agreed. -->

## How it was tested

<!-- The suites you ran and what they showed. For a fix: the test that fails without it. For a change on a path every page or tab goes through: the numbers before and after. Say what was not tested. -->

## Checklist

- [ ] **One concern**, about 600 changed lines or fewer (`Package.resolved`, fixtures and vendored or generated resources excluded). If bigger, say why it cannot be split: <!-- reason -->
- [ ] **Synced with `main`**, and the checks are green; this is a draft until they are.
- [ ] **Tests** cover the change and its failure case (`./scripts/test --filter …`). None shows a window, plays sound, opens an app, or depends on the network or today's date.
- [ ] **No cost when unused**: no timers, observers, page scripts or web views until the feature is used.
- [ ] **Docs**: the README section a user-visible change belongs to is updated.
- [ ] **No personal data** in code, commits, docs or screenshots: no names, email addresses, machine names or home-folder paths.

## Self-review

<!-- Which reviewer agent or loop you ran on the full diff, how many rounds, and what it found and you fixed. "None" is a valid answer only for a trivial change. -->

## Design decisions

<!-- The choices a reviewer could question, and why you made them. Say which tools you used to settle them, if any. -->
