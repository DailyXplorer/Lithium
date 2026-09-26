import AppKit
import Observation
import WebKit

@MainActor
@Observable
final class Tab: NSObject, Identifiable {
    let id = UUID()
    var pinID: Pin.ID?
    /// Replaced by a blank view while the tab sleeps, which frees the page's memory.
    private(set) var webView: WKWebView
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

    @ObservationIgnored private weak var browser: Browser?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var appliedProtections: (enabled: Bool, generation: Int)?
    @ObservationIgnored private var failedURL: URL?
    @ObservationIgnored private var errorNavigation: WKNavigation?
    @ObservationIgnored private var lastCrashReload: Date?
    /// A `lithium://` page this tab was told to open by the app itself.
    @ObservationIgnored private var trustedInternalURL: URL?
    @ObservationIgnored private var hasInternalBridge = false

    private static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", Internal.scheme]

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
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        attach(webView)
    }

    private func attach(_ webView: WKWebView) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
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
        if let failedURL { load(failedURL) } else { webView.reload() }
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
        hasInternalBridge = false
        isAsleep = true
        appliedProtections = nil
        canGoBack = false
        canGoForward = false
        isLoading = false
        // A WKWebView that never loads anything does not start a web process.
        webView = WKWebView(frame: .zero, configuration: configuration)
        attach(webView)
    }

    func tearDown() {
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
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
                }
            },
            webView.observe(\.url) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isAsleep, let url = webView.url, url != self.url else { return }
                    if url.host() != self.url?.host() { self.favicon = nil; self.faviconData = nil }
                    self.url = url
                    // Same-document navigations (pushState) never reach didFinish.
                    if !webView.isLoading, !self.isHome { self.browser?.history.record(url, title: self.title) }
                }
            },
            webView.observe(\.isLoading) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
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

    private func applyProtections(for url: URL) async {
        guard let privacy = browser?.privacy else { return }
        await privacy.waitUntilReady()
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
        if let script = browser?.sponsorBlock.script(for: url) { controller.addUserScript(script) }
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

    private func refreshFavicon() async {
        if Internal.isInternal(url) {
            favicon = NSApp.applicationIconImage
            return
        }
        guard let data = await Favicons.shared.favicon(for: webView) else { return }
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
            setInternalBridge(true)
            return (.allow, preferences)
        }
        guard isMainFrame else { return (.allow, preferences) }
        setInternalBridge(false)

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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
            sleep(configuration: browser.makeConfiguration())
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
