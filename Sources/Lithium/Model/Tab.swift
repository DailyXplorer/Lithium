import AppKit
import Observation
import WebKit

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
        let webView = WKWebView(frame: .zero, configuration: configuration)
        loadedWebView = webView
        attach(webView)
        return webView
    }
    @ObservationIgnored private var loadedWebView: WKWebView?
    /// What the next web view is made with.
    @ObservationIgnored private var configuration: WKWebViewConfiguration
    let isHome: Bool
    private(set) var isAsleep = false
    @ObservationIgnored private(set) var lastActive = Date()

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
    @ObservationIgnored private var lastCrashReload: Date?
    /// A `lithium://` page this tab was told to open by the app itself.
    @ObservationIgnored private var trustedInternalURL: URL?
    @ObservationIgnored private var hasInternalBridge = false
    @ObservationIgnored private var hasWebstoreBridge = false

    private static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", Internal.scheme, Extensions.scheme]

    /// A name the user gave the tab; it wins over the page's own title until cleared.
    var customTitle: String?
    /// A shorter name for the page's title (Max, Tidy tab titles).
    private(set) var tidyTitle: String?

    var displayTitle: String {
        if let customTitle { return customTitle }
        if let tidyTitle, browser?.tidyTitles.isEnabled == true { return tidyTitle }
        if !title.isEmpty { return title }
        if let host = url?.host() { return host }
        if let url, url.isFileURL { return url.lastPathComponent }
        return "New Tab"
    }

    init(browser: Browser, configuration: WKWebViewConfiguration, isHome: Bool = false) {
        self.browser = browser
        self.isHome = isHome
        self.configuration = configuration
        super.init()
    }

    private func attach(_ webView: WKWebView) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        observeWebView()
    }

    func load(_ url: URL) {
        self.url = url
        isAsleep = false
        if Internal.isInternal(url) { trustedInternalURL = url }
        if url.isFileURL {
            // The whole folder, so a document's relative images and links to its neighbours load.
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// A tab from the last session starts asleep: it shows its name and icon, and loads when selected.
    func restore(url: URL, title: String) {
        self.url = url
        self.title = title
        faviconData = Favicons.shared.cachedData(host: url.host() ?? "")
        favicon = Internal.isInternal(url) ? NSApp.applicationIconImage : faviconData.flatMap(NSImage.init(data:))
        isAsleep = true
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
        guard let data = await PDFReader.mainResourceData(of: webView), pdf === reader else { return }
        guard reader.open(data) else {
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
            if let url, !isHome { browser?.history.updateTitle(title, for: url) }
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
        lastActive = Date()
        if isAsleep, let url { load(url) }
    }

    /// A tab that has been left alone for a while and is not busy (loading, playing sound,
    /// using the camera or microphone) can release its page. It reloads when selected.
    func canSleep(idleFor interval: TimeInterval) async -> Bool {
        guard !isAsleep, !isHome, url != nil, !webView.isLoading,
              Date().timeIntervalSince(lastActive) > interval,
              webView.cameraCaptureState == .none, webView.microphoneCaptureState == .none else { return false }
        return await webView.requestMediaPlaybackState() != .playing
    }

    func sleep(configuration: WKWebViewConfiguration) {
        guard !isAsleep else { return }
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
                    if let url = self.url, !self.isHome { self.browser?.history.updateTitle(self.title, for: url) }
                    self.tellExtensions(.title)
                }
            },
            webView.observe(\.url) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isAsleep, let url = webView.url, url != self.url else { return }
                    if url.host() != self.url?.host() { self.favicon = nil; self.faviconData = nil }
                    self.url = url
                    // Same-document navigations (pushState) never reach didFinish.
                    if !webView.isLoading, !self.isHome { self.browser?.history.record(url, title: self.title) }
                    self.tellExtensions(.URL)
                }
            },
            webView.observe(\.isLoading) { [weak self] webView, _ in
                MainActor.assumeIsolated {
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
        guard !isHome, !isAsleep, let browser, browser.tabs.contains(self) else { return }
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
        privacy.addScripts(enabled, for: url, to: controller)
    }

    /// A tab opened just to fetch a file has no page to show once the download starts; like Safari, close it.
    private func closeIfOnlyADownload() {
        guard !isHome, webView.backForwardList.currentItem == nil else { return }
        browser?.close(self)
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
        guard let data = await Favicons.shared.favicon(for: webView), data != faviconData else { return }
        faviconData = data
        favicon = NSImage(data: data)
        browser?.didLoadFavicon(data, in: self)
    }

    private func showError(_ error: Error, for url: URL?) {
        let error = error as NSError
        let ignored = error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && error.code == 102)
        guard !ignored else { return }
        failedURL = url
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
        if action.shouldPerformDownload { return (.download, preferences) }

        guard Self.webSchemes.contains(url.scheme?.lowercased() ?? "") else {
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            return (.cancel, preferences)
        }

        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        let source = (action.sourceFrame as WKFrameInfo?)?.securityOrigin.protocol
        if Internal.isInternal(url) {
            // Websites may not open Lithium's pages; only the app or another Lithium page can.
            guard isMainFrame, url == trustedInternalURL || source == Internal.scheme else { return (.cancel, preferences) }
            trustedInternalURL = nil
            webView.configuration.userContentController.removeAllUserScripts()
            setWebstoreBridge(false)
            setInternalBridge(true)
            return (.allow, preferences)
        }
        // An extension's own pages run in its configuration, which Lithium leaves alone.
        guard url.scheme != Extensions.scheme, isMainFrame else { return (.allow, preferences) }
        setInternalBridge(false)
        setWebstoreBridge(ChromeWebStore.isStore(url))

        if isHome, !Browser.isHomeURL(url) {
            browser?.newTab(url: url)
            return (.cancel, preferences)
        }

        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) {
            browser?.newTab(url: url, selecting: action.modifierFlags.contains(.shift))
            return (.cancel, preferences)
        }

        if action.request.httpMethod == "GET", let clean = TrackingParameters.stripped(url) {
            Task { webView.load(URLRequest(url: clean)) }
            return (.cancel, preferences)
        }

        await applyProtections(for: url)
        Privacy.setEngineProtections(browser?.privacy.isEnabled(for: url) ?? true, on: preferences)
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !response.canShowMIMEType { return .download }
        if let http = response.response as? HTTPURLResponse,
           http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.track(download)
        closeIfOnlyADownload()
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.track(download)
        closeIfOnlyADownload()
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        Task { await applyProtections(for: url) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if navigation !== errorNavigation { failedURL = nil }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
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
        guard failedURL == nil, !isHome else { return }
        if let url = webView.url { browser?.history.record(url, title: webView.title ?? "") }
        browser?.tidyTitles.update(self)
        Task { await refreshFavicon() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error, for: (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error, for: url)
    }

    /// A tab out of sight comes back when it is selected rather than reloading now: its page may
    /// have been dropped to free memory. A page that takes its process down again right after
    /// reloading shows an error instead of reloading forever.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let browser else { return }
        guard isHome || browser.selectedTabID == id else {
            sleep(configuration: browser.makeConfiguration(for: url))
            return
        }
        if let last = lastCrashReload, Date().timeIntervalSince(last) < 10 {
            lastCrashReload = nil
            showError(Self.crashedAgain, for: url)
        } else {
            lastCrashReload = Date()
            webView.reload()
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
        browser.prepare(popup: configuration)
        return browser.newTab(configuration: configuration).webView
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
        _ = await present(alert(message, from: frame, buttons: ["OK"]))
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await present(alert(message, from: frame, buttons: ["OK", "Cancel"])) == .alertFirstButtonReturn
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let alert = alert(prompt, from: frame, buttons: ["OK", "Cancel"])
        let field = NSTextField(string: defaultText ?? "")
        field.frame.size.width = 260
        alert.accessoryView = field
        return await present(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
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

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = webView.window else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }
}

/// Tabs as extensions see them (`chrome.tabs`).
extension Tab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        isHome ? nil : browser?.extensions.window
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

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        load(url)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        reload()
    }

    func goBack(for context: WKWebExtensionContext) async throws {
        webView.goBack()
    }

    func goForward(for context: WKWebExtensionContext) async throws {
        webView.goForward()
    }
}
