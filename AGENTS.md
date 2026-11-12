# Lithium

A light, native macOS browser built on the system's WebKit (SwiftUI + WKWebView, no Chromium). Swift Package Manager, Swift 6, no Xcode project. The [README](README.md) describes every feature and names the files behind it.

## Layout

- `Sources/Lithium/App`: the app's entry point and theme.
- `Sources/Lithium/Model`: state and logic (the browser, its windows and tabs, the readers, screenshots).
- `Sources/Lithium/Views`: the SwiftUI and AppKit interface.
- `Sources/Lithium/Privacy`: filter lists, content blocking, scriptlets.
- `Sources/Lithium/Agent`: the MCP server agents drive Lithium through ([design](docs/design/agent-mcp.md)).
- `Sources/Lithium/Max`: the optional on-device model features.
- `Sources/Lithium/Resources/Scripts`: scripts Lithium injects in pages. `Resources/Pages`: the `lithium://` pages.
- `Sources/LithiumMCP`: `lithium-mcp`, the stdio bridge MCP clients start.
- `Tests/LithiumTests`: the Swift Testing suites, their `Support` helpers and `Fixtures`.
- `scripts`: build, test and update scripts. `.github`: pull request checks and their tests.

## Commands

See [CONTRIBUTING.md](CONTRIBUTING.md#commands). In short: `./scripts/test --filter <Suite>` for the suites covering your change, never plain `swift test`, and never two builds or test runs at once (they share `.build`).

## Rules

[CONTRIBUTING.md](CONTRIBUTING.md) applies to you in full, its [Before you open a pull request](CONTRIBUTING.md#before-you-open-a-pull-request) list first. What agents get wrong most often:

- **Do not disturb the person at the keyboard.** Tests show no window (use `OffscreenWindow`), play no sound and open no app. `./scripts/build-app.sh --run` and `--install` quit their running Lithium: run them only when asked.
- **One concern, about 600 changed lines.** Split the work before you write it, not after.
- **Prove it works.** A fix comes with a test that fails without it. A performance claim comes with numbers before and after. Say what you did not test.
- **Nothing on the hot paths for free.** Code that runs for every page, frame or tab is measured, and a feature that is off costs nothing. `LITHIUM_SCRIPT_COST=1 ./scripts/test --filter ScriptCostProbe` measures what the injected scripts cost a page.
- **English, and comments that say why.** Code, comments, docs, commits and UI text.
- **No personal data.** No names, email addresses, account ids, machine names or home-folder paths in code, tests, commits or pull requests. Commit with the identity git is configured with, never one made up from the machine's name.
- **Do not weaken a rule to pass.** If a test or a check is in the way, say so instead of editing it in the same change.
- **Other software's behavior is recreated, never copied.** No proprietary code, images or text from another browser or site.
