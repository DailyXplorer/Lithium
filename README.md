# Lithium

A light, native macOS browser built on the system's WebKit (SwiftUI + WKWebView), no Chromium. Arc-style layout: pinned sites as tiles and tabs in a sidebar. Privacy first, with uBlock Origin's filter lists built in.

## Build and run

```sh
./scripts/build-app.sh --run        # builds .build/Lithium.app and opens it
./scripts/build-app.sh --install    # installs it in /Applications
swift test                          # unit and end-to-end tests
CFFIXED_USER_HOME=$(mktemp -d) swift test --filter BrowserTests   # a whole Browser, in a throwaway home
```

On the first build, `scripts/update-filters.py` downloads the filter lists and converts them (into `Sources/Lithium/Resources/Filters`, not versioned). Run it again to refresh the lists, then rebuild.

`.build` is a symlink to `~/Library/Caches/Lithium/build`: iCloud-synced folders tag build products with extended attributes that break code signing.

## Protections

- **Network and cosmetic blocking.** uBlock Origin (filters, privacy, badware, quick-fixes, unbreak, resource-abuse), EasyList, EasyPrivacy, Peter Lowe and URLhaus, compiled into native WebKit content rules by AdGuard's converter.
- **Advanced uBO rules.** Scriptlets (anti-adblock defusers, YouTube ad removal, …), procedural cosmetics like `:has()`, and CSS injection. AdGuard's filter engine picks the rules for each page and Lithium injects them at document start, before any page script. uBO's `+js()` filters run uBlock Origin's own scriptlets with uBO's own argument parser (`Privacy/UBOScriptlets.swift`), as they would in uBO: AdGuard's look-alikes take different arguments and lack the newest ones, which YouTube's ads are fought with. `node scripts/update-ubo-scriptlets.mjs [tag]` refreshes them from a uBO release.
- **Fingerprinting protection.** WebKit's own Advanced Fingerprinting Protection (engine-level canvas noise, window-sized `screen`, link decoration filtering), plus Brave-style farbling (`Resources/Scripts/farbling.js`): deterministic noise per site and session on canvas, OffscreenCanvas, WebGL `readPixels`, audio and `hardwareConcurrency`, a reduced voice list, and the same protection for same-origin iframes. Invisible to `toString` checks.
- **Filter lists update daily** in the background (Settings, Privacy & Security, Update now to force it).
- **Also.** Tracking parameters stripped from URLs, fraudulent-site warnings, HTTPS upgrades for known hosts, popups blocked unless user-initiated.
- The shield in the toolbar turns protections off for a single site.

`Tests/Manual/protections.html` checks blocking and fingerprinting live: open it in Lithium through a `file://` URL.

## Files

Lithium shows up in Finder's Open With menu for Markdown and PDF files, without taking over as their default app.

- **Markdown** (`.md`, `.markdown`, …) renders as a formatted document, locally or when a server sends it as plain text. Rendering happens in the page after the file loads (`Model/MarkdownReader.swift`, `Resources/Scripts/markdown-reader.js`, parsed by the bundled [marked](https://github.com/markedjs/marked)), so the address, reload and history stay the file's own. HTML inside the file displays, but a content security policy stops it from running scripts.
- **PDF** files, local or from the web, open in Lithium's own viewer (`Model/PDFReader.swift`, `Views/PDFReaderView.swift`): page thumbnails or the outline on the side, a page field, zoom and fit to width or page, rotation, a two-page view, find (⌘F), print (⌘P), download (it saves the bytes the page received, so an expired link still works), and Open in Preview for signing or annotating. WebKit still loads the file, so the address, reload and history stay the file's own; Lithium reads the bytes WebKit received and draws the document with PDFKit over WebKit's viewer. That relies on two private WebKit calls (`_isDisplayingPDF`, `_getMainResourceDataWithCompletionHandler:`); without them, WebKit's viewer shows instead.

A local file gets read access to its own folder, so relative images and links to neighbouring files work.

## DM Sans on every site

Websites render in DM Sans instead of their own fonts (Settings › Appearance, on by default). Elements whose own font is an icon font (Font Awesome, Material Symbols, Glyphicons, or any font drawing Private Use Area glyphs), a monospace font or a math font keep it, along with everything inside them. `Resources/Scripts/page-font.js` finds them by briefly lifting the override on new content and reading the font the site chose, before it paints. Pages get the font as WOFF2 (89 KB instead of the TTF's 240 KB), since each one decodes it again; `scripts/make-web-font.py` makes it from `DMSans.ttf`.

## Sleeping tabs

A background tab left alone for 30 minutes releases its page, unless it is playing sound or was a few minutes ago (so a pause between tracks doesn't count), using the camera or microphone, sharing the screen, or loading. It wakes when selected, on the same page with its back and forward history (WebKit's `interactionState`, which also brings back the scroll position when the page allows). Like any Back, the page may come from WebKit's cache rather than the network (⌘R fetches it again), and showing again a form's result WebKit no longer has asks before sending the form a second time, as Safari does (on Back and Reload too); a tab out of sight never sends one by itself, and a tab waking on one shows its address instead. A history with local files, `blob:` pages or Lithium's own pages in it isn't kept, nor is one whose tab shows a PDF: the tab loads its page afresh. In Low Power Mode or when the Mac runs hot, tabs sleep after 5 minutes (`defaults write app.lithium.browser tabIdleSeconds N` sets your own delay, which Low Power Mode leaves alone). For as long as macOS reports memory short, tabs idle for 5 minutes (or your own delay, if shorter) sleep, and every background tab that can when memory is critical, whatever the delay. A popup window with a size or position (a sign-in or payment window, say) and the page that opened it stay awake while both are open, so they can still talk to each other, unless memory is critical.

## Mini player

Leave a tab while its video plays with sound, and the video goes on playing in a small player in the page's bottom right corner, like Arc's. Coming back to the tab puts it back in the page. A muted video (an autoplaying loop, a preview) stays where it is. Pop Out Video in the page menu (⌥⌘P) does it for the tab in front, whose page then says where its video went. The player takes the tab's own web view, and `Resources/Scripts/video-popout.js` puts the video in the top layer (a manual popover) filling it, and puts it back there if the page moves its player (YouTube does when its window narrows): the site's own player keeps running, nothing is reloaded, and the page is left as it was when the video comes back. Hovering shows play and pause, 10 seconds back or forward, the time bar, sound, back to the tab and close (which pauses the video); a double click also goes back to the tab. The player stays wherever it is dropped, and keeps its distance from the nearest corner when the window changes size; its edges facing the page resize it, keeping the video's shape. It remembers its place and size. A tab whose video plays in it never sleeps.

## Screenshots

The camera button in the toolbar captures Lithium's window, the way Arc's Portrait Mode did. Click anywhere to take the whole window, or drag to take an area. For the whole window, the preview shows it with or without the sidebar (closed by default), and sets it on the Mac's wallpaper, a solid color or nothing at all, with an optional "Made with Lithium" badge, then copies it or saves a PNG. Lithium captures its own window through ScreenCaptureKit's current-process content (`Model/ScreenCapture.swift`), so it needs no Screen Recording permission.

## Max

Optional intelligence features, toggled one by one in Settings › Max.

- **Tidy tab titles.** Long page titles become short tab names ("WebKit project" for GitHub's full repository description). Rules strip notification counters and the site's name first, instantly and without any model (`Max/TitleCleaner.swift`). Titles still longer than a sidebar row (22 characters) go to Apple's on-device model through the Foundation Models framework (`Max/ModelTitles.swift`): one request at a time, a fresh session each, greedy decoding, in the title's own language, about half a second on an M4 Pro. Answers are validated before use (one line, 40 characters at most, no links, at least one word shared with the page's title) so a title written to steer the model can't. Names are cached per site and title; names you give tabs always win, and the original title shows on hover. Needs macOS 26 with Apple Intelligence for the model part; FoundationModels is weak-linked, so Lithium still runs on macOS 15.4 with rule-based tidying.

- **Summarize pages.** The sparkle button in the toolbar sums up the page in one sentence and a few key points, written in your language (or the one picked in Settings › Max). With 30 words or more selected, it summarizes only the selection. Nothing runs until you click. The text comes from the page's article or main content, without menus, sidebars and footers (`Resources/Scripts/page-text.js`). Text longer than one request (about 21,000 characters on macOS 27, 8,700 on macOS 26) is summarized part by part, then the notes are merged (`Max/ModelSummaries.swift`). The model serves one request at a time, so it takes about 0.55 s per 1,000 characters on an M4 Pro: a long Wikipedia article (88,000 characters) takes about a minute. Pages are read up to 200,000 characters. A summary keeps running when its popover closes, and stays with the tab until it leaves the page. It uses the permissive guardrails Apple provides for transforming text, so news about sensitive subjects still gets summarized. Lines with a link are dropped from answers, so a page can't slip one in.

- **Fix spelling and grammar.** A small button appears in the bottom right corner of the text box you're writing in (a textarea or a rich text editor like Gmail's, once it holds a few words); clicking it or pressing ⌥⌘K fixes spelling, grammar and punctuation mistakes without rewording anything. One ⌘Z brings back what you wrote. Apple's on-device model rewrites the text in pieces of about 1,200 characters, and an answer counts only if it keeps the same lines, about the same length and at most a third of the letters changed; a translation, a summary or a reply to the text is thrown away (`Max/CorrectionText.swift`, `Max/ModelCorrections.swift`). About 1 s for a short email on an M4 Pro. Only the words that changed are replaced, each as typed text (`Resources/Scripts/text-correction.js`), so bold, links and the editor's own state stay as they were; changes of spacing or apostrophe style are left out. Quoted replies and Gmail signatures aren't touched. One-line inputs and fields with spellchecking off (code editors) get no button. The button and its script live in Lithium's own content world, so pages can neither see it nor ask for corrections.

`LITHIUM_MODEL_TESTS=1 swift test` also runs the real model on sample titles, pages and texts to correct.

## Extensions

Extensions from the Chrome Web Store install with the store's own Add to Chrome button, and run on WebKit's own extension support (`WKWebExtension`, macOS 15.4 and later), without Chrome. On the store, Lithium presents itself as Chrome 141 and gives the page the `chrome.webstorePrivate` and `chrome.management` calls its button uses (`Resources/Scripts/webstore.js`, answered by `WebstoreBridge` in `Model/ChromeWebStore.swift`). A click asks first, in Lithium's own dialog, listing what the extension can do in Chrome's words. The package then comes from Google's update server, and must be the extension the store named (the id in the CRX3 header has to match). Lithium does not check the package's signatures: the download comes straight from Google over HTTPS. Lithium keeps its ZIP archive in `~/Library/Application Support/Lithium/Extensions`, with an unpacked copy it loads at launch (`Model/Extensions.swift`), since WebKit would unpack the archive again at every launch.

The puzzle-piece button in the toolbar lists the extensions with their badges and opens each one's popup, its options page opens in a tab, and it sees Lithium's tabs and window through `chrome.tabs` and `chrome.windows`. Settings › Extensions lists them, turns them off or removes them with their data. Most extensions work; the ones that rely on parts of Chrome WebKit doesn't have may not.

`LITHIUM_LIVE_TESTS=1 CFFIXED_USER_HOME=$(mktemp -d) swift test --filter BrowserTests/addsAnExtension` adds SponsorBlock from the real store, through its button and Lithium's dialog, and watches it skip a sponsor on YouTube.

## Settings and internal pages

Settings (`lithium://settings`, ⌘,) and History (`lithium://history`, ⌘Y) are web pages, served from `Resources/Pages`. Websites cannot open `lithium://` pages or load their files, and the page's bridge to the app (`InternalBridge`) only exists while a tab shows one.

## Shortcuts

⌘T new tab · ⌘W close tab · ⇧⌘T reopen closed tab · ⌘L address bar · ⌘B sidebar · ⌘D pin · ⌘1…9 go to item · ⌃Tab next tab · ⌘[ / ⌘] back and forward · ⌘R reload · ⌘F find · ⌘P print · ⌘G / ⇧⌘G next and previous match · ⌘Y history · ⇧⌘C copy link · ⇧⌘S summarize page · ⇧⌘P protections on or off for the site · ⌥⌘P pop out the video · ⌘, settings

## License

GPL-3.0 (see `LICENSE`). Lithium bundles GPL-3.0 components: AdGuard SafariConverterLib, Scriptlets and ExtendedCss, and uBlock Origin's filter lists and scriptlets. It also bundles [marked](https://github.com/markedjs/marked) (MIT). Icons are [Phosphor](https://phosphoricons.com) (MIT). The DM Sans font is under the SIL Open Font License.
