# Third-party notices

Lithium is under GPL-3.0 (see [`LICENSE`](LICENSE)). It bundles or links the work of others, each under its own license. The license texts in [`LICENSES`](LICENSES) are copied from each project as published.

## In this repository

| Component | Where | License |
|---|---|---|
| [marked](https://github.com/markedjs/marked) 18.0.14 | `Sources/Lithium/Resources/Scripts/marked.min.js` | [MIT](LICENSES/marked-MIT.md) |
| [Mozilla Readability](https://github.com/mozilla/readability) 0.6.0 | the end of `Sources/Lithium/Resources/Scripts/reader.js` | [Apache-2.0](LICENSES/Readability-Apache-2.0.md), Copyright (c) 2010 Arc90 Inc |
| [Phosphor Icons](https://phosphoricons.com) 2.1.1 | `Sources/Lithium/Resources/Icons` | [MIT](LICENSES/Phosphor-MIT.txt) |
| [DM Sans](https://github.com/googlefonts/dm-fonts) 4.004 | `Sources/Lithium/Resources/Fonts` | [SIL Open Font License 1.1](LICENSES/DMSans-OFL-1.1.txt) |
| [AdGuard ExtendedCss](https://github.com/AdguardTeam/ExtendedCss) 2.1.1 | `Sources/Lithium/Resources/Scripts/extended-css.min.js` | GPL-3.0, Copyright (c) 2024 AdGuard |
| [AdGuard Scriptlets](https://github.com/AdguardTeam/Scriptlets) 2.3.1 | `Sources/Lithium/Resources/Scripts/scriptlets.corelibs.json` | GPL-3.0 |
| [uBlock Origin](https://github.com/gorhill/uBlock) scriptlets 1.75.0 | `Sources/Lithium/Resources/Scripts/scriptlets.ubo.json` | GPL-3.0, Copyright (C) 2020-present Raymond Hill |

GPL-3.0 is the license in [`LICENSE`](LICENSE).

## Linked into the app

Swift Package Manager downloads these at build time, at the versions pinned in `Package.resolved`.

| Package | License |
|---|---|
| [AdGuard SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib) | GPL-3.0 |
| [swift-psl](https://github.com/ameshkov/swift-psl) | [MIT](LICENSES/swift-psl-MIT.txt) |
| [PunycodeSwift](https://github.com/gumob/PunycodeSwift) | [MIT](LICENSES/PunycodeSwift-MIT.txt) |

## Downloaded at build time

`scripts/update-filters.py` downloads the filter lists named in `Sources/Lithium/Resources/FilterSources.json` and converts them into the app. They are not in this repository. Each list belongs to its publisher and comes under that publisher's license.
