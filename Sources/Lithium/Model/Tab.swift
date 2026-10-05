import AppKit
import Observation
import WebKit

/// How a load in the page ended without showing anything.
enum UnshownLoad {
    case download(fileName: String?)
    /// Lithium refused where it led: another app's scheme (`mailto:`), or its own pages.
    case refused(scheme: String)
}

@MainActor
@Observable
final class Tab: NSObject, Identifiable {
    let id = UUID()
    var pinID: Pin.ID?
    /// Made on first use and dropped while the tab sleeps, which frees the page's memory. A tab
    /// restored asleep at launch holds no web view at all until it is selected.
    var webView: WKWebView {
        access(keyPath: \.webView)
        if let loadedWebView { return loadedWebView }
        let webView = PageWebView(frame: .zero, configuration: configuration)
        webView.translation = browser?.translation
        webView.tab = self
        loadedWebView = webView
        attach(webView)
        return webView
    }
    @ObservationIgnored private(set) var loadedWebView: WKWebView?
    /// What the next web view is made with.
    @ObservationIgnored private var configuration: WKWebViewConfiguration
    private(set) var isAsleep = false
    @ObservationIgnored private(set) var lastActive = Date()
    /// The page's back and forward history (and scroll position) while the tab sleeps, so it
    /// wakes where it was left.
    @ObservationIgnored private var sleepingState: Any?
    /// The tab whose page opened this one as a popup window, as sign-in windows are.
    @ObservationIgnored weak var opener: Tab?
    /// The hub whose dialog the page waits on: it still answers it once agent access is off.
    @ObservationIgnored var dialogOwner: AgentHub?
    /// When the page was last heard, so a pause between tracks or while buffering isn't taken
    /// for silence.
    @ObservationIgnored private var lastHeard: Date?
    @ObservationIgnored private var isAskingPlayback = false
    /// Whether this web view has shown a page yet: one woken on a form's result has nothing to
    /// fall back on if the form isn't sent again.
    @ObservationIgnored private var hasShownPage = false
    /// The old page of a sleeping tab an extension sent elsewhere: its load, started by putting
    /// the history back, is cancelled. Cleared at the next main-frame decision, whichever it is.
    @ObservationIgnored private var supersededURL: URL?
    /// Where an extension sent a tab that slept without its history, loaded once its old page is
    /// shown, or once it is clear it won't be. Stopping the tab drops it.
    @ObservationIgnored private var addressAfterWaking: URL?
    /// The site of the page shown, which its frames belong to. `webView.url` moves to the next
    /// address as soon as it starts loading, while the frames still are the old page's.
    @ObservationIgnored private var shownHost: String?

    private(set) var title = ""
    private(set) var url: URL? {
        didSet {
            if PageSummaries.page(of: oldValue) != PageSummaries.page(of: url) { browser?.summaries.discard(self) }
        }
    }
    private(set) var favicon: NSImage?
    private(set) var faviconData: Data?
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Set while the page is a PDF, which Lithium draws with its own viewer.
    private(set) var pdf: PDFReader?
    /// The PDFs of this tab's history. WebKit brings such a page back from its cache without
    /// its bytes; the kept reader also comes back where it was left.
    @ObservationIgnored private var pdfHistory: [WKBackForwardListItem: PDFReader] = [:]

    @ObservationIgnored private weak var browser: Browser?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var appliedProtections: (enabled: Bool, generation: Int)?
    @ObservationIgnored private var failedURL: URL?
    @ObservationIgnored private var errorNavigation: WKNavigation?
    /// Why Lithium's error page stands in for the page, at the address that failed; cleared when
    /// another page commits.
    private(set) var loadError: NSError?
    var connection: SiteInfo.Connection { SiteInfo.Connection(url: url, loadError: loadError) }
    @ObservationIgnored private var lastCrashReload: Date?
    /// A `lithium://` page this tab was told to open by the app itself.
    @ObservationIgnored private var trustedInternalURL: URL?
    @ObservationIgnored private var hasInternalBridge = false
    @ObservationIgnored private var hasWebstoreBridge = false

    private static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", Internal.scheme, Extensions.scheme]

    /// A name the user gave the tab; it wins over the page's own title until cleared.
    var customTitle: String?
    /// The agent session ("s1") that opened the tab, which puts it in the sidebar's Agent group.
    /// Cleared when the user moves it to the tab list; never saved, so it comes back an ordinary tab.
    var openedByAgent: String?
    var isInAgentGroup: Bool { pinID == nil && openedByAgent != nil }
    var isInTabList: Bool { pinID == nil && openedByAgent == nil }
    /// Counts the documents shown, error pages included, so an agent waiting on a navigation can
    /// tell its page from the one before. A sleeping tab's old page, shown on its way to the
    /// address it was sent to (`go(to:)`), isn't counted.
    private(set) var commits = 0
    /// Counts the moves within the document shown to an anchor (`page#section`), or Back and
    /// Forward between `pushState` entries, which WebKit commits nothing for. The page's own
    /// script makes them too (`location.hash`, `history.back()`), not only a navigation asked for.
    /// The page's `pushState` and `replaceState` aren't counted.
    private(set) var sameDocumentNavigations = 0
    /// Counts the loads in the page itself that ended without showing anything, for an agent
    /// waiting on one; `lastUnshownLoad` tells how the latest ended.
    private(set) var unshownLoads = 0
    @ObservationIgnored private(set) var lastUnshownLoad: UnshownLoad?

    /// The three counts above: any of them moving ends the load under way.
    struct LoadMarks: Equatable {
        let commits, moves, unshown: Int
    }

    var loadMarks: LoadMarks { LoadMarks(commits: commits, moves: sameDocumentNavigations, unshown: unshownLoads) }
    /// From the moment a load starts until it commits a document or ends without one: the
    /// document shown until then is the one on its way out.
    private(set) var isAwaitingCommit = false
    /// The main document's HTTP status, for agents; nil until a response arrives, and for pages
    /// that have none (Lithium's error page, local files).
    @ObservationIgnored private(set) var httpStatus: Int?
    /// A shorter name for the page's title (Max, Tidy tab titles).
    private(set) var tidyTitle: String?
    /// Silenced by the user. WebKit keeps it per web view, so each new one (waking) is muted again.
    /// Muted, it gives up the mini player: it is no longer heard, and would otherwise keep it.
    var isMuted = false {
        didSet {
            if let loadedWebView { applyMute(to: loadedWebView) }
            if isMuted { browser?.nowPlaying.discard(self) }
        }
    }

    /// Per-page mute is private WebKit (`_setPageMuted:`, as Safari's tab speaker uses), absent from older ones.
    nonisolated static let canMute = WKWebView.instancesRespond(to: Selector(("_setPageMuted:")))
    private static let setPageMuted = Selector(("_setPageMuted:"))
    /// `_WKMediaAudioMuted`; the other bits (camera, microphone, screen) are left as they are.
    private static let audioMuted = 1

    var displayTitle: String {
        if let customTitle { return customTitle }
        if let tidyTitle, browser?.tidyTitles.isEnabled == true { return tidyTitle }
        if !title.isEmpty { return title }
        if let host = url?.host() { return host }
        if let url, url.isFileURL { return url.lastPathComponent }
        return "New Tab"
    }

    init(browser: Browser, configuration: WKWebViewConfiguration) {
        self.browser = browser
        self.configuration = configuration
        super.init()
    }

    private func attach(_ webView: WKWebView) {
        hasShownPage = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        observeWebView()
        if isMuted { applyMute(to: webView) }
    }

    private func applyMute(to webView: WKWebView) {
        guard Self.canMute else { return }
        let state = webView.responds(to: Selector(("_mediaMutedState"))) ? webView.value(forKey: "_mediaMutedState") as? Int ?? 0 : 0
        typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
        let setter = unsafeBitCast(webView.method(for: Self.setPageMuted), to: Setter.self)
        setter(webView, Self.setPageMuted, isMuted ? state | Self.audioMuted : state & ~Self.audioMuted)
    }

    func load(_ url: URL) {
        load(URLRequest(url: url))
    }

    func load(_ request: URLRequest) {
        guard let url = request.url else { return }
        // Dropped as when sleeping, the web view is made again, with the address's configuration.
        // A sleeping tab has none to drop, only the configuration it would wake with.
        if let browser, needsNewWebView(for: url) {
            let configuration = browser.makeConfiguration(for: url)
            if isAsleep { self.configuration = configuration } else { sleep(configuration: configuration) }
        }
        self.url = url
        isAsleep = false
        sleepingState = nil
        addressAfterWaking = nil
        // A page the user sends elsewhere is no longer what its popup was talking to.
        unpair()
        if Internal.isInternal(url) { trustedInternalURL = url }
        if url.isFileURL {
            // The whole folder, so a document's relative images and links to its neighbours load.
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(request)
        }
    }

    /// WebKit shows an extension's pages only in a web view made with its configuration, and
    /// nothing else in one: it drops the load without a word. Going between them takes a new
    /// web view, without the old page's history. A tab without a page shown (asleep) has the
    /// configuration made for its address.
    private func needsNewWebView(for url: URL) -> Bool {
        guard let shown = loadedWebView?.url ?? self.url, let current = Self.owner(of: shown), let next = Self.owner(of: url) else { return false }
        return current != next
    }

    /// The extension whose configuration a page loads in, "" for Lithium's; nil for addresses
    /// that load in whichever they are opened from (about:, blob:, data:).
    private static func owner(of url: URL) -> String? {
        switch url.scheme?.lowercased() {
        case Extensions.scheme: url.host()
        case "http", "https", "file", Internal.scheme: ""
        default: nil
        }
    }

    /// A tab from the last session starts asleep: it shows its name and icon, and loads when selected.
    func restore(url: URL, title: String) {
        self.url = url
        self.title = title
        faviconData = Favicons.shared.cachedData(host: url.host() ?? "")
        favicon = Internal.isInternal(url) ? NSImage(named: NSImage.applicationIconName) : faviconData.flatMap(NSImage.init(data:))
        isAsleep = true
    }

    /// Stops the page, and whatever it was to go on to once shown.
    func stopLoading() {
        addressAfterWaking = nil
        webView.stopLoading()
    }

    func reload() {
        if let item = webView.backForwardList.currentItem { pdfHistory[item] = nil }
        if let failedURL { load(failedURL) } else { webView.reload() }
    }

    /// What shows the page: the PDF viewer or the web view. Keyboard focus goes back to it.
    var contentView: NSView {
        pdf?.view ?? webView
    }

    var findTarget: FindTarget {
        pdf ?? webView
    }

    func print() {
        if let pdf {
            pdf.print()
            return
        }
        let operation = webView.printOperation(with: .shared)
        // WebKit's operation draws nothing until its view has a size.
        operation.view?.frame = webView.bounds
        if let window = webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    private func openPDF(from webView: WKWebView, reader: PDFReader) async {
        let data = await PDFReader.mainResourceData(of: webView)
        guard pdf === reader else { return }
        // Without the bytes, or with bytes PDFKit can't read, WebKit's viewer stays.
        guard let data, reader.open(data) else {
            pdf = nil
            return
        }
        adopt(reader)
    }

    /// The document's title and an icon for the tab, also when the reader comes back from the history.
    private func adopt(_ reader: PDFReader) {
        if favicon == nil { favicon = PDFReader.icon }
        if title.isEmpty {
            title = reader.title
            if let url { browser?.history.updateTitle(title, for: url) }
            browser?.tidyTitles.update(self)
            tellExtensions(.title)
        }
        // The page had the keyboard; the viewer takes it, so arrows and space scroll the document.
        if let window = reader.view.window,
           (window.firstResponder as? NSView)?.isDescendant(of: webView) == true {
            window.makeFirstResponder(reader.view)
        }
    }

    func markActive() {
        noteSound()
        lastActive = Date()
        wakeIfAsleep()
    }

    private func wakeIfAsleep() {
        guard isAsleep, let url else { return }
        load(url, history: sleepingState)
    }

    /// What `load(_:history:)` takes to bring this page back elsewhere (a reopened or duplicated
    /// tab) with its back and forward history; nil when it can't come back that way.
    var history: Any? {
        isAsleep ? sleepingState : loadedWebView.flatMap(restorableState(of:))
    }

    /// The history a sleeping tab wakes with, if every page in it can come back that way. Local
    /// files and Lithium's own pages can't: their read access and trust are granted by `load`.
    /// Nor can a page whose process died in the middle of a navigation: the history doesn't
    /// have the page the tab was going to yet.
    private func restorableState(of webView: WKWebView) -> Any? {
        let list = webView.backForwardList
        // A PDF shown when the tab sleeps loads afresh: Lithium's viewer needs the document's
        // bytes, which a page brought back from history may not come with.
        guard pdf == nil, let current = list.currentItem, current.url == url,
              (list.backList + [current] + list.forwardList).allSatisfy({ Self.wakesWithHistory($0.url) }) else { return nil }
        return webView.interactionState
    }

    /// A blob: address dies with the process that made it.
    private static func wakesWithHistory(_ url: URL) -> Bool {
        !url.isFileURL && !Internal.isInternal(url) && url.scheme != Extensions.scheme && url.scheme != "blob"
    }

    /// Shows the page with the history it had, or loads it afresh without one.
    func load(_ url: URL, history: Any?) {
        guard let history else { return load(url) }
        self.url = url
        sleepingState = nil
        isAsleep = false
        webView.interactionState = history
        // A state WebKit could not read leaves an empty page.
        if webView.backForwardList.currentItem == nil { load(url) }
    }

    /// A tab that has been left alone for a while and is not busy (loading, playing sound,
    /// using the camera or microphone) can release its page. It loads again when selected,
    /// with its history. It is decided in the app, without waiting on the page's process,
    /// which may be stuck, or slow to answer when memory is short: sound is as last noted,
    /// which every sleep pass does for every tab first.
    func canSleep(idleFor interval: TimeInterval) -> Bool {
        guard !isAsleep, url != nil else { return false }
        return !webView.isLoading
            && Date().timeIntervalSince(lastActive) > interval
            && Date().timeIntervalSince(lastHeard ?? .distantPast) > Self.silenceBeforeSleep
            && !isInCall
    }

    private static let silenceBeforeSleep: TimeInterval = 5 * 60

    /// Notes whether the page plays sound: what Safari's speaker icon shows (private
    /// `_isPlayingAudio`, known in the app). WebKit's public media state is no substitute: it
    /// calls a page holding a video or sound it never started "playing", which would keep
    /// most news pages awake. It is used only by a WebKit without the private property, as
    /// Lithium did before, and counts from the next pass, since the page's process answers it.
    func noteSound() {
        guard let webView = loadedWebView, !isAsleep else { return }
        if let isPlayingAudio {
            if isPlayingAudio { lastHeard = Date() }
            return
        }
        // One question at a time: a stuck process doesn't pile them up.
        guard !isAskingPlayback else { return }
        isAskingPlayback = true
        Task { [weak self] in
            let state = await webView.requestMediaPlaybackState()
            guard let self else { return }
            self.isAskingPlayback = false
            if state == .playing { self.lastHeard = Date() }
        }
    }

    /// Safari's speaker icon, asked of the app's side of WebKit; nil from a WebKit without it.
    var isPlayingAudio: Bool? {
        guard let webView = loadedWebView, webView.responds(to: Selector(("_isPlayingAudio"))) else { return nil }
        return webView.value(forKey: "_isPlayingAudio") as? Bool
    }

    /// The process that runs the page, for the hover card's memory and CPU. Private API; nil
    /// from a WebKit without it, and while the process isn't running (WebKit reports 0).
    var webProcessIdentifier: pid_t? {
        guard let webView = loadedWebView, webView.responds(to: Selector(("_webProcessIdentifier"))),
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }

    /// Using the camera or microphone, or sharing the screen or a window: a call, whose
    /// participants are heard through the page's media. Screen sharing is private API, absent
    /// from older WebKits.
    var isInCall: Bool {
        guard let webView = loadedWebView else { return false }
        if webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none { return true }
        guard webView.responds(to: Selector(("_displayCaptureState"))) else { return false }
        return (webView.value(forKey: "_displayCaptureState") as? Int ?? 0) != 0
    }

    /// Ends the link between a popup window and the page that opened it, both ways.
    func unpair() {
        opener = nil
        browser?.tabs.forEach { if $0.opener === self { $0.opener = nil } }
    }

    func sleep(configuration: WKWebViewConfiguration) {
        guard !isAsleep else { return }
        browser?.videoPopout.discard(self)
        browser?.nowPlaying.discard(self)
        browser?.agent?.pageGone(self)
        dialogOwner?.answerDialog(in: self)
        sleepingState = loadedWebView.flatMap(restorableState(of:))
        addressAfterWaking = nil
        // Its page and its popup's no longer know each other once it wakes in a new web view.
        unpair()
        // The next web view asks afresh, even if this one's question never gets an answer.
        isAskingPlayback = false
        tearDown()
        pdf = nil
        pdfHistory = [:]
        hasInternalBridge = false
        hasWebstoreBridge = false
        isAsleep = true
        appliedProtections = nil
        canGoBack = false
        canGoForward = false
        isLoading = false
        isAwaitingCommit = false
        self.configuration = configuration
        withMutation(keyPath: \.webView) { loadedWebView = nil }
    }

    func tearDown() {
        observations.removeAll()
        guard let loadedWebView else { return }
        loadedWebView.stopLoading()
        loadedWebView.navigationDelegate = nil
        loadedWebView.uiDelegate = nil
        loadedWebView.removeFromSuperview()
    }

    private func observeWebView() {
        observations = [
            webView.observe(\.title) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isAsleep else { return }
                    self.title = webView.title ?? ""
                    self.tidyTitle = nil
                    self.browser?.tidyTitles.update(self)
                    if let url = self.url { self.browser?.history.updateTitle(self.title, for: url) }
                    self.tellExtensions(.title)
                }
            },
            webView.observe(\.url) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isAsleep, let url = webView.url, url != self.url else { return }
                    if url.host() != self.url?.host() { self.favicon = nil; self.faviconData = nil }
                    self.url = url
                    // Same-document navigations (pushState) never reach didFinish.
                    if !webView.isLoading { self.browser?.history.record(url, title: self.title) }
                    self.tellExtensions(.URL)
                }
            },
            webView.observe(\.isLoading) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    // WebKit reports a load from the moment it is asked for, before it calls
                    // didStartProvisionalNavigation.
                    if self?.isLoading != webView.isLoading { self?.isAwaitingCommit = webView.isLoading }
                    self?.isLoading = webView.isLoading
                    self?.tellExtensions(.loading)
                }
            },
            webView.observe(\.estimatedProgress) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.progress = webView.estimatedProgress }
            },
            webView.observe(\.canGoBack) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
        ]
    }

    private func tellExtensions(_ properties: WKWebExtension.TabChangedProperties) {
        guard !isAsleep, let browser, browser.tabs.contains(self) else { return }
        browser.extensions.didChange(properties, of: self)
    }

    private func applyProtections(for url: URL) async {
        guard let privacy = browser?.privacy else { return }
        await privacy.waitUntilReady()
        await browser?.extensions.waitUntilLoaded()
        let enabled = privacy.isEnabled(for: url)
        let controller = webView.configuration.userContentController
        if appliedProtections?.enabled != enabled || appliedProtections?.generation != privacy.generation {
            privacy.applyRuleLists(enabled, to: controller)
            appliedProtections = (enabled, privacy.generation)
        }
        // User scripts depend on the page (advanced rules are per site), so they are swapped
        // on every main-frame navigation, before the new document starts.
        controller.removeAllUserScripts()
        PageStyle.scripts(for: url).forEach(controller.addUserScript)
        if MarkdownReader.handles(url) { controller.addUserScript(MarkdownReader.script) }
        if ChromeWebStore.isStore(url) { controller.addUserScript(ChromeWebStore.script) }
        controller.addUserScript(PageTranslation.script)
        browser?.nowPlaying.install(on: controller)
        privacy.addScripts(enabled, for: url, to: controller)
        browser?.agent?.install(on: controller)
    }

    /// Sends a tab an extension woke without its history on to the extension's address. Called
    /// when its old page is shown, and also when that load ends without showing anything (it
    /// failed, was refused, or became a download): the address is loaded all the same, without
    /// the old page to go back to. Otherwise it would wait for, and replace, whichever page
    /// shows next.
    @discardableResult
    private func goToAddressAfterWaking() -> Bool {
        guard let next = addressAfterWaking else { return false }
        addressAfterWaking = nil
        Task { self.load(next) }
        return true
    }

    private func downloadStarted(_ download: WKDownload, inMainFrame: Bool, fileName: String?) {
        Downloads.shared.track(download)
        // A tab going on to an extension's address isn't empty, though nothing is shown yet.
        guard !goToAddressAfterWaking() else { return }
        if inMainFrame { endedUnshown(.download(fileName: fileName)) }
        // A tab opened just to fetch a file has no page to show once the download starts; like Safari, close it.
        if webView.backForwardList.currentItem == nil { browser?.close(self) }
    }

    private func endedUnshown(_ load: UnshownLoad) {
        lastUnshownLoad = load
        unshownLoads += 1
    }

    /// Applied only if the page still has the title the tidy name was made from.
    func setTidyTitle(_ tidy: String, from source: String) {
        guard title == source else { return }
        tidyTitle = tidy == title ? nil : tidy
    }

    private func setInternalBridge(_ installed: Bool) {
        guard installed != hasInternalBridge, let browser else { return }
        let controller = webView.configuration.userContentController
        if installed {
            controller.addScriptMessageHandler(browser.internalBridge, contentWorld: .page, name: InternalBridge.name)
        } else {
            controller.removeScriptMessageHandler(forName: InternalBridge.name, contentWorld: .page)
        }
        hasInternalBridge = installed
    }

    /// The Chrome Web Store's install button talks to Lithium only while the tab shows the store.
    private func setWebstoreBridge(_ installed: Bool) {
        guard installed != hasWebstoreBridge, let browser else { return }
        let controller = webView.configuration.userContentController
        if installed {
            controller.addScriptMessageHandler(browser.extensions.webstoreBridge, contentWorld: .page, name: WebstoreBridge.name)
        } else {
            controller.removeScriptMessageHandler(forName: WebstoreBridge.name, contentWorld: .page)
        }
        hasWebstoreBridge = installed
    }

    /// Runs after every page load; an unchanged icon is left alone, so the sidebar doesn't redraw it.
    private func refreshFavicon() async {
        if Internal.isInternal(url) {
            if favicon !== NSApp.applicationIconImage { favicon = NSApp.applicationIconImage }
            return
        }
        // The fetch can outlast the page: an icon found after the tab moved to another site isn't its.
        let host = url?.host()
        guard let data = await Favicons.shared.favicon(for: webView), url?.host() == host, data != faviconData else { return }
        faviconData = data
        favicon = NSImage(data: data)
        browser?.didLoadFavicon(data, in: self)
    }

    private func showError(_ error: Error, for url: URL?) {
        let error = error as NSError
        let ignored = error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && error.code == 102)
        guard !ignored else { return }
        failedURL = url
        loadError = error
        let message = error.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let html = """
            <!doctype html><meta charset="utf-8"><title>Can’t open this page</title>
            <style>
              body { font: 15px "DM Sans", -apple-system, sans-serif; color: #444; display: grid; place-items: center; height: 90vh; margin: 0; }
              h1 { font-size: 22px; font-weight: 600; color: #111; margin: 0 0 8px; }
              @media (prefers-color-scheme: dark) { body { background: #1c1c1e; color: #aaa; } h1 { color: #eee; } }
            </style>
            <div><h1>Can’t open this page</h1><p>\(message)</p></div>
            """
        errorNavigation = webView.loadHTMLString(html, baseURL: url)
    }
}

extension Tab: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = action.request.url else { return (.cancel, preferences) }
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        // Only the first decision after an extension sent a sleeping tab on can be its old page's
        // load, started first; whatever it is, the next ones (the new address's redirects, a
        // Reload after a download) go through.
        if isMainFrame, let superseded = supersededURL {
            supersededURL = nil
            if url == superseded { return (.cancel, preferences) }
        }
        if action.shouldPerformDownload {
            // A download the agent started waits for the user's Allow.
            let name = url.lastPathComponent
            let allowed = await browser?.agent?.confirmDownload(in: self, fileName: ["", "/"].contains(name) ? nil : name, size: nil, from: url)
            return (allowed == false ? .cancel : .download, preferences)
        }

        guard Self.webSchemes.contains(url.scheme?.lowercased() ?? "") else {
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            // A load refused here ends without a word from WebKit.
            if isMainFrame, !goToAddressAfterWaking() { endedUnshown(.refused(scheme: url.scheme ?? "")) }
            return (.cancel, preferences)
        }

        // Going back to a form's result WebKit no longer has, reloading it or waking on it sends
        // the form again: an order, a payment. Like Safari, Lithium asks first, for the page in
        // front only; a frame's form too (an embedded payment check or sign-in), which refused
        // stays blank. Refused, a web view with nothing shown yet (a tab waking on that page)
        // loads the address instead, without the form.
        if action.navigationType == .formResubmitted {
            guard await confirmResubmission(of: url, inFrame: !isMainFrame) else {
                // Unless the tab was sent elsewhere meanwhile (an extension's address, say).
                if isMainFrame, !hasShownPage { Task { if self.url == url { self.load(url) } } }
                return (.cancel, preferences)
            }
        }

        let source = (action.sourceFrame as WKFrameInfo?)?.securityOrigin.protocol
        if Internal.isInternal(url) {
            // Websites may not open Lithium's pages; only the app or another Lithium page can.
            guard isMainFrame, url == trustedInternalURL || source == Internal.scheme else {
                if isMainFrame { endedUnshown(.refused(scheme: Internal.scheme)) }
                return (.cancel, preferences)
            }
            trustedInternalURL = nil
            webView.configuration.userContentController.removeAllUserScripts()
            setWebstoreBridge(false)
            setInternalBridge(true)
            return (.allow, preferences)
        }
        // An extension's own pages run in its configuration, which Lithium leaves alone.
        guard url.scheme != Extensions.scheme, isMainFrame else { return (.allow, preferences) }

        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) {
            browser?.newTab(url: url, selecting: action.modifierFlags.contains(.shift))
            return (.cancel, preferences)
        }
        // An extension's page sending its tab to a website (1Password's Sign In button) goes on
        // in a new web view. Only that way round: a website may not open an extension's pages.
        if ["http", "https"].contains(url.scheme?.lowercased()), needsNewWebView(for: url) {
            Task { self.load(action.request) }
            return (.cancel, preferences)
        }
        setInternalBridge(false)
        setWebstoreBridge(ChromeWebStore.isStore(url))

        if action.request.httpMethod == "GET", let clean = TrackingParameters.stripped(url) {
            Task { webView.load(URLRequest(url: clean)) }
            return (.cancel, preferences)
        }

        await applyProtections(for: url)
        Privacy.setEngineProtections(browser?.privacy.isEnabled(for: url) ?? true, on: preferences)
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.isForMainFrame { httpStatus = (response.response as? HTTPURLResponse)?.statusCode }
        let isAttachment = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        guard !response.canShowMIMEType || isAttachment else { return .allow }
        // A download the agent started waits for the user's Allow, in place of what follows.
        if let allowed = await browser?.agent?.confirmDownload(in: self, fileName: response.response.suggestedFilename, size: response.response.expectedContentLength, from: response.response.url) {
            return allowed ? .download : .cancel
        }
        if response.isForMainFrame { return .download }
        // A frame in the page (an ad, or a site's Download button pointing a hidden frame at the
        // file) asks first, as in Safari: the site the user is on is allowed, or not, once.
        guard let browser, let host = shownHost, !host.isEmpty else { return .cancel }
        return await browser.permissions.request([.downloads], host: host, tabID: id) ? .download : .cancel
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        let name = navigationAction.request.url?.lastPathComponent
        downloadStarted(download, inMainFrame: navigationAction.targetFrame?.isMainFrame ?? true, fileName: ["", "/"].contains(name) ? nil : name)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloadStarted(download, inMainFrame: navigationResponse.isForMainFrame, fileName: navigationResponse.response.suggestedFilename)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        Task { await applyProtections(for: url) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if navigation !== errorNavigation { failedURL = nil }
        httpStatus = nil
        isAwaitingCommit = true
    }

    /// Private WebKit (`WKNavigationDelegatePrivate`), which calls it only on a delegate that has it.
    /// `type` is `_WKSameDocumentNavigationType`: 0 an anchor, 1 pushState, 2 replaceState, 3 Back or Forward.
    @objc(_webView:navigation:didSameDocumentNavigation:)
    func webView(_ webView: WKWebView, navigation: WKNavigation?, didSameDocumentNavigation type: Int) {
        if type == 0 || type == 3 { sameDocumentNavigations += 1 }
    }

    /// Private WebKit (`WKNavigationDelegatePrivate`): the page menu's Download Image, Download
    /// Linked File and Download Video. Without it WebKit drops the download before it starts.
    /// Like Safari's Save Image As…, it asks where to save.
    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreateDownload download: WKDownload) {
        Downloads.shared.track(download, askingWhere: true)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasShownPage = true
        isAwaitingCommit = false
        if navigation !== errorNavigation { loadError = nil }
        // The old page is now in the history, one Back away. Only on its way out, it isn't the
        // document an agent's navigation waits for.
        if !goToAddressAfterWaking() { commits += 1 }
        // A prompt left from the page before would read as the new page's.
        browser?.permissions.cancel(tabID: id)
        // The page that played is gone; the new one reports its own media.
        browser?.nowPlaying.discard(self)
        shownHost = webView.url?.host()
        let list = webView.backForwardList
        let live = Set(list.backList + list.forwardList + [list.currentItem].compactMap { $0 })
        pdfHistory = pdfHistory.filter { live.contains($0.key) }
        let previous = pdf
        defer { if let previous, previous !== pdf { previous.putAway() } }
        guard PDFReader.isShowingPDF(webView), let url = webView.url else {
            pdf = nil
            if favicon === PDFReader.icon { favicon = nil }
            return
        }
        if let item = list.currentItem, let kept = pdfHistory[item], kept.url == url {
            pdf = kept
            return
        }
        let reader = PDFReader(url: url)
        // Like a website's links: never Lithium's own pages, local files only from a local PDF
        // (a file opens with read access to its folder), and other apps' schemes (mailto:) go to those apps.
        let isLocal = url.isFileURL
        reader.onOpenLink = { [weak self] url, inNewTab in
            guard let self else { return }
            let scheme = url.scheme?.lowercased()
            switch scheme {
            case "http", "https", "file":
                guard scheme != "file" || isLocal else { return }
                if inNewTab { self.browser?.newTab(url: url, selecting: false) } else { self.load(url) }
            case Internal.scheme, Extensions.scheme:
                break
            default:
                NSWorkspace.shared.open(url)
            }
        }
        pdf = reader
        if let item = list.currentItem { pdfHistory[item] = reader }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // After the visit is recorded below, so the PDF's title lands on this visit's row.
        defer {
            if let pdf {
                if pdf.document == nil { Task { await openPDF(from: webView, reader: pdf) } } else { adopt(pdf) }
            }
        }
        guard failedURL == nil else { return }
        if let url = webView.url { browser?.history.record(url, title: webView.title ?? "") }
        browser?.tidyTitles.update(self)
        Task { await refreshFavicon() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Whatever the error, cancellations included: the old page was only on its way out.
        guard !goToAddressAfterWaking() else { return }
        showError(error, for: (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error, for: url)
    }

    /// A tab out of sight comes back when it is selected rather than reloading now: its page may
    /// have been dropped to free memory. A page that takes its process down again right after
    /// reloading shows an error instead of reloading forever.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The media died with the process; a reload that never commits would leave it showing as playing.
        browser?.nowPlaying.discard(self)
        browser?.agent?.pageGone(self)
        dialogOwner?.answerDialog(in: self)
        guard let browser else { return }
        guard browser.selectedTabID == id else {
            sleep(configuration: browser.makeConfiguration(for: url))
            return
        }
        if let last = lastCrashReload, Date().timeIntervalSince(last) < 10 {
            lastCrashReload = nil
            showError(Self.crashedAgain, for: url)
        } else {
            lastCrashReload = Date()
            webView.reload()
            // The new process starts from the page's settings; said again in case mute isn't among them.
            if isMuted { applyMute(to: webView) }
        }
    }

    private static let crashedAgain = NSError(domain: "Lithium", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "The page stopped working twice in a row. Reload to try again.",
    ])
}

extension Tab: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let browser else { return nil }
        // WebKit hands an extension's page its own configuration for the new one, which a website
        // won't load in. It opens as a plain tab instead, without a way back to its opener.
        if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased()), needsNewWebView(for: url) {
            browser.newTab(url: url)
            return nil
        }
        browser.prepare(popup: configuration)
        let popup = browser.newTab(configuration: configuration)
        // A popup window gives a size or a position, as sign-in and payment windows do. A link
        // or script opening a plain tab (target=_blank, noopener) doesn't; neither does a
        // window.open with no features at all, which can't be told apart from one.
        let geometry = [windowFeatures.width, windowFeatures.height, windowFeatures.x, windowFeatures.y]
        if geometry.contains(where: { $0 != nil }) { popup.opener = self }
        return popup.webView
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        let kinds: [PermissionKind] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        @unknown default: [.camera, .microphone]
        }
        return await askPermission(kinds, origin: origin) ? .grant : .deny
    }

    @available(macOS 27.0, *)
    func webView(
        _ webView: WKWebView,
        requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo
    ) async -> WKPermissionDecision {
        await askPermission([.location], origin: origin) ? .grant : .deny
    }

    /// Before macOS 27 the geolocation prompt hook was private; this is the selector WebKit looks for.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func legacyGeolocationPermission(
        _ webView: WKWebView,
        origin: WKSecurityOrigin,
        frame: WKFrameInfo,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        Task { decisionHandler(await askPermission([.location], origin: origin) ? .grant : .deny) }
    }

    private func askPermission(_ kinds: [PermissionKind], origin: WKSecurityOrigin) async -> Bool {
        guard let browser, !origin.host.isEmpty else { return false }
        return await browser.permissions.request(kinds, host: origin.host, tabID: id)
    }

    func webViewDidClose(_ webView: WKWebView) {
        browser?.close(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await answer(AgentDialog(.alert, message: message, host: frame.securityOrigin.host)) {
            _ = await self.present(self.alert(message, from: frame, buttons: ["OK"]))
            return DialogReply(accepted: true, text: nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await answer(AgentDialog(.confirm, message: message, host: frame.securityOrigin.host)) {
            DialogReply(accepted: await self.present(self.alert(message, from: frame, buttons: ["OK", "Cancel"])) == .alertFirstButtonReturn, text: nil)
        }.accepted
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let reply = await answer(AgentDialog(.prompt, message: prompt, defaultText: defaultText, host: frame.securityOrigin.host)) {
            let alert = self.alert(prompt, from: frame, buttons: ["OK", "Cancel"])
            let field = NSTextField(string: defaultText ?? "")
            field.frame.size.width = 260
            alert.accessoryView = field
            return DialogReply(accepted: await self.present(alert) == .alertFirstButtonReturn, text: field.stringValue)
        }
        return reply.accepted ? reply.text ?? "" : nil
    }

    /// Its web view came into a window: the agent's dialog waiting in the page is the user's now.
    func didComeIntoView() {
        dialogOwner?.handDialogToUser(in: self)
    }

    /// A dialog in a tab out of sight that a connected session holds goes to the agent, never to
    /// a modal that would hold up the user, until it is handed to the user; any other is the
    /// user's, and agents see it while it shows.
    private func answer(_ dialog: AgentDialog, asUser: () async -> DialogReply) async -> DialogReply {
        guard let agent = browser?.agent else { return await asUser() }
        if let reply = await agent.agentReply(to: dialog, in: self) { return reply }
        return await agent.whileUserAnswers(dialog, in: self, asUser)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        // An agent never gets the user's panel: only files the user allowed for it.
        switch browser?.agent?.openPanel(for: self) {
        case .files(let files): return files
        case .cancelled: return nil
        case nil: break
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        guard let window = webView.window else { return panel.runModal() == .OK ? panel.urls : nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    private func alert(_ message: String, from frame: WKFrameInfo, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : frame.securityOrigin.host
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert
    }

    /// A tab out of sight never sends a form again by itself.
    private func confirmResubmission(of url: URL, inFrame: Bool) async -> Bool {
        guard browser?.selectedTabID == id, let window = webView.window else { return false }
        let alert = NSAlert()
        let site = url.host() ?? "this site"
        alert.messageText = "Send the form again?"
        alert.informativeText = inFrame
            ? "Part of this page sends a form to \(site) again. This can repeat an order or a payment."
            : "This page sends a form to \(site) again. This can repeat an order or a payment."
        alert.addButton(withTitle: "Send Again")
        alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = webView.window else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }
}

/// Tabs as extensions see them (`chrome.tabs`).
extension Tab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        browser?.extensions.window
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        browser?.navigationOrder.firstIndex(of: self) ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        isAsleep ? nil : webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        displayTitle
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        url
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        pinID != nil
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        browser?.selectedTabID == id
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !isLoading
    }

    func activate(for context: WKWebExtensionContext) async throws {
        browser?.select(self)
    }

    func close(for context: WKWebExtensionContext) async throws {
        browser?.close(self)
    }

    /// A sleeping tab keeps its old page one Back away. With its history saved, it gets it back
    /// and goes straight on to the address: the old page's load is superseded rather than waited
    /// for. Without (a tab restored asleep from the last session), it wakes onto its old page first,
    /// and goes on once that is shown or has failed to be.
    /// Sent to the page it slept on, it just wakes, which loads that page. Sent between an
    /// extension's pages and websites, it wakes in a new web view without its history.
    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        go(to: url)
    }

    /// Sends the tab to an address on someone else's behalf (an extension, an agent), keeping a
    /// sleeping tab's history as `loadURL(_:for:)` describes.
    func go(to url: URL) {
        lastActive = Date()
        guard isAsleep, let old = self.url, !needsNewWebView(for: url) else {
            load(url)
            return
        }
        guard old != url else {
            wakeIfAsleep()
            return
        }
        if let state = sleepingState {
            sleepingState = nil
            // Putting the history back starts loading the old page. That load is only on its way
            // out, so it mustn't ask to resend a form or be reloaded without its tracking parameters.
            supersededURL = old
            webView.interactionState = state
            load(url)
        } else {
            wakeIfAsleep()
            // After waking, which clears anything pending.
            addressAfterWaking = url
        }
    }

    /// A sleeping tab wakes first, with its history; waking loads its page, which is the reload.
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        if isAsleep { wake() } else { reload() }
    }

    func goBack(for context: WKWebExtensionContext) async throws {
        wake()
        webView.goBack()
    }

    func goForward(for context: WKWebExtensionContext) async throws {
        wake()
        webView.goForward()
    }

    /// What an extension or an agent does in a tab counts as using it, so the next sleep pass leaves it be.
    func wake() {
        lastActive = Date()
        wakeIfAsleep()
    }
}
