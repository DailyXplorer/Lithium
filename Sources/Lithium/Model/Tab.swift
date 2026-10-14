import AppKit
import Observation
import WebKit

/// How a load in the page ended without showing anything.
enum UnshownLoad {
    case download(fileName: String?)
    /// Lithium refused where it led: another app's scheme (`mailto:`), or its own pages.
    case refused(scheme: String)
    /// A 204 No Content answer, a load the page stopped, a response WebKit dropped (error 102).
    case dropped
}

/// Refuses every load of a put-away web view. Without a delegate, WebKit hands a late redirect to
/// `mailto:` to another app itself, so a closed tab could open the user's mail app.
@MainActor
final class PutAwayWebView: NSObject, WKNavigationDelegate {
    static let refusing = PutAwayWebView()

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.cancel)
    }
}

@MainActor
@Observable
final class Tab: NSObject, Identifiable {
    let id = UUID()
    var pinID: Pin.ID? {
        didSet { if (oldValue == nil) != (pinID == nil) { pinnedChanged() } }
    }
    private(set) var unread = UnreadBadge()
    /// The icon the page declares: it wins over the icon cached for its site, which may be a day old.
    @ObservationIgnored private(set) var liveIcon: URL?
    /// One icon fetch at a time, each replacing the last, so a page can't pile fetches up.
    @ObservationIgnored private var faviconLoad: Task<Void, Never>?
    @ObservationIgnored private var iconFollow: Task<Void, Never>?
    /// An icon swapped faster than this (an animation) is fetched, shown and saved at most this often.
    static let iconInterval = Duration.seconds(2)
    /// Made on first use and dropped while the tab sleeps, which frees the page's memory.
    var webView: WKWebView {
        access(keyPath: \.webView)
        if let loadedWebView { return loadedWebView }
        let configuration = self.configuration ?? browser?.makeConfiguration(for: url) ?? WKWebViewConfiguration()
        self.configuration = configuration
        // A private tab's web views keep its own store, and no extension runs in them.
        if let privateStore {
            configuration.websiteDataStore = privateStore
            configuration.webExtensionController = nil
        } else if let spaceStore, url?.scheme != Extensions.scheme {
            // Popups too (`Privacy.harden` hands them the default store). Extension pages keep theirs.
            configuration.websiteDataStore = spaceStore
        }
        let webView = PageWebView(frame: .zero, configuration: configuration)
        webView.translation = browser?.translation
        webView.tab = self
        DeveloperTools.apply(browser?.developerTools ?? false, to: webView)
        if browser?.energy.isOn == true { BackgroundThrottling.apply(true, to: webView) }
        loadedWebView = webView
        attach(webView)
        return webView
    }
    @ObservationIgnored private(set) var loadedWebView: WKWebView?
    /// Nil for a tab restored asleep at launch: made when it first needs a web view.
    @ObservationIgnored private var configuration: WKWebViewConfiguration?
    /// For tests.
    var hasConfiguration: Bool { configuration != nil }
    private(set) var isAsleep = false
    @ObservationIgnored private(set) var lastActive = Date()
    @ObservationIgnored private var sleepingState: Any?
    /// Set by Clear History: WebKit can't empty a web view's back list, so it isn't saved or kept
    /// until the tab gets a new web view.
    @ObservationIgnored private var historyForgotten = false
    /// The tab whose page opened this one as a popup window, as sign-in windows are.
    @ObservationIgnored weak var opener: Tab?
    /// The tab whose page made this one's web view (`window.open`, target=_blank): WebKit links the
    /// two pages through `window.opener` and the returned handle until either web view goes.
    @ObservationIgnored weak var scriptOpener: Tab?
    /// Kept once `scriptOpener` goes: a page that opened this one may close it (a finished sign-in
    /// or payment window), and that isn't a tab the user would reopen.
    @ObservationIgnored private var openedByScript = false
    /// The hub whose dialog the page waits on: it still answers it once agent access is off.
    @ObservationIgnored var dialogOwner: AgentHub?
    /// The page's dialog waiting for the tab to be shown: true when it is, false for the default answer.
    @ObservationIgnored private var hiddenDialog: CheckedContinuation<Bool, Never>?
    /// For tests.
    var hasHiddenDialog: Bool { hiddenDialog != nil }
    /// So a pause between tracks or while buffering isn't taken for silence.
    @ObservationIgnored private var lastHeard: Date?
    @ObservationIgnored private var isAskingPlayback = false
    /// One woken on a form's result has nothing to fall back on if the form isn't sent again.
    @ObservationIgnored private var hasShownPage = false
    /// One that wakes without its history isn't a tab opened just to fetch a file.
    @ObservationIgnored private var hasHadPage = false
    @ObservationIgnored private var resubmissionSheet: NSWindow?
    @ObservationIgnored private var dialogSheet: NSWindow?
    /// A woken tab's old page: its load, started by restoring the history, is cancelled.
    @ObservationIgnored private var supersededURL: URL?
    /// The app sent the tab to an address (`load`), for the next main-frame decision.
    @ObservationIgnored private var appStartedLoad = false
    /// The user or app started the current load, so a file downloads at once. One the page started
    /// on its own asks first, as Safari does, so no page fills Downloads without a click.
    @ObservationIgnored private var loadWasRequested = false
    /// Where an extension sent a tab that slept without its history, loaded once its old page is
    /// shown or clearly won't be.
    @ObservationIgnored private var addressAfterWaking: URL?
    /// The site of the page shown, which its frames belong to. `webView.url` moves to the next
    /// address as soon as it starts loading, while the frames still are the old page's.
    @ObservationIgnored private var shownHost: String?
    /// `load` names the address before WebKit starts on it: the page shown stays until the next commits.
    @ObservationIgnored private var isStartingLoad = false

    private(set) var title = ""
    private(set) var url: URL? {
        didSet {
            if PageSummaries.page(of: oldValue) != PageSummaries.page(of: url) {
                browser?.summaries.discard(self)
                // Its popover too, which a hidden Zen bar's button can't close.
                if let browser, browser.selectedTabID == id, browser.summaries.isPanelPresented { browser.summaries.isPanelPresented = false }
                // The article was the old address's, even when the page moved on by itself (pushState).
                // A load's address comes before its page: the reader stays until that page commits
                // (`resetReader`), or the page left behind would show, and play, meanwhile.
                if isReading, !isStartingLoad, loadedWebView?.isLoading != true { leaveReader() }
                readerPageMovedOn()
            }
        }
    }
    private(set) var favicon: NSImage? {
        get {
            access(keyPath: \.favicon)
            readRestoredIcon()
            return shownFavicon
        }
        set {
            readRestoredIcon()
            withMutation(keyPath: \.favicon) { shownFavicon = newValue }
        }
    }
    private(set) var faviconData: Data? {
        get {
            access(keyPath: \.faviconData)
            readRestoredIcon()
            return shownFaviconData
        }
        set {
            readRestoredIcon()
            withMutation(keyPath: \.faviconData) { shownFaviconData = newValue }
        }
    }
    @ObservationIgnored private var shownFavicon: NSImage?
    @ObservationIgnored private var shownFaviconData: Data?
    /// The address whose cached icon a tab restored at launch shows, read when first asked for:
    /// the sidebar draws only the rows in view, and each read is a file and an image.
    @ObservationIgnored private var restoredIconURL: URL?
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var zoom = 1.0
    /// When the page last reported typing or interaction since loaded (`UnsavedInput`): idle sleep
    /// would lose that work. It lapses, or one keystroke in a search field would keep the tab awake for good.
    @ObservationIgnored private(set) var unsavedInputAt: Date?
    /// Frames that said an upload of the user's files started and not yet that it ended: it runs
    /// with no input and no load, for as long as it takes, and sleep or a reload would lose it.
    @ObservationIgnored private var uploadingFrames = 0
    var isUploading: Bool { uploadingFrames > 0 }
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var pdf: PDFReader?
    /// WebKit brings a PDF page back from its cache without its bytes.
    @ObservationIgnored private var pdfHistory: [WKBackForwardListItem: PDFReader] = [:]
    /// Its items, the PDF shown last at the end. Each reader holds its whole file and document,
    /// so only the last few are kept: WebKit's cache keeps only the last few pages left, and a
    /// PDF further back loads again, bytes and all, and gets a new reader.
    @ObservationIgnored private var pdfRecency: [WKBackForwardListItem] = []
    private static let keptPDFs = 4
    /// For tests.
    var keptPDFCount: Int { pdfHistory.count }
    private(set) var isReaderAvailable = false
    /// The page's media waits while reading, its frames' too (a YouTube embed no page script can
    /// reach). WebKit keeps it waiting across documents until told, so it is told however the reader goes.
    private(set) var isReading = false {
        didSet {
            guard isReading != oldValue, let webView = loadedWebView else { return }
            let suspended = isReading
            Task { await webView.setAllMediaPlaybackSuspended(suspended) }
        }
    }
    @ObservationIgnored private var readerChecked = false
    /// A page back from the cache may still show the reader, so pages are asked even with the button off.
    @ObservationIgnored private var hasRead = false
    @ObservationIgnored private var readerRecheck: Task<Void, Never>?
    /// Set by `PageTranslator` once the page's language is known; nil while there is nothing to offer.
    var pageTranslation: TabTranslation?
    @ObservationIgnored var languageChecked = false
    /// The language the user translated from in this tab: its next pages in it are translated too.
    @ObservationIgnored var translatesLanguage: String?
    /// Moves with each page and Show Original, so a translation started before lands nowhere.
    @ObservationIgnored var translationRun = 0

    @ObservationIgnored private weak var browser: Browser?
    @ObservationIgnored private(set) var observations: [NSObject] = []
    @ObservationIgnored private var appliedProtections: (enabled: Bool, generation: Int, leftOff: Set<String>)?
    /// The address the page's scripts were last set up for, and at the shown page's commit (`restoreProtections`).
    @ObservationIgnored private var protectedURL: URL?
    @ObservationIgnored private var shownProtectedURL: URL?
    @ObservationIgnored private var protectionRequests = 0
    @ObservationIgnored private var protectedFrameHosts: Set<String> = []
    @ObservationIgnored private var failedURL: URL?
    var isShowingError: Bool { failedURL != nil }
    /// Shown over the error page when a filter list blocked the page itself.
    private(set) var blockedPage: BlockedPage?
    @ObservationIgnored private(set) var blockLookup: Task<BlockedPage.Reason, Never>?
    /// Open anyway: its load goes without the groups that blocked the page (`putBackLeftOffGroups`). Set
    /// by `load` from `passToLoad`, so any other load the tab is sent on gets every list again.
    @ObservationIgnored private var letThrough: (url: URL, host: String, groups: Set<String>)?
    @ObservationIgnored private var passToLoad: (url: URL, host: String, groups: Set<String>)?
    @ObservationIgnored private var errorNavigation: WKNavigation?
    /// Cleared when another page commits.
    private(set) var loadError: NSError?
    var connection: SiteInfo.Connection { SiteInfo.Connection(url: url, loadError: loadError) }
    @ObservationIgnored private var lastCrashReload: Date?
    /// A redirect putting the tracking parameters back is let through, not stripped and reloaded forever.
    @ObservationIgnored private var strippedURL: URL?
    /// The stripped address a page's own redirect was sent on to by the tab's script, which
    /// WebKit counts as a press: it is still the page's load, not the user's.
    @ObservationIgnored private var strippedRedirect: URL?
    @ObservationIgnored private var trustedInternalURL: URL?
    @ObservationIgnored private var hasInternalBridge = false
    @ObservationIgnored private var hasWebstoreBridge = false

    private static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", Internal.scheme, Extensions.scheme]

    var customTitle: String?
    /// The agent session ("s1") that opened the tab; never saved, so it comes back an ordinary tab.
    var openedByAgent: String?
    var isInAgentGroup: Bool { pinID == nil && openedByAgent != nil }
    var isInTabList: Bool { pinID == nil && openedByAgent == nil }
    var folderID: TabFolder.ID?
    /// So an agent can tell its page from the one before. A woken tab's old page isn't counted.
    private(set) var commits = 0
    /// Moves to an anchor, or Back and Forward between `pushState` entries, which WebKit commits
    /// nothing for. The page's own `pushState` and `replaceState` aren't counted.
    private(set) var sameDocumentNavigations = 0
    /// Loads in the page that ended without showing anything; `lastUnshownLoad` tells how.
    private(set) var unshownLoads = 0
    @ObservationIgnored private(set) var lastUnshownLoad: UnshownLoad?

    /// The three counts above: any of them moving ends the load under way.
    struct LoadMarks: Equatable {
        let commits, moves, unshown: Int
    }

    var loadMarks: LoadMarks { LoadMarks(commits: commits, moves: sameDocumentNavigations, unshown: unshownLoads) }
    /// From a load's start until it commits or ends: the document shown is the one on its way out.
    private(set) var isAwaitingCommit = false
    /// So an agent's input tells its load from one under way. The error page isn't a load of its own.
    private(set) var loadStarts = 0
    /// From `showError` until its page starts loading, which WebKit may report first through
    /// `isLoading`, before `errorNavigation` is known.
    @ObservationIgnored private var isStartingErrorPage = false
    @ObservationIgnored private var startedNavigation: WKNavigation?
    /// `unshownLoads` when the load under way started: one that already ended as a download
    /// isn't dropped too when WebKit then gives it up.
    @ObservationIgnored private var unshownAtStart = 0
    /// The main document's HTTP status, for agents; nil for pages without one (error page, files).
    @ObservationIgnored private(set) var httpStatus: Int?
    private(set) var tidyTitle: String?
    /// The page whose title it last sent the on-device model (`TidyTitles`): once per page.
    @ObservationIgnored var titleAskedFor: URL?
    /// WebKit keeps it per web view, so each new one (waking) is muted again.
    var isMuted = false {
        didSet {
            if let loadedWebView { applyMute(to: loadedWebView) }
            if isMuted { browser?.nowPlaying.discard(self, pageGone: false) }
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

    /// A private tab's in-memory data store, shared only with the tabs it opens. Such a tab is never
    /// saved in the session, the history, the closed tabs or the favicon cache.
    @ObservationIgnored let privateStore: WKWebsiteDataStore?
    var isEphemeral: Bool { privateStore != nil }
    /// Where a private tab's permission answers are kept, for its private session only.
    var privateSession: ObjectIdentifier? { privateStore.map(ObjectIdentifier.init) }
    private var historyStore: HistoryStore? { isEphemeral ? nil : browser?.history }
    @ObservationIgnored private var recordedURL: URL?
    /// The page a wake or a crash reload brings back: seen before, so finishing it is no new visit.
    @ObservationIgnored private var reloadedURL: URL?

    private func recordVisit(_ url: URL, title: String) {
        recordedURL = url
        historyStore?.record(url, title: title)
    }

    /// The space whose sidebar shows the tab (`Space`). Fixed: its pages' cookies live there.
    let spaceID: Space.ID
    /// Asked for as a web view is made, so tabs restored asleep make no store.
    private var spaceStore: WKWebsiteDataStore? {
        privateStore == nil ? browser?.spaceStore(for: spaceID) : nil
    }

    /// `Keychain.isAllowed`, given to tests as either answer.
    nonisolated let keychainAllowed: Bool

    init(browser: Browser, configuration: WKWebViewConfiguration?, privateStore: WKWebsiteDataStore? = nil, space: Space.ID = Space.mainID,
         keychainAllowed: Bool = Keychain.isAllowed) {
        self.browser = browser
        self.keychainAllowed = keychainAllowed
        self.configuration = configuration
        self.privateStore = privateStore
        spaceID = space
        super.init()
    }

    /// A space keeping its data apart has its own permissions: its sign-ins are another identity's.
    var siteSpace: Space.ID? {
        privateStore == nil && browser?.separatesData(spaceID) == true ? spaceID : nil
    }

    /// Without a configuration yet, the store `Privacy.harden` gives every one.
    var dataStore: WKWebsiteDataStore { privateStore ?? spaceStore ?? configuration?.websiteDataStore ?? .default() }

    private func attach(_ webView: WKWebView) {
        hasShownPage = false
        shownProtectedURL = nil
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        // Before the observer, which reads it back into `zoom`.
        if zoom != 1 { webView.pageZoom = zoom }
        observeWebView()
        if isMuted { applyMute(to: webView) }
        browser?.agent?.didAttach(webView, to: self)
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
        if let browser, needsNewWebView(for: url) {
            let configuration = browser.makeConfiguration(for: url)
            if isAsleep { self.configuration = configuration } else { sleep(configuration: configuration) }
        }
        isStartingLoad = true
        self.url = url
        isStartingLoad = false
        isAsleep = false
        sleepingState = nil
        addressAfterWaking = nil
        reloadedURL = nil
        // Open anyway's pass is for its own load: one sent while it is on its way (an address typed
        // into the same site) mustn't get it, whenever WebKit reports the first one dropped.
        letThrough = passToLoad
        passToLoad = nil
        // A page the user sends elsewhere is no longer what its popup was talking to.
        unpair()
        // An address the user or the app sends the tab to loads without tracking parameters again.
        strippedURL = nil
        appStartedLoad = true
        if Internal.isInternal(url) { trustedInternalURL = url }
        if url.isFileURL {
            // The whole folder, so a document's relative images and links to its neighbours load.
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(request)
        }
    }

    /// WebKit shows an extension's pages only in a web view made with its configuration, and
    /// nothing else in one (it drops the load silently), so going between them takes a new web view.
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

    func restore(url: URL, title: String, history: Data? = nil) {
        self.url = url
        self.title = title
        restoredIconURL = url
        isAsleep = true
        sleepingState = history
        hasHadPage = true
    }

    /// The restored address's icon, read before anything else reads or sets the tab's.
    private func readRestoredIcon() {
        guard let url = restoredIconURL else { return }
        restoredIconURL = nil
        let data = (browser?.favicons ?? .shared).cachedData(host: url.host() ?? "")
        shownFaviconData = data
        shownFavicon = Internal.isInternal(url) ? NSImage(named: NSImage.applicationIconName) : data.flatMap(NSImage.init(data:))
    }

    func stopLoading() {
        addressAfterWaking = nil
        webView.stopLoading()
    }

    func reload() {
        // Reading `webView` would only make an empty one; waking loads the page, which is the reload.
        if isAsleep { return wake() }
        if let item = webView.backForwardList.currentItem { pdfHistory[item] = nil }
        if let failedURL { load(failedURL) } else { reloadPage() }
    }

    /// A first load that never committed leaves WebKit nothing to reload: load the address again.
    private func reloadPage() {
        // A reload is another navigation: Open anyway's pass ("this time only") ends, even mid-load.
        // So does a crash's: a blocked page that crashed its process isn't opened again unasked.
        letThrough = nil
        if webView.backForwardList.currentItem == nil, let url { load(url) } else { appStartedLoad = webView.reload() != nil }
    }

    /// Asked of the app, unlike the page's `history.back()`: a file it leads to downloads without asking.
    func goBack() {
        letThrough = nil
        appStartedLoad = webView.goBack() != nil
    }

    func goForward() {
        letThrough = nil
        appStartedLoad = webView.goForward() != nil
    }

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

    var canRead: Bool { !isAsleep && pdf == nil && !isShowingError && ReaderMode.handles(url) }

    var canTranslate: Bool {
        !isAsleep && pdf == nil && !isShowingError && ["http", "https", "file"].contains(url?.scheme?.lowercased() ?? "")
    }

    /// A new document, or none: what was translated went with the old one.
    private func resetTranslation() {
        translationRun += 1
        languageChecked = false
        if pageTranslation != nil { pageTranslation = nil }
    }

    @discardableResult
    func toggleReader() async -> Bool {
        guard canRead, let webView = loadedWebView else { return false }
        if isReading {
            leaveReader()
            return true
        }
        let marks = commits
        hasRead = true
        let shown = await ReaderMode.enter(webView, style: .saved)
        guard webView === loadedWebView, commits == marks else { return false }
        isReading = shown
        if shown { isReaderAvailable = ReaderMode.showsButton }
        return shown
    }

    private func leaveReader() {
        isReading = false
        guard let webView = loadedWebView else { return }
        Task { await ReaderMode.exit(webView) }
    }

    /// Asked once per page, once on screen, and not with the button off unless the reader was used.
    func checkReader() {
        guard !readerChecked, canRead, ReaderMode.showsButton || hasRead, let webView = loadedWebView else { return }
        readerChecked = true
        let marks = commits
        Task {
            let state = await ReaderMode.check(webView)
            guard webView === loadedWebView, commits == marks else { return }
            let available = state == .reading || state == .article && ReaderMode.showsButton
            if isReaderAvailable != available { isReaderAvailable = available }
            if isReading != (state == .reading) { isReading = state == .reading }
        }
    }

    /// Turned off, the button goes from pages not in the reader; turned on, pages are asked again.
    func readerButtonChanged() {
        guard !isReading else { return }
        isReaderAvailable = false
        readerChecked = false
    }

    /// A page moving on by itself (pushState) neither commits nor finishes: its new address is
    /// asked once, a moment later, when its content has likely come in. A load is asked at its end.
    private func readerPageMovedOn() {
        readerChecked = false
        if isReaderAvailable { isReaderAvailable = false }
        guard ReaderMode.showsButton || hasRead, let webView = loadedWebView, !webView.isLoading else { return }
        let marks = commits
        readerRecheck?.cancel()
        readerRecheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, commits == marks, !webView.isLoading, browser?.isOnScreen(self) == true else { return }
            checkReader()
        }
    }

    private func resetReader() {
        readerChecked = false
        if isReaderAvailable { isReaderAvailable = false }
        if isReading { isReading = false }
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

    private func adopt(_ reader: PDFReader) {
        if favicon == nil { favicon = PDFReader.icon }
        if title.isEmpty {
            title = reader.title
            if let url { historyStore?.updateTitle(title, for: url) }
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
        if !isLoading {
            checkReader()
            browser?.translator.check(self)
        }
        // Its title may have changed while off screen, where it doesn't ask the model.
        if !isAsleep { browser?.tidyTitles.update(self) }
        // Shown as Lithium opens (the selected tab, a split's pages), a restored page waits for the
        // last session's cookies (`Browser.cookieRestore`), or it would load signed out.
        if let restoring = browser?.cookieRestore {
            Task { [weak self] in
                await restoring.value
                self?.wakeIfAsleep()
            }
        } else {
            wakeIfAsleep()
        }
    }

    /// Without selecting it.
    func wakeIfAsleep() {
        guard isAsleep, let url else { return }
        load(url, history: sleepingState)
        reloadedURL = url
        // A pinned page's icon may have changed while it slept (a calendar's date).
        if let saved = browser?.savedIconURL(of: self) { followIcon(saved) }
    }

    /// For `load(_:history:)` in a reopened or duplicated tab; nil when it can't come back that way.
    var history: Any? {
        isAsleep ? sleepingState : loadedWebView.flatMap(restorableState(of:))
    }

    /// Not for local files and Lithium's pages, whose read access and trust `load` grants, nor a
    /// page whose process died mid-navigation, whose history lacks the page it was going to.
    private func restorableState(of webView: WKWebView) -> Any? {
        guard !historyForgotten else { return nil }
        let list = webView.backForwardList
        // Lithium's PDF viewer needs the bytes, which a page back from history may not come with.
        guard pdf == nil, let current = list.currentItem, current.url == url,
              (list.backList + [current] + list.forwardList).allSatisfy({ Self.wakesWithHistory($0.url) }) else { return nil }
        return webView.interactionState
    }

    /// Asleep too: woken before the clear ends, it would otherwise hand its new list to a quit.
    func forgetHistory() {
        sleepingState = nil
        historyForgotten = true
    }

    /// A blob: address dies with the process that made it.
    private static func wakesWithHistory(_ url: URL) -> Bool {
        !url.isFileURL && !Internal.isInternal(url) && url.scheme != Extensions.scheme && url.scheme != "blob"
    }

    func load(_ url: URL, history: Any?) {
        guard let history else { return load(url) }
        self.url = url
        sleepingState = nil
        isAsleep = false
        appStartedLoad = true
        webView.interactionState = history
        // A state WebKit could not read leaves an empty page.
        if webView.backForwardList.currentItem == nil { load(url) }
    }

    /// Decided in the app, without waiting on the page's process, which may be stuck or slow when
    /// memory is short: sound is as last noted, which every sleep pass does for every tab first.
    func canSleep(idleFor interval: TimeInterval) -> Bool {
        guard !isAsleep, url != nil else { return false }
        return !webView.isLoading
            && Date().timeIntervalSince(lastActive) > interval
            && !wasHeardLately
            && !isInCall
    }

    var wasHeardLately: Bool {
        Date().timeIntervalSince(lastHeard ?? .distantPast) <= Self.silenceBeforeSleep
    }

    private static let silenceBeforeSleep: TimeInterval = 5 * 60

    /// From the page shown, not one put away or left behind by sleep.
    func noteUnsavedInput(from webView: WKWebView) {
        guard webView === loadedWebView, !isAsleep else { return }
        unsavedInputAt = Date()
    }

    func noteUpload(_ uploading: Bool, from webView: WKWebView) {
        guard webView === loadedWebView, !isAsleep else { return }
        uploadingFrames = max(0, uploadingFrames + (uploading ? 1 : -1))
    }

    /// The page reports again while the user keeps at it: this is work left alone for less than
    /// `interval`. An upload counts for as long as it runs.
    func hasUnsavedInput(within interval: TimeInterval) -> Bool {
        isUploading || unsavedInputAt.map { Date().timeIntervalSince($0) <= interval } ?? false
    }

    /// Uses Safari's speaker state (private `_isPlayingAudio`). WebKit's public media state calls a
    /// page holding a video it never started "playing", which would keep most news pages awake: it
    /// is only a fallback, counting from the next pass, since the page's process answers it.
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

    /// Nil from a WebKit without it.
    var isPlayingAudio: Bool? {
        guard let webView = loadedWebView, webView.responds(to: Selector(("_isPlayingAudio"))) else { return nil }
        return webView.value(forKey: "_isPlayingAudio") as? Bool
    }

    /// For the hover card. Private API; nil without it, and while the process isn't running (WebKit reports 0).
    var webProcessIdentifier: pid_t? {
        guard let webView = loadedWebView, webView.responds(to: Selector(("_webProcessIdentifier"))),
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }

    /// Camera, microphone, or screen sharing (private API, absent from older WebKits).
    var isInCall: Bool {
        guard let webView = loadedWebView else { return false }
        if webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none { return true }
        guard webView.responds(to: Selector(("_displayCaptureState"))) else { return false }
        return (webView.value(forKey: "_displayCaptureState") as? Int ?? 0) != 0
    }

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
        // An unanswered prompt holds the page's delegate call, and with it the old web view.
        browser?.permissions.cancel(tabID: id)
        browser?.appLinks.cancel(tabID: id)
        sleepingState = loadedWebView.flatMap(restorableState(of:))
        addressAfterWaking = nil
        // Its page and its popup's no longer know each other once it wakes in a new web view.
        unpair()
        scriptOpener = nil
        browser?.tabs.forEach { if $0.scriptOpener === self { $0.scriptOpener = nil } }
        // The next web view asks afresh, even if this one's question never gets an answer.
        isAskingPlayback = false
        tearDown()
        // Asleep, the page can't change its count, which would stay on the tile as it was.
        updateUnread { $0.pageSlept() }
        pdf = nil
        pdfHistory = [:]
        pdfRecency = []
        resetReader()
        resetTranslation()
        hasRead = false
        hasInternalBridge = false
        hasWebstoreBridge = false
        isAsleep = true
        appliedProtections = nil
        // Waking loads the address again, which shows the page again if it is still blocked.
        endBlockedPage()
        letThrough = nil
        protectedURL = nil
        canGoBack = false
        canGoForward = false
        isLoading = false
        unsavedInputAt = nil
        uploadingFrames = 0
        awaitCommit(false)
        self.configuration = configuration
        historyForgotten = false
        withMutation(keyPath: \.webView) { loadedWebView = nil }
    }

    func tearDown() {
        answerHiddenDialog()
        endResubmissionSheet()
        endDialogSheet()
        observations.removeAll()
        // A favicon fetch holds the tab and its web view, and can last a minute on a page that
        // names many icons: a closed tab's page would keep running until it ends.
        faviconLoad?.cancel()
        faviconLoad = nil
        forgetLiveIcon()
        // A search still on its way would keep a closed private session's address once it ends.
        endBlockedPage()
        guard let loadedWebView else { return }
        loadedWebView.stopLoading()
        loadedWebView.navigationDelegate = PutAwayWebView.refusing
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
                    // The error page's title goes no further than the tab.
                    guard !self.isShowingError else { return }
                    if self.pinID != nil { self.updateUnread { $0.setTitle(self.title) } }
                    self.browser?.tidyTitles.update(self)
                    if let url = self.url { self.historyStore?.updateTitle(self.title, for: url) }
                    self.tellExtensions(.title)
                }
            },
            webView.observe(\.url) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isAsleep, let url = webView.url, url != self.url else { return }
                    self.url = url
                    self.tellExtensions(.URL)
                }
            },
            webView.observe(\.isLoading) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    // WebKit reports a load from the moment it is asked for, before it calls
                    // didStartProvisionalNavigation.
                    if self?.isLoading != webView.isLoading { self?.awaitCommit(webView.isLoading) }
                    self?.isLoading = webView.isLoading
                    self?.tellExtensions(.loading)
                }
            },
            webView.observe(\.estimatedProgress) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.progress = webView.estimatedProgress }
            },
            webView.observe(\.pageZoom, options: .initial) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.zoom = webView.pageZoom }
            },
            webView.observe(\.canGoBack) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
        ]
        // The mini player's surest sign a page plays: it then asks the page what it plays.
        if let hearing = Hearing(webView, changed: { [weak self] in
            guard let self, !self.isAsleep else { return }
            self.browser?.nowPlaying.hearingChanged(self)
        }) {
            observations.append(hearing)
        }
    }

    private func tellExtensions(_ properties: WKWebExtension.TabChangedProperties) {
        guard !isAsleep, let browser, browser.tabs.contains(self) else { return }
        browser.extensions.didChange(properties, of: self)
    }

    private func applyProtections(for url: URL, if stillWanted: (() -> Bool)? = nil) async {
        guard let privacy = browser?.privacy else { return }
        protectionRequests += 1
        await privacy.waitUntilReady()
        await browser?.extensions.waitUntilLoaded()
        if let stillWanted, !stillWanted() { return }
        protectedURL = url
        let enabled = privacy.isEnabled(for: url, privateSession: privateSession, space: siteSpace)
        var leftOff = privacy.allowedGroups(for: url, privateSession: privateSession)
        if let letThrough, letThrough.host == Privacy.siteHost(url) { leftOff.formUnion(letThrough.groups) }
        let controller = webView.configuration.userContentController
        if appliedProtections?.enabled != enabled || appliedProtections?.generation != privacy.generation || appliedProtections?.leftOff != leftOff {
            privacy.applyRuleLists(enabled, leavingOff: leftOff, to: controller)
            appliedProtections = (enabled, privacy.generation, leftOff)
        }
        // Advanced rules are per site, so scripts are swapped on every main-frame navigation.
        controller.removeAllUserScripts()
        protectedFrameHosts = []
        PageStyle.scripts(for: url, privateSession: privateSession, space: siteSpace).forEach(controller.addUserScript)
        if MarkdownReader.handles(url) { controller.addUserScript(MarkdownReader.script) }
        if ChromeWebStore.isStore(url) { controller.addUserScript(ChromeWebStore.script) }
        controller.addUserScript(PageTranslation.script)
        controller.addUserScript(PageOverrides.script)
        browser?.nowPlaying.install(on: controller)
        UnsavedInput.shared.install(on: controller)
        if pinID != nil { controller.addUserScript(PinnedPages.script) }
        privacy.addScripts(enabled, for: url, privateSession: privateSession, to: controller)
        browser?.agent?.install(on: controller, for: self)
    }

    /// Groups left off a page let through blocked only its own load: once its response is in, before
    /// the document starts, they are back for its scripts, images and frames. WebKit can't turn off
    /// part of a compiled list, so this keeps the rest of a group (other ads, trackers) on the page.
    /// A site always allowed keeps its groups off its whole page, as before it was let through.
    private func putBackLeftOffGroups() {
        guard let applied = appliedProtections, !applied.leftOff.isEmpty, let privacy = browser?.privacy else { return }
        let allowed = privacy.allowedGroups(for: protectedURL, privateSession: privateSession)
        guard applied.leftOff != allowed else { return }
        privacy.applyRuleLists(applied.enabled, leavingOff: allowed, to: webView.configuration.userContentController)
        appliedProtections = (applied.enabled, privacy.generation, allowed)
    }

    /// A main-frame load that ends unshown left the page with scripts set up for its target: a frame
    /// added next would farble with that site's seed and get its rules. Put the shown page's back.
    private func restoreProtections() {
        guard hasShownPage, protectedURL != shownProtectedURL else { return }
        let shown = shownProtectedURL, stale = protectedURL, requests = protectionRequests
        // Once WebKit is done with the load: nothing else set up scripts since, and no load is on its way.
        let untouched = { [weak self] (started: Int) in
            guard let self else { return false }
            return protectionRequests == requests + started && protectedURL == stale && !webView.isLoading
        }
        Task {
            // A load asked twice to restore (a dropped load also ends unshown) restores once: the
            // second sees the first's request. Otherwise each would see the other's and both give up.
            guard untouched(0) else { return }
            guard let shown else {
                webView.configuration.userContentController.removeAllUserScripts()
                browser?.agent?.removeConsole(from: webView.configuration.userContentController)
                protectedURL = nil
                return
            }
            await applyProtections(for: shown) { untouched(1) }
        }
    }

    /// One lookup per host per page; rebuilding the page's scripts on navigation drops them.
    private func addFrameProtections(for url: URL) {
        guard let privacy = browser?.privacy, let page = webView.url, let host = url.host()?.lowercased(),
              protectedFrameHosts.insert(host).inserted,
              let script = privacy.frameScript(privacy.isEnabled(for: page, privateSession: privateSession, space: siteSpace), for: url, in: page) else { return }
        webView.configuration.userContentController.addUserScript(script)
    }

    /// Also called when the old page's load ends unshown: otherwise the address would wait for,
    /// and replace, whichever page shows next.
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
        // A tab opened just to fetch a file has no page to show once the download starts; like
        // Safari, close it, without a Reopen Closed Tab entry that would only download it again.
        if !hasHadPage, webView.backForwardList.currentItem == nil { browser?.close(self, remembering: false, goingBack: true) }
    }

    private func endedUnshown(_ load: UnshownLoad) {
        // Open anyway was for a page that now never shows (Stop, a download): the next load is
        // blocked again, and the blocked page, still underneath, gets its explanation and buttons back.
        let passed = letThrough
        letThrough = nil
        restoreProtections()
        lastUnshownLoad = load
        unshownLoads += 1
        if let passed {
            failedURL = passed.url
            showBlockedPage(passed.url)
        }
        browser?.agent?.loadEndedUnshown(in: self)
    }

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
        guard !followsPageIcon else { return }
        // The fetch can outlast the page: an icon found after the tab moved to another site isn't its.
        let host = url?.host()
        let favicons = browser?.favicons ?? .shared
        // A private tab shows an icon already cached, and fetches and stores none.
        let found = isEphemeral ? host.flatMap(favicons.cachedData(host:)) : await favicons.favicon(for: webView, counting: unread.shown != nil)
        guard !Task.isCancelled, let data = found, url?.host() == host,
              !followsPageIcon, data != faviconData else { return }
        faviconData = data
        favicon = NSImage(data: data)
        browser?.didLoadFavicon(data, in: self)
    }

    private var followsPageIcon: Bool {
        liveIcon != nil && unread.shown == nil
    }

    func showFavicon(_ data: Data) {
        guard data != faviconData else { return }
        faviconData = data
        favicon = NSImage(data: data)
    }

    /// Paced by `iconInterval`, so an animated icon can't rewrite the favorite at every frame. Nothing
    /// is fetched while the tile shows an unread badge: Discord, Gmail or WhatsApp then name an icon
    /// with the count drawn in, which would show it twice.
    private func followIcon(_ url: URL, after delay: Duration = .zero) {
        guard url != liveIcon else { return }
        liveIcon = url
        guard iconFollow == nil, unread.shown == nil else { return }
        faviconLoad?.cancel()
        faviconLoad = nil
        iconFollow = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            var fetched: URL?
            while !Task.isCancelled, let tab = self, tab.unread.shown == nil, let next = tab.liveIcon, next != fetched {
                fetched = next
                await tab.browser?.refreshIcon(of: tab, from: next)
                try? await Task.sleep(for: Self.iconInterval)
            }
            // A cancelled one may already have been replaced.
            if !Task.isCancelled { self?.iconFollow = nil }
        }
    }

    private func forgetLiveIcon() {
        liveIcon = nil
        iconFollow?.cancel()
        iconFollow = nil
    }

    /// Assigned only when the badge changes, so the sidebar doesn't redraw for nothing.
    private func updateUnread(_ change: (inout UnreadBadge) -> Void) {
        var next = unread
        change(&next)
        guard next != unread else { return }
        let wasShown = unread.shown != nil
        unread = next
        // After `iconInterval`, so a new icon reported just after the title is the one fetched.
        if wasShown, next.shown == nil, let icon = liveIcon {
            liveIcon = nil
            followIcon(icon, after: Self.iconInterval)
        }
    }

    func receive(_ signal: PinnedPages.Signal) {
        switch signal {
        case .badge(let count): updateUnread { $0.setAppBadge(count) }
        case .clearBadge: updateUnread { $0.clearAppBadge() }
        case .notification:
            guard browser?.selectedTabID != id || loadedWebView?.window?.isKeyWindow != true else { return }
            updateUnread { $0.notify() }
        case .icon(let url, let title):
            // The count that came with the icon holds its fetch back.
            if let title, !isShowingError { updateUnread { $0.setTitle(title) } }
            followIcon(url)
        }
    }

    func didOpen() {
        updateUnread { $0.open() }
    }

    /// Pinned, the page gets its script and channel at once, without a reload. A tab restored asleep
    /// counts nothing from its saved title: the badge only says what a page said since launch.
    private func pinnedChanged() {
        if pinID == nil {
            // The icon first: a badge going away would follow it again.
            forgetLiveIcon()
            updateUnread { $0 = UnreadBadge() }
        }
        guard let browser, let webView = loadedWebView, !isAsleep else { return }
        browser.pinnedPages.setChannel(pinID != nil, on: webView.configuration.userContentController)
        guard pinID != nil else { return }
        updateUnread { $0.setTitle(title) }
        if ["http", "https"].contains(webView.url?.scheme?.lowercased()) {
            webView.evaluateJavaScript(PinnedPages.script.source, in: nil, in: .page)
        }
    }

    private func showError(_ error: Error, for url: URL?) {
        guard !Self.isDropped(error) else { return }
        let error = error as NSError
        failedURL = url
        loadError = error
        letThrough = nil
        endBlockedPage()
        let blocked = url.flatMap { BlockedPage.isBlocked(error) ? $0 : nil }
        if let blocked { showBlockedPage(blocked) }
        let message = error.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        // A blocked page's explanation is `BlockedPageView`, over this one.
        let html = """
            <!doctype html><meta charset="utf-8"><title>\(blocked == nil ? "Can’t open this page" : "Page blocked")</title>
            <style>
              body { font: 15px "DM Sans", -apple-system, sans-serif; color: #444; display: grid; place-items: center; height: 90vh; margin: 0; }
              h1 { font-size: 22px; font-weight: 600; color: #111; margin: 0 0 8px; }
              @media (prefers-color-scheme: dark) { body { background: #1c1c1e; color: #aaa; } h1 { color: #eee; } }
            </style>
            \(blocked == nil ? "<div><h1>Can’t open this page</h1><p>\(message)</p></div>" : "")
            """
        isStartingErrorPage = true
        // `loadHTMLString` gets no history entry: the page before would be the current one, Back
        // would skip it. WebKit's alternate page (Safari's) takes the failed address's place in the
        // history, and Back, Forward and Reload to it try that address again. It returns no
        // navigation; `didStartProvisionalNavigation` takes the one WebKit reports, if any.
        guard let url, webView.responds(to: Self.loadAlternateHTML) else {
            errorNavigation = webView.loadHTMLString(html, baseURL: url)
            return
        }
        errorNavigation = nil
        typealias Load = @convention(c) (AnyObject, Selector, NSString, NSURL, NSURL) -> Void
        let load = unsafeBitCast(webView.method(for: Self.loadAlternateHTML), to: Load.self)
        load(webView, Self.loadAlternateHTML, html as NSString, url as NSURL, url as NSURL)
    }

    /// Private WebKit (`WKWebViewPrivate`), as Safari's error pages use.
    private static let loadAlternateHTML = Selector(("_loadAlternateHTMLString:baseURL:forUnreachableURL:"))

    /// The lists are read only now, on the page's way out, and never for a page that loads.
    private func showBlockedPage(_ url: URL) {
        blockedPage = BlockedPage(url: url)
        blockLookup?.cancel()
        guard let privacy = browser?.privacy else { return }
        let lookup = Task { [privateSession] in await privacy.blockReason(for: url, privateSession: privateSession) }
        blockLookup = lookup
        Task { [weak self] in
            let reason = await lookup.value
            guard let self, self.blockLookup == lookup else { return }
            self.blockedPage?.reason = reason
        }
    }

    private func endBlockedPage() {
        blockedPage = nil
        // A search no page waits for any more stops.
        blockLookup?.cancel()
        blockLookup = nil
    }

    /// Open anyway lets this one page through; Always allow saves the site (for its private session
    /// only, in a private tab). Either way only the groups that blocked it are left off, or every
    /// loaded one when the lists' text doesn't say which.
    func letBlockedPageThrough(always: Bool) async {
        guard let page = blockedPage, let host = Privacy.siteHost(page.url), let lookup = blockLookup else { return }
        let groups = await lookup.value.groups
        // Not if the tab went elsewhere while the lists were read.
        guard blockLookup == lookup, let browser else { return }
        if always {
            browser.privacy.allowPages(of: page.url, groups: groups, privateSession: privateSession)
        } else {
            passToLoad = (page.url, host, groups)
        }
        browser.navigate(self, .open(page.url))
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
        // Asked once, and only when needed: the answer uses the press up.
        lazy var pressed = isPressed(action, in: webView)
        // Only the first decision after an extension sent a sleeping tab on can be its old page's
        // load; the next ones (redirects, a Reload after a download) go through.
        if isMainFrame, let superseded = supersededURL {
            supersededURL = nil
            if url == superseded { return (.cancel, preferences) }
        }
        // A link, form, or click-started frame load uses the press up, so the page it opens can't
        // reuse it; not other frame loads (an ad's), which would take it from the page.
        if [.linkActivated, .formSubmitted].contains(action.navigationType) || !isMainFrame && action.navigationType == .other && Self.isUserInitiated(action),
           !Self.isRedirect(action) { _ = pressed }
        // A server's redirect keeps the type of the click that started its load, whoever pressed since.
        if [.linkActivated, .formSubmitted].contains(action.navigationType), !Self.isRedirect(action), (webView as? PageWebView)?.agentPressedLast != true {
            browser?.agent?.userStartedLoad(in: self)
        }
        if action.shouldPerformDownload {
            let name = url.lastPathComponent
            if let allowed = await browser?.agent?.confirmDownload(in: self, fileName: ["", "/"].contains(name) ? nil : name, size: nil, from: url) {
                return (allowed ? .download : .cancel, preferences)
            }
            // A frame's `<a download>` asks first, as its attachments do (see the response policy),
            // whichever frame it names; so does the page's own when no press started it.
            if isMainFrame, (action.sourceFrame as WKFrameInfo?)?.isMainFrame ?? true, pressed { return (.download, preferences) }
            return (await askToDownload() ? .download : .cancel, preferences)
        }
        if isMainFrame, action.targetFrame != nil, !Self.isRedirect(action) {
            // Not every Back or Reload: a page's own `history.go(0)` comes as one too.
            loadWasRequested = appStartedLoad || url != strippedRedirect && pressed
            appStartedLoad = false
            strippedRedirect = nil
        }

        guard Self.webSchemes.contains(url.scheme?.lowercased() ?? "") else {
            // Only the user's own click hands an address to another app, never an agent's or a
            // script's. The site whose frame has the link (an ad's, say) is the one asking.
            if action.navigationType == .linkActivated, pressed, (webView as? PageWebView)?.agentPressedLast != true {
                let host = (action.sourceFrame as WKFrameInfo?)?.securityOrigin.host ?? shownHost ?? ""
                openInApp(url, from: host)
            }
            // A load refused here ends without a word from WebKit.
            if isMainFrame, !goToAddressAfterWaking() { endedUnshown(.refused(scheme: url.scheme ?? "")) }
            return (.cancel, preferences)
        }

        // Going back to, reloading or waking on a form's result sends the form again (an order, a
        // payment): like Safari, ask first, frames too. Refused, a web view with nothing shown yet
        // loads the address instead, without the form.
        if action.navigationType == .formResubmitted {
            // A web view put away meanwhile (its tab closed or asleep) never sends it, nor reloads.
            guard await confirmResubmission(of: url, inFrame: !isMainFrame), webView.navigationDelegate === self else {
                // Unless the tab was sent elsewhere meanwhile (an extension's address, say).
                if isMainFrame, !hasShownPage, webView.navigationDelegate === self { Task { if self.url == url { self.load(url) } } }
                return (.cancel, preferences)
            }
        }

        let source = (action.sourceFrame as WKFrameInfo?)?.securityOrigin.protocol
        if Internal.isInternal(url) {
            // Only the app or another Lithium page may open these. Back, Forward and Reload only
            // return to one the tab showed: a website can't put Lithium's pages in the history.
            let isRevisit = [.backForward, .reload].contains(action.navigationType)
            guard isMainFrame, url == trustedInternalURL || source == Internal.scheme || isRevisit else {
                if isMainFrame { endedUnshown(.refused(scheme: Internal.scheme)) }
                return (.cancel, preferences)
            }
            // A new tab's page is set up by that tab's own decision, not in this one.
            guard action.targetFrame != nil else { return (.allow, preferences) }
            trustedInternalURL = nil
            webView.configuration.userContentController.removeAllUserScripts()
            browser?.agent?.removeConsole(from: webView.configuration.userContentController)
            protectedURL = nil
            setWebstoreBridge(false)
            // Before the page's first script asks for it; taken away only once another page commits.
            setInternalBridge(true)
            return (.allow, preferences)
        }
        guard url.scheme != Extensions.scheme else { return (.allow, preferences) }
        guard isMainFrame else {
            addFrameProtections(for: url)
            return (.allow, preferences)
        }

        // An agent's middle click is WebKit's button mask 4. A script's ⌘-click is followed in
        // place, as in WebKit: a new tab of Lithium's would get around the popup blocker.
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) || action.buttonNumber == 4 && browser?.agent?.actingSession(in: self) != nil,
           pressed {
            if await browser?.agent?.open(url, from: self) != true {
                browser?.newTab(url: url, selecting: action.modifierFlags.contains(.shift), privateStore: privateStore, openedFrom: self)
            }
            return (.cancel, preferences)
        }
        // A new tab's page decides for itself once made in `createWebViewWith`.
        guard action.targetFrame != nil else { return (.allow, preferences) }
        // An extension's page sending its tab to a website (1Password's Sign In button) goes on
        // in a new web view. Only that way round: a website may not open an extension's pages.
        if ["http", "https"].contains(url.scheme?.lowercased()), needsNewWebView(for: url) {
            Task { self.load(action.request) }
            return (.cancel, preferences)
        }
        // Before the store's first script asks for it; removed only once another page commits.
        if ChromeWebStore.isStore(url) { setWebstoreBridge(true) }
        // A woken tab's new web view gets the channel at its first page.
        browser?.pinnedPages.setChannel(pinID != nil, on: webView.configuration.userContentController)

        // A pressed link or form is a new load, not the page bouncing back: stripped again.
        if [.linkActivated, .formSubmitted].contains(action.navigationType), !Self.isRedirect(action), pressed {
            strippedURL = nil
        }
        // Not Back, Forward or Reload: cancelled for a new load, they would drop the forward list
        // and keep the user from going back past that page.
        if [.linkActivated, .formSubmitted, .other].contains(action.navigationType),
           browser?.privacy.isEnabled(for: url, privateSession: privateSession, space: siteSpace) != false, action.request.httpMethod == "GET",
           let clean = TrackingParameters.stripped(url), clean != strippedURL {
            strippedURL = clean
            appStartedLoad = loadWasRequested
            // A page sending itself on (`location.replace`, a meta refresh) takes its place in the
            // history: a new load would leave it there, so Back would land on it and bounce again.
            if action.navigationType == .other, !loadWasRequested, webView.backForwardList.currentItem != nil {
                strippedRedirect = clean
                Task {
                    do {
                        _ = try await webView.callAsyncJavaScript("location.replace(url)", arguments: ["url": clean.absoluteString], contentWorld: .defaultClient)
                    } catch {
                        strippedRedirect = nil
                        webView.load(URLRequest(url: clean))
                    }
                }
            } else {
                Task { webView.load(URLRequest(url: clean)) }
            }
            return (.cancel, preferences)
        }
        // Open anyway lets through its own site only. WebKit checks a redirect before asking here,
        // with the groups still off, so one to another site goes again with every list on. One within
        // the site (to https, to another path; the same host, `www.` aside, not a language subdomain)
        // is part of that load: the same filters name it.
        if let letThrough, Self.isRedirect(action), letThrough.host != Privacy.siteHost(url) {
            self.letThrough = nil
            Task { self.load(url) }
            return (.cancel, preferences)
        }

        await applyProtections(for: url)
        Privacy.setEngineProtections(browser?.privacy.isEnabled(for: url, privateSession: privateSession, space: siteSpace) ?? true, on: preferences)
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.isForMainFrame {
            httpStatus = (response.response as? HTTPURLResponse)?.statusCode
            putBackLeftOffGroups()
        }
        // Before the document starts, after the page's farbling (see Privacy.trustedTypesScript).
        if let privacy = browser?.privacy, let page = response.isForMainFrame ? response.response.url : webView.url {
            privacy.addTrustedTypesScript(privacy.isEnabled(for: page, privateSession: privateSession, space: siteSpace), for: response.response, privateSession: privateSession,
                                          to: webView.configuration.userContentController)
        }
        let isAttachment = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        guard !response.canShowMIMEType || isAttachment else { return .allow }
        // A download the agent started waits for the user's Allow, in place of what follows.
        if let allowed = await browser?.agent?.confirmDownload(in: self, fileName: response.response.suggestedFilename, size: response.response.expectedContentLength, from: response.response.url) {
            return allowed ? .download : .cancel
        }
        if response.isForMainFrame, loadWasRequested { return .download }
        // A frame (an ad, a hidden download frame) or a page going to a file without a click asks
        // first, as in Safari: the site the user is on is allowed, or not, once.
        return await askToDownload() ? .download : .cancel
    }

    private func askToDownload() async -> Bool {
        guard let browser, let host = shownHost, !host.isEmpty else { return false }
        return await browser.permissions.request([.downloads], host: host, tabID: id, privateSession: privateSession, space: siteSpace)
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
        // The alternate error page's load, should a WebKit name it after all.
        if isStartingErrorPage, errorNavigation == nil { errorNavigation = navigation }
        if navigation !== errorNavigation {
            failedURL = nil
            endBlockedPage()
        }
        httpStatus = nil
        awaitCommit(true, for: navigation)
        isStartingErrorPage = false
    }

    /// `navigation` is nil when `isLoading` tells of a load before WebKit names it: that load,
    /// named next, isn't counted twice, but one that replaces the load under way is.
    private func awaitCommit(_ awaiting: Bool, for navigation: WKNavigation? = nil) {
        let isErrorPage = navigation.map { $0 === errorNavigation } ?? isStartingErrorPage
        if awaiting, !isErrorPage, !isAwaitingCommit || navigation != nil && startedNavigation != nil && startedNavigation !== navigation {
            loadStarts += 1
            unshownAtStart = unshownLoads
        }
        startedNavigation = awaiting ? navigation ?? startedNavigation : nil
        isAwaitingCommit = awaiting
    }

    /// Private WebKit (`WKNavigationDelegatePrivate`), which calls it only on a delegate that has it.
    /// `type` is `_WKSameDocumentNavigationType`: 0 an anchor, 1 pushState, 2 replaceState, 3 Back or Forward.
    @objc(_webView:navigation:didSameDocumentNavigation:)
    func webView(_ webView: WKWebView, navigation: WKNavigation?, didSameDocumentNavigation type: Int) {
        if type == 0 || type == 3 { sameDocumentNavigations += 1 }
        // These never reach didFinish, so their visit is recorded here, once the address changed.
        // replaceState rewrites the entry in place, as a search box or a map does on every change:
        // no new visit. One during a load is recorded by didFinish.
        if type != 2, !webView.isLoading, let url = webView.url, url != recordedURL { recordVisit(url, title: title) }
        // A web app's new view, through pushState or Back and Forward, is a new page to search.
        if type == 1 || type == 3 { searchAgainIfFinding() }
    }

    /// The find bar's count and match belong to the page it searched.
    private func searchAgainIfFinding() {
        guard let browser, browser.showsFindBar(over: self), !browser.find.query.isEmpty else { return }
        let find = browser.find
        Task { await find.update(query: find.query, in: findTarget) }
    }

    /// Private WebKit (`WKNavigationDelegatePrivate`): the page menu's Download Image, Linked File and
    /// Video. Without it WebKit drops the download before it starts.
    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreateDownload download: WKDownload) {
        Downloads.shared.track(download, askingWhere: true)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasShownPage = true
        hasHadPage = true
        shownProtectedURL = protectedURL
        awaitCommit(false)
        // A new document: its script tells again, a page back from the cache too.
        unsavedInputAt = nil
        uploadingFrames = 0
        resetReader()
        resetTranslation()
        if navigation !== errorNavigation {
            loadError = nil
            // Open anyway was for this page: the next one gets every list again.
            letThrough = nil
            // A page back from the cache had no response to put them back at.
            putBackLeftOffGroups()
        }
        // A later link to the same tracked address (after Back, say) is stripped again.
        if webView.url != strippedURL { strippedURL = nil }
        // Only now: a load that never shows (a download, a 204, Stop) leaves Lithium's page its bridge.
        setInternalBridge(Internal.isInternal(webView.url))
        setWebstoreBridge(ChromeWebStore.isStore(webView.url))
        // A woken tab's old page is only on its way out: not the document an agent waits for.
        if !goToAddressAfterWaking() { commits += 1 }
        // A prompt left from the page before would read as the new page's.
        browser?.permissions.cancel(tabID: id)
        browser?.appLinks.cancel(tabID: id)
        browser?.nowPlaying.discard(self)
        // Only once another site shows: a load that never does keeps the page's icon.
        if let old = shownHost, old != webView.url?.host() {
            forgetLiveIcon()
            updateUnread { $0.leaveSite() }
            favicon = nil
            faviconData = nil
        }
        shownHost = webView.url?.host()
        let list = webView.backForwardList
        let live = Set(list.backList + list.forwardList + [list.currentItem].compactMap { $0 })
        pdfHistory = pdfHistory.filter { live.contains($0.key) }
        pdfRecency.removeAll { pdfHistory[$0] == nil }
        let previous = pdf
        defer { if let previous, previous !== pdf { previous.putAway() } }
        guard PDFReader.isShowingPDF(webView), let url = webView.url else {
            pdf = nil
            if favicon === PDFReader.icon { favicon = nil }
            return
        }
        if let item = list.currentItem, let kept = pdfHistory[item], kept.url == url {
            pdf = kept
            keepPDF(kept, for: item)
            return
        }
        let reader = PDFReader(url: url)
        reader.isPrivate = isEphemeral
        // Never Lithium's own pages; local files only from a local PDF and strictly inside its folder
        // (a file opens with read access to its folder, and the folder itself to the one above).
        let folder = url.isFileURL ? url.deletingLastPathComponent().standardizedFileURL.pathComponents : nil
        let site = url.host() ?? ""
        reader.onOpenLink = { [weak self] url, inNewTab in
            guard let self else { return }
            let scheme = url.scheme?.lowercased()
            switch scheme {
            case "http", "https", "file":
                guard scheme != "file" || folder.map({ let path = url.standardizedFileURL.pathComponents; return path.count > $0.count && path.starts(with: $0) }) == true else { return }
                if inNewTab { self.browser?.newTab(url: url, selecting: false, privateStore: self.privateStore, openedFrom: self) } else { self.load(url) }
            case Internal.scheme, Extensions.scheme:
                break
            default:
                if NSApp.currentEvent.map(NativeInput.isAgents) != true { self.openInApp(url, from: site) }
            }
        }
        pdf = reader
        if let item = list.currentItem { keepPDF(reader, for: item) }
    }

    private func keepPDF(_ reader: PDFReader, for item: WKBackForwardListItem) {
        pdfHistory[item] = reader
        pdfRecency.removeAll { $0 == item }
        pdfRecency.append(item)
        while pdfRecency.count > Self.keptPDFs { pdfHistory[pdfRecency.removeFirst()] = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // After the visit is recorded below, so the PDF's title lands on this visit's row.
        defer {
            if let pdf {
                if pdf.document == nil { Task { await openPDF(from: webView, reader: pdf) } } else { adopt(pdf) }
            }
        }
        searchAgainIfFinding()
        guard failedURL == nil else { return }
        if browser?.isOnScreen(self) == true {
            checkReader()
            browser?.translator.check(self)
        }
        if let url = webView.url {
            if url == reloadedURL { recordedURL = url } else { recordVisit(url, title: webView.title ?? "") }
        }
        reloadedURL = nil
        browser?.tidyTitles.update(self)
        faviconLoad?.cancel()
        faviconLoad = Task { await refreshFavicon() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Whatever the error, cancellations included: the old page was only on its way out.
        guard !goToAddressAfterWaking() else { return }
        restoreProtections()
        // A load given up with no load after it ends here, as one that became a download does.
        if Self.isDropped(error), !webView.isLoading, unshownLoads == unshownAtStart { endedUnshown(.dropped) }
        showError(error, for: (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? url)
    }

    private static func isRedirect(_ action: WKNavigationAction) -> Bool {
        action.responds(to: NSSelectorFromString("_isRedirect")) && action.value(forKey: "_isRedirect") as? Bool == true
    }

    /// A real press, not a script, started this: WebKit's user gesture, or a press just before
    /// (for a frame's redirect or a WebKit without it). A main-frame redirect keeps its load's answer.
    private func isPressed(_ action: WKNavigationAction, in webView: WKWebView) -> Bool {
        let page = webView as? PageWebView
        if Self.isUserInitiated(action) {
            page?.usePress()
            return true
        }
        if Self.isRedirect(action), action.targetFrame?.isMainFrame == true { return loadWasRequested }
        guard page?.pressedRecently == true else { return false }
        page?.usePress()
        return true
    }

    private static func isUserInitiated(_ action: WKNavigationAction) -> Bool {
        action.responds(to: NSSelectorFromString("_isUserInitiated")) && action.value(forKey: "_isUserInitiated") as? Bool == true
    }

    private func openInApp(_ url: URL, from host: String) {
        guard let browser else { return }
        Task { await browser.appLinks.open(url, from: host, tabID: id, isPrivate: isEphemeral) }
    }

    /// Cancelled, interrupted by a policy change (WebKit 102), or WebKit's 204 "plug-in will handle
    /// load" (a media link's player took over): nothing to show the user.
    static func isDropped(_ error: Error) -> Bool {
        let error = error as NSError
        return error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && [102, 204].contains(error.code))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // A PDF stopped partway never finishes: its viewer opens what came, or leaves WebKit's
        // showing, rather than staying blank over it. A failure shows the error page instead.
        if Self.isDropped(error), let pdf, pdf.document == nil { Task { await openPDF(from: webView, reader: pdf) } }
        showError(error, for: url)
    }

    /// A tab out of sight sleeps rather than reloading: its page may have been dropped to free memory.
    /// A page that crashes again right after reloading shows an error instead of reloading forever.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The media died with the process; a reload that never commits would leave it showing as playing.
        browser?.nowPlaying.discard(self)
        browser?.agent?.pageGone(self)
        dialogOwner?.answerDialog(in: self)
        answerHiddenDialog()
        guard let browser else { return }
        guard browser.isOnScreen(self) else {
            sleep(configuration: browser.makeConfiguration(for: url))
            return
        }
        if let last = lastCrashReload, Date().timeIntervalSince(last) < 10 {
            lastCrashReload = nil
            showError(Self.crashedAgain, for: url)
        } else {
            lastCrashReload = Date()
            reloadPage()
            reloadedURL = webView.url ?? url
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
        // An agent's tab for an address agents can't open as it is (a file: page, which asks the
        // user) opens through the hub, without its opener.
        let agentSession = browser.agent?.actingSession(in: self)
        if agentSession != nil, let url = action.request.url, !url.absoluteString.isEmpty, AgentURLs.verdict(for: url) != .allowed {
            Task { await browser.agent?.open(url, from: self) }
            return nil
        }
        // WebKit hands an extension's page its own configuration for the new one, which a website
        // won't load in. It opens as a plain tab instead, without a way back to its opener.
        if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased()), needsNewWebView(for: url) {
            if let agentSession {
                let tab = browser.newAgentTab(session: agentSession, privateStore: privateStore, space: spaceID)
                tab.load(url)
                browser.agent?.didOpen(tab, from: self)
            } else if browser.quickLinks.contains(self) {
                browser.quickLinks.open(url, space: spaceID)
            } else {
                browser.newTab(url: url, privateStore: privateStore, openedFrom: self)
            }
            return nil
        }
        browser.prepare(popup: configuration)
        // A private or separate-space tab's popup shares its store, so a sign-in's cookies reach its
        // opener. A link's own window opens its pages in windows of their own.
        let popup = agentSession.map { browser.newAgentTab(session: $0, configuration: configuration, privateStore: privateStore, space: spaceID) }
            ?? (browser.quickLinks.contains(self) ? browser.quickLinks.open(configuration: configuration, space: spaceID) : nil)
            ?? browser.newTab(configuration: configuration, privateStore: privateStore, openedFrom: self)
        if agentSession != nil { browser.agent?.didOpen(popup, from: self) }
        popup.scriptOpener = self
        popup.openedByScript = true
        // A popup window gives a size or a position, as sign-in and payment windows do; a plain
        // tab (target=_blank) doesn't, nor does a featureless window.open, which looks the same.
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

    /// Private WebKit (`WKUIDelegatePrivate`), called only on a delegate that responds to it: the
    /// key that wraps the CryptoKeys a site stores. Without it WebKit reads its own login Keychain
    /// item. Only builds that may not use the Keychain answer (`answers`); called anyway, the
    /// installed app hands no key rather than one its stored CryptoKeys weren't wrapped with.
    @objc(_webCryptoMasterKeyForWebView:completionHandler:)
    func webCryptoMasterKey(_ webView: WKWebView, completionHandler: @escaping @MainActor (Data?) -> Void) {
        completionHandler(keychainAllowed ? nil : Keychain.webCryptoKey)
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        Self.answers(selector, keychainAllowed: keychainAllowed) && super.responds(to: selector)
    }

    /// The installed app leaves the key to WebKit, which keeps using its own item as it always has:
    /// a new key would leave every CryptoKey sites already stored unreadable.
    nonisolated static func answers(_ selector: Selector?, keychainAllowed: Bool) -> Bool {
        selector != #selector(webCryptoMasterKey(_:completionHandler:)) || !keychainAllowed
    }

    private func askPermission(_ kinds: [PermissionKind], origin: WKSecurityOrigin) async -> Bool {
        guard let browser, !origin.host.isEmpty else { return false }
        return await browser.permissions.request(kinds, host: origin.host, tabID: id, privateSession: privateSession, space: siteSpace)
    }

    func webViewDidClose(_ webView: WKWebView) {
        browser?.close(self, remembering: !openedByScript)
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

    /// The agent's dialog waiting in the page is the user's now.
    func didComeIntoView() {
        if let hiddenDialog {
            self.hiddenDialog = nil
            hiddenDialog.resume(returning: true)
        }
        dialogOwner?.handDialogToUser(in: self)
        browser?.agent?.cameIntoView(self)
    }

    func webViewDidMove(_ webView: WKWebView) {
        browser?.agent?.stage.didLeave(webView)
    }

    func noteUserInput() {
        browser?.agent?.userInput(in: self)
    }

    func noteUserActivation() {
        browser?.agent?.userActivated(in: self)
    }

    /// A dialog in an out-of-sight tab a connected session holds goes to the agent, never to a modal
    /// that would hold up the user; any other is the user's, and agents see it while it shows.
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
        guard let window = webView.userWindow else { return panel.runModal() == .OK ? panel.urls : nil }
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
        resubmissionSheet = alert.window
        defer { if resubmissionSheet === alert.window { resubmissionSheet = nil } }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    /// Otherwise the sheet would stay on the window for a page that is gone.
    private func endResubmissionSheet() {
        guard let sheet = resubmissionSheet else { return }
        resubmissionSheet = nil
        sheet.sheetParent?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    }

    /// A sheet, never an app-modal alert: a page out of sight would hold up the whole app
    /// (`for (;;) alert(1)` left only Force Quit), so its dialog waits for the tab to be shown.
    /// Nil is the default answer.
    func present(_ alert: NSAlert) async -> NSApplication.ModalResponse? {
        if webView.userWindow == nil {
            guard hiddenDialog == nil else { return nil }
            guard await withCheckedContinuation({ hiddenDialog = $0 }) else { return nil }
        }
        guard let window = webView.userWindow else { return nil }
        dialogSheet = alert.window
        defer { if dialogSheet === alert.window { dialogSheet = nil } }
        return await alert.beginSheetModal(for: window)
    }

    /// An extension or agent can close the tab while its dialog is up: the dialog goes with it.
    private func endDialogSheet() {
        guard let sheet = dialogSheet else { return }
        dialogSheet = nil
        sheet.sheetParent?.endSheet(sheet, returnCode: .abort)
    }

    func answerHiddenDialog() {
        guard let hiddenDialog else { return }
        self.hiddenDialog = nil
        hiddenDialog.resume(returning: false)
    }
}

/// Tabs as extensions see them (`chrome.tabs`).
extension Tab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        browser?.extensions.window
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        browser?.extensions.tabs.firstIndex(of: self) ?? NSNotFound
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

    /// Not the user's pick: their typing in the address bar goes on, and doesn't land in this page.
    func activate(for context: WKWebExtensionContext) async throws {
        browser?.select(self, picked: false)
    }

    func close(for context: WKWebExtensionContext) async throws {
        browser?.close(self)
    }

    /// A sleeping tab keeps its old page one Back away: with its history saved, the old page's load
    /// is superseded; without (restored after a crash), it wakes onto the old page first.
    /// Between an extension's pages and websites, it wakes in a new web view without its history.
    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        guard Extensions.mayOpen(url) else { throw Extensions.RefusedAddress() }
        go(to: url)
    }

    /// For an extension or agent, keeping a sleeping tab's history as `loadURL(_:for:)` describes.
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

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        if isAsleep { wake() } else { reload() }
    }

    func goBack(for context: WKWebExtensionContext) async throws {
        wake()
        goBack()
    }

    func goForward(for context: WKWebExtensionContext) async throws {
        wake()
        goForward()
    }

    /// What an extension or an agent does in a tab counts as using it, so the next sleep pass leaves it be.
    func wake() {
        lastActive = Date()
        wakeIfAsleep()
    }
}
