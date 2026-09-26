import AppKit
import UniformTypeIdentifiers
import WebKit

/// Lithium's own pages (`lithium://settings`, `lithium://history`), served from the app bundle.
///
/// Safety rules, since these pages can change settings:
/// - Only the user or the app can open one (see `Tab`'s navigation policy); web pages cannot.
/// - Files are served only to documents that are themselves `lithium://` pages, so a website
///   cannot probe for Lithium by loading its resources.
/// - The message bridge exists only while a tab shows a `lithium://` page, and it answers
///   main-frame messages from a `lithium://` origin only.
enum Internal {
    static let scheme = "lithium"
    static let settingsURL = URL(string: "lithium://settings")!
    static let historyURL = URL(string: "lithium://history")!

    static func isInternal(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == scheme
    }
}

@MainActor
final class InternalSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = InternalSchemeHandler()

    func install(on configuration: WKWebViewConfiguration) {
        guard configuration.urlSchemeHandler(forURLScheme: Internal.scheme) == nil else { return }
        configuration.setURLSchemeHandler(self, forURLScheme: Internal.scheme)
    }

    /// Tasks WebKit has cancelled; answering them afterwards would raise an exception.
    private var stopped: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, Internal.isInternal(task.request.mainDocumentURL ?? url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let parts = url.path().split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        if parts.first == "favicon", parts.count == 2 {
            let id = ObjectIdentifier(task)
            Task {
                let data = await Favicons.shared.icon(forHost: parts[1])
                guard stopped.remove(id) == nil else { return }
                if let data { respond(task, url: url, data: data, fileExtension: "png") } else { task.didFailWithError(URLError(.fileDoesNotExist)) }
            }
            return
        }
        guard let (data, fileExtension) = Self.content(for: url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        respond(task, url: url, data: data, fileExtension: fileExtension)
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, fileExtension: String) {
        let type = UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": type,
            // Pages share files across lithium:// hosts; masks and fonts are fetched with CORS.
            // Only lithium:// documents get here (checked above).
            "Access-Control-Allow-Origin": "*",
            "Content-Security-Policy": "default-src lithium:; style-src lithium: 'unsafe-inline'; script-src lithium: 'unsafe-inline'; img-src lithium: data:",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private static func content(for url: URL) -> (Data, String)? {
        let bundle = Resources.bundle
        let parts = url.path().split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        let file: URL? = switch (url.host(), parts.first) {
        case ("settings", nil): bundle.url(forResource: "settings", withExtension: "html", subdirectory: "Pages")
        case ("history", nil): bundle.url(forResource: "history", withExtension: "html", subdirectory: "Pages")
        case (_, "style.css"): bundle.url(forResource: "lithium", withExtension: "css", subdirectory: "Pages")
        case (_, "pages.js"): bundle.url(forResource: "pages", withExtension: "js", subdirectory: "Pages")
        case (_, "font"): bundle.url(forResource: "DMSans", withExtension: "ttf")
        case (_, "icon"): parts.count == 2 ? bundle.url(forResource: parts[1], withExtension: "svg") : nil
        case (_, "app-icon"): bundle.url(forResource: "AppIcon", withExtension: "png", subdirectory: "Pages")
        default: nil
        }
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return (data, file.pathExtension)
    }
}

/// The internal pages' line to the app. Settings calls return the full settings state;
/// history calls return the matching visits.
@MainActor
final class InternalBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "lithium"
    private weak var browser: Browser?

    init(browser: Browser) {
        self.browser = browser
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == Internal.scheme,
              let browser,
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return (nil, "Not allowed") }
        let value = body["value"]
        let defaults = UserDefaults.standard

        switch action {
        case "state": break
        case "setSidebarStyle":
            if let style = (value as? String).flatMap(SidebarStyle.init(rawValue:)) { defaults.set(style.rawValue, forKey: Preference.sidebarStyle) }
        case "setSidebarColor":
            if let hex = value as? String, hex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil {
                defaults.set(hex.uppercased(), forKey: Preference.sidebarColor)
            }
        case "setWebsiteFont":
            PageStyle.usesDMSansEverywhere = value as? Bool ?? true
        case "setSearchEngine":
            if let engine = (value as? String).flatMap(SearchEngine.init(rawValue:)) { browser.setSearchEngine(engine) }
        case "updateFilters":
            browser.privacy.updateFiltersNow()
        case "enableProtections":
            if let host = value as? String { browser.privacy.setEnabled(true, for: URL(string: "https://\(host)/")) }
        case "setPermission":
            if let entry = value as? [String: String], let host = entry["host"],
               let kind = entry["kind"].flatMap(PermissionKind.init(rawValue:)) {
                browser.permissions.set(entry["decision"].flatMap(PermissionDecision.init(rawValue:)), for: kind, host: host)
            }
        case "setTidyTitles":
            browser.tidyTitles.isEnabled = value as? Bool ?? true
            if browser.tidyTitles.isEnabled {
                browser.tidyTitles.prepare()
                browser.tabs.forEach(browser.tidyTitles.update)
            }
        case "setSummaries":
            browser.summaries.isEnabled = value as? Bool ?? true
        case "setSummaryLanguage":
            let code = value as? String ?? ""
            let known = browser.summaries.languageChoices.languages.contains { $0.code == code }
            browser.summaries.language = known ? code : nil
        case "setSponsorBlock":
            browser.sponsorBlock.isEnabled = value as? Bool ?? true
        case "setSegmentAction":
            if let entry = value as? [String: String],
               let category = entry["category"].flatMap(SegmentCategory.init(rawValue:)),
               let action = entry["action"].flatMap(SegmentAction.init(rawValue:)) {
                browser.sponsorBlock.setAction(action, for: category)
            }
        case "clearHistory":
            browser.history.clear()
            return (visits(browser, matching: ""), nil)
        case "history":
            return (visits(browser, matching: value as? String ?? ""), nil)
        case "deleteVisit":
            if let id = value as? Int64 ?? (value as? NSNumber)?.int64Value { browser.history.delete(id: id) }
            return (nil, nil)
        default:
            return (nil, "Unknown action")
        }
        return (state(browser), nil)
    }

    private func visits(_ browser: Browser, matching query: String) -> [[String: Any]] {
        browser.history.visits(matching: query).map {
            ["id": $0.id, "url": $0.url.absoluteString, "title": $0.title, "time": $0.date.timeIntervalSince1970 * 1000]
        }
    }

    private func state(_ browser: Browser) -> [String: Any] {
        let defaults = UserDefaults.standard
        let info = Bundle.main.infoDictionary ?? [:]
        let safari = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        return [
            "appearance": [
                "sidebarStyle": defaults.string(forKey: Preference.sidebarStyle) ?? SidebarStyle.solid.rawValue,
                "sidebarColor": defaults.string(forKey: Preference.sidebarColor) ?? Theme.defaultSidebarHex,
                "defaultColor": Theme.defaultSidebarHex,
                "websiteFont": PageStyle.usesDMSansEverywhere,
            ],
            "search": [
                "engine": SearchEngine.current.rawValue,
                "engines": SearchEngine.allCases.map { ["id": $0.rawValue, "name": $0.name, "host": $0.home.host() ?? ""] },
            ],
            "protections": [
                "ruleCount": browser.privacy.ruleCount,
                "updated": browser.privacy.filtersUpdated.map { $0.timeIntervalSince1970 * 1000 } ?? 0,
                "updating": browser.privacy.isUpdatingFilters,
                "disabledHosts": browser.privacy.disabledHosts.sorted(),
            ],
            "permissions": browser.permissions.decisions.keys.sorted().map { host in
                var entry: [String: String] = ["host": host]
                for (kind, decision) in browser.permissions.decisions[host] ?? [:] { entry[kind.rawValue] = decision.rawValue }
                return entry
            },
            "max": [
                "tidyTitles": browser.tidyTitles.isEnabled,
                "summaries": browser.summaries.isEnabled,
                "summaryLanguage": browser.summaries.language ?? "",
                "summarySystemLanguage": browser.summaries.languageChoices.system,
                "summaryLanguages": browser.summaries.languageChoices.languages.map { ["code": $0.code, "name": $0.name] },
                "modelAvailable": browser.tidyTitles.modelStatus.available,
                "modelMessage": browser.tidyTitles.modelStatus.message,
            ],
            "sponsorBlock": [
                "enabled": browser.sponsorBlock.isEnabled,
                "categories": SegmentCategory.allCases.map {
                    ["id": $0.rawValue, "name": $0.label, "hint": $0.hint, "color": $0.color, "action": browser.sponsorBlock.actions[$0]?.rawValue ?? ""]
                },
            ],
            "about": [
                "version": info["CFBundleShortVersionString"] as? String ?? "dev",
                "safari": safari?["CFBundleShortVersionString"] as? String ?? "",
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            ],
        ]
    }
}
