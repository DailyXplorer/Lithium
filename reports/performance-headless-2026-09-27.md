# Performance audit of Lithium and Helium, 27 September 2026

This is a record of that day. Findings and file references describe the code as it was then. The font regression reported below was fixed before the change landed, the next day (commit `c8380ae`), and `PageFontTests.largeContainerFollowsItsClassChanges` covers it.

The local changes improve the handling of large containers, the canvas anti-fingerprinting noise and the way filters are applied. A font regression is reproduced in the large-container optimization. Helium stays faster at creating the DOM of this test page. WebKit without Lithium's additions already shows almost all of that gap.

## Scope and protocol

The Swift code and the resources of the working tree were compiled in release, uncommitted changes included. The reference commit is `75c9f0f7a272c59845a1f930dd2aa321e795d314`. The before and after comparisons cover the scripts `page-font.js` and `farbling.js`, and separately the raw and the prepared native rules. The "HEAD scripts" column is not a full build of the old application.

The machine is a MacBook with an Apple M4 Pro and 24 GB, on macOS 27.0, build 26A428. WebKit is version 22625.1.29.11.27. Helium 0.18.1.1 ships Chromium 154.0.8037.57. The tests run on battery, at a reduced priority (`nice 15`). The user's browsers and the other applications stay open.

Lithium is exercised through the system's WebKit and its real compiled types. The `WKWebView`s have no visible window. Helium is started with `--headless=new`, a clean temporary profile and the sound off. [Chromium's headless mode](https://developer.chrome.com/docs/automation-and-testing/headless) allows this run without a window on screen. Each browser runs separately. The temporary profiles read neither the user's history nor their extensions.

The size is 1280 × 800. Each microtest has one warm-up pass and seven measurements. Three test processes in a row give 21 measurements per cell. The order of WebKit and Helium, and the order of the WebKit variants, is reversed on the second pass. The numbers are the pooled medians, in milliseconds. Smaller is better.

| Operation | WebKit alone | HEAD scripts | Local scripts | Helium |
|---|---:|---:|---:|---:|
| JSON and sorting, 15 series of 6,000 objects | 16.0 | 17.0 | 17.0 | 15.3 |
| DOM, 2,500 rows with a height read | 19.0 | 18.0 | 18.0 | 7.3 |
| Layout, 12 changes over 1,200 rows | 28.0 | 28.0 | 29.0 | 21.1 |
| Canvas, 8 reads of 512 × 512 pixels | 2.0 | 9.0 | 4.0 | 39.3 |

The raw measurements and their JSON summary hold the values of every pass. They were written to `.tools/perf-audit-2026-09-27/final/`, a folder that is not versioned. The same goes for every JSON file and log named below.

The DOM test measures a synchronous creation and a height read. It does not include the deferred work of the font observer, measured separately below. The DOM result is 18 ms for the local scripts against 7.3 ms for Helium. WebKit alone is at 19 ms. This result does not allow blaming that gap on the protections Lithium adds.

The canvas goes down from 9 to 4 ms with the new script, about 56% less time on this case. The 512 × 512 canvas stays under the script's limit of 500,000 pixels. The protections differ between Helium and Lithium. The canvas result is therefore no proof that WebKit is faster in general, nor that their fingerprinting protections are equivalent.

## Local changes measured

### Fonts and large containers

A page of 1,500 rows, 4,500 descendants of the container, toggles its class six times. Instrumentation in the isolated world measures the time spent in the font callbacks and the number of style reads. The 450 ms wait between mutations is excluded from the reported time.

The HEAD script makes between 4,501 and 7,501 style reads per change. Its median is 13.5 ms. The local script makes only one. Its median is below the resolution of the clock, about one millisecond. The 0 ms values must not be read as a cost of zero.

A regression comes with this gain. The rule `.special .icon { font-family: Menlo, monospace; }` applies to a child when its grandparent takes the class `special`. The old script then keeps Menlo. The new one keeps DM Sans on the three activations tested. The condition in [page-font.js](../Sources/Lithium/Resources/Scripts/page-font.js) (line 192 at the time) rechecks only the large container. It ignores the font change of the descendant caused by a CSS selector on the ancestor.

This is the first point to fix. A selective recheck must include the descendants whose font rule depends on the changed class. A deferred full pass is another lead to compare. Bringing back the initial synchronous scan every time would also bring back its cost.

Evidence in `font-mutations.json`. The existing `PageFontTests` pass because their large container changes font itself. They do not cover this selector applied to a descendant only.

### Native filters

A local page loads 160 distinct scripts without a cache. The three real bundled lists are compiled. Five loads alternate the variants.

| Variant | Median load |
|---|---:|
| No rules | 84 ms |
| Raw rules | 91 ms |
| Rules prepared by the local code | 84 ms |

The gain observed is about 8% over the raw rules in this scenario. It does not confirm the factor of 2.3 mentioned in a code comment, measured on another workload. A cosmetic control rule does hide its element with the raw and the prepared variants. The 160 expected scripts run in each variant.

The initial preparation and compilation of the three lists take 5.10 s in total against 4.75 s for the raw lists in this pass. That time includes the JSON rewrite, not only WebKit's compiler. It is not the time of each navigation. The cache normally avoids this work. However, `Tab.applyProtections` waits for `privacy.waitUntilReady()` before allowing the navigation. A start with a missing or invalidated cache can therefore wait for the compilation. This is deduced from the code, not measured on a full launch of the application. Protection must be preserved through any optimization of this path.

Evidence in `native-rules.json`, `rule-compilation.json`, [Privacy.swift](../Sources/Lithium/Privacy/Privacy.swift) (line 187 at the time) and [Tab.swift](../Sources/Lithium/Model/Tab.swift) (line 192 at the time).

### History search

The test database is synthetic. No personal history was used. The queries run five times per case through the real functions of `HistoryStore`.

| History and query | Synchronous function | Background function |
|---|---:|---:|
| 10,000 visits, `site` | 4.7 ms | 4.6 ms |
| 200,000 visits, `site` | 61.3 ms | 59.6 ms |
| 200,000 visits, `article 123` | 22.3 ms | 22.0 ms |
| 200,000 visits, no result | 14.1 ms | 14.0 ms |

Moving the work off the main thread helps responsiveness. It does not reduce the SQL work. The query keeps a `LIKE '%text%'` search, a `NOT INDEXED` scan and a grouping of the visits. At a large size, a table of pre-aggregated pages and a search index are leads to measure before adopting them. The CPU throughput and the energy use of this path are not measured here.

Evidence in `history-search.json` and [History.swift](../Sources/Lithium/Model/History.swift) (line 98 at the time).

## Checks and limits

The four measurement tests of the first pass succeed. The two repetitions of the microtest succeed. The 12 existing tests of the AddressSuggestions, Extensions, Fingerprinting, HistoryStore, PageFont and RuleList suites pass in release with a temporary user folder. The log of the existing tests (`regression-tests.log`) holds the details. The existing tests passing does not cover the CSS selector regression reproduced here.

The user's Lithium process, PID 14072 at the start of the audit, stayed active. No packaging, installation or app-closing script was run. The test's visibility assertion confirms that no window was visible. WebKit creates a hidden internal `TUINSWindow`, visible in `test-windows.json`.

These measurements are not an overall ranking of the two browsers. They measure neither battery, nor the memory of the whole application, nor frames dropped during YouTube, nor the smoothness of visible scrolling. The changes to extension loading, lazy tab creation and favicons are included in the build, but their gain is not quantified here. Per-site advanced filters and installed extensions are not present in the DOM and canvas microtests.

`document.visibilityState` is `hidden` in the WebKit views and `visible` in headless Helium. This mostly limits the conclusions about animations and deferred work. The synchronous measurements wait for no `requestAnimationFrame`. The user's video and the other applications remain a source of variation. WebKit's JavaScript clock is coarse, close to a millisecond in this protocol. Small gaps should not be over-interpreted. No official Speedometer score is claimed.

## Reproducing

From the repository, run the following command. It compiles the tests in release by default. It runs neither `scripts/build-app.sh` nor the older `scripts/bench/run.py`, because they close Lithium.

```sh
python3 scripts/bench/run-headless.py .tools/perf-audit-new --rounds 3
```

After a recent build of the tests, `--skip-build` avoids recompiling. The detailed results are written to the chosen folder. The temporary profiles are deleted after the tests. The sources are [HeadlessPerformanceTests.swift](../Tests/LithiumTests/HeadlessPerformanceTests.swift), [workloads.js](../scripts/bench/workloads.js), [headless-helium.mjs](../scripts/bench/headless-helium.mjs) and [run-headless.py](../scripts/bench/run-headless.py).

The `poteto-mode` skill guided the audit. Build the Lever led to keeping the reproducible scripts. Model the Domain led to comparing a table of variants on the same workloads. Prove It Works and Test Behavior, Not Implementation led to the measurements on the real WebKit, the hiding control and the check of the computed fonts. No subagent was used.
