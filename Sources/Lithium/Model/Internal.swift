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
    static let agentsURL = URL(string: "lithium://agents")!

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

    /// Types the system doesn't name.
    private static let mimeTypes = ["woff2": "font/woff2"]

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, fileExtension: String) {
        let type = Self.mimeTypes[fileExtension] ?? UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
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
        case ("agents", nil): bundle.url(forResource: "agents", withExtension: "html", subdirectory: "Pages")
        case (_, "style.css"): bundle.url(forResource: "lithium", withExtension: "css", subdirectory: "Pages")
        case (_, "pages.js"): bundle.url(forResource: "pages", withExtension: "js", subdirectory: "Pages")
        case (_, "font"): bundle.url(forResource: "DMSans", withExtension: "woff2")
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
        case "setSidebarReveal":
            if let reveal = (value as? String).flatMap(SidebarReveal.init(rawValue:)) { defaults.set(reveal.rawValue, forKey: Preference.sidebarReveal) }
        case "setMiniPlayer":
            defaults.set(value as? Bool ?? true, forKey: Preference.miniPlayer)
        case "setTabUsage":
            defaults.set(value as? Bool ?? true, forKey: Preference.tabUsage)
        case "setSidebarColor":
            if let hex = Self.hex(value) { defaults.set(hex, forKey: Preference.sidebarColor) }
        case "setStartBackground":
            guard let kind = (value as? String).flatMap(StartBackground.init(rawValue:)) else { break }
            if kind == .image, StartImage.current == nil {
                _ = await StartImage.choose()
            } else {
                defaults.set(kind.rawValue, forKey: Preference.startBackground)
                if !kind.showsPicture { StartPictures.forget() }
            }
        case "setStartColor":
            if let hex = Self.hex(value) { defaults.set(hex, forKey: Preference.startColor) }
        case "setStartGradient":
            if let colors = value as? [String: Any], let from = Self.hex(colors["from"]), let to = Self.hex(colors["to"]) {
                defaults.set(from, forKey: Preference.startGradientFrom)
                defaults.set(to, forKey: Preference.startGradientTo)
            }
        case "chooseStartImage":
            _ = await StartImage.choose()
        case "setWebsiteFont":
            PageStyle.usesDMSansEverywhere = value as? Bool ?? true
        case "setSiteFont":
            // Typed in by the user: a bare domain, or anything with one in it.
            guard let entry = value as? [String: Any], let text = (entry["site"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let host = URL(string: text.contains("://") ? text : "https://\(text)")?.host()?.lowercased(),
                  !host.isEmpty, !host.contains(" ") else { return (nil, "No site") }
            PageStyle.setKeepsSiteFont(entry["keep"] as? Bool ?? true, for: host)
        case "setSearchEngine":
            if let engine = (value as? String).flatMap(SearchEngine.init(rawValue:)) { defaults.set(engine.rawValue, forKey: SearchEngine.preferenceKey) }
        case "updateFilters":
            browser.privacy.updateFiltersNow()
        case "enableProtections":
            if let host = value as? String { browser.setProtections(true, host: host) }
        case "setPermission":
            if let entry = value as? [String: String], let host = entry["host"],
               let kind = entry["kind"].flatMap(PermissionKind.init(rawValue:)) {
                browser.permissions.set(entry["decision"].flatMap(PermissionDecision.init(rawValue:)), for: kind, host: host)
            }
        case "removeAppLink":
            // Asks again next time: "Always allow" is all that is remembered.
            if let entry = value as? [String: String], let host = entry["host"], let scheme = entry["scheme"] {
                browser.appLinks.set(false, scheme: scheme, host: host)
            }
        case "site", "clearSiteData":
            guard let host = value as? String, !host.isEmpty else { return (nil, "No site") }
            let info = SiteInfo(host: host)
            await info.load()
            if action == "clearSiteData" {
                await info.clear()
                // Its open pages would go on without the data they expect; private tabs keep theirs.
                browser.tabs.filter { !$0.isAsleep && !$0.isEphemeral && SiteInfo.registrable($0.url?.host() ?? "") == info.site }.forEach { browser.navigate($0, .reload) }
            }
            return (["host": host, "cookies": info.cookieCount ?? 0, "hasData": info.hasData], nil)
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
        case "setAgentAccess":
            await browser.setAgentAccess(value as? Bool ?? false)
        case "resetAgentToken":
            browser.agent?.resetToken()
        case "allowAgents":
            browser.agent?.allowAgain()
        case "openAgentLog":
            browser.openAgentLog()
        case "setAgentCaptureBodies":
            defaults.set(value as? Bool ?? false, forKey: Preference.agentCaptureBodies)
        case "setAgentRunScripts":
            defaults.set(value as? Bool ?? false, forKey: Preference.agentRunScripts)
        case "setDeveloperTools":
            browser.developerTools = value as? Bool ?? true
        case "copyAgentSetup":
            guard let text = value as? String else { return (nil, "No text") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return (nil, nil)
        case "agentLog":
            // As JSON text: the entries are `JSONValue`s, which don't cross to the page as they are.
            let entries = await agentLog(browser).entries(limit: Self.agentLogPageLength)
            return (String(decoding: JSONValue.array(entries).encoded(), as: UTF8.self), nil)
        case "clearAgentLog":
            browser.agent?.clearRecentLog()
            await agentLog(browser).clear()
            return ("[]", nil)
        case "exportAgentLog":
            return (await exportAgentLog(browser, from: message.webView?.window), nil)
        case "setExtensionEnabled":
            if let entry = value as? [String: Any], let id = entry["id"] as? String {
                await browser.extensions.setEnabled(entry["enabled"] as? Bool ?? true, id: id)
            }
        case "removeExtension":
            if let id = value as? String { await browser.extensions.remove(id: id) }
        case "openExtensionOptions":
            if let id = value as? String { browser.extensions.openOptions(id: id) }
        case "openWebStore":
            browser.newTab(url: URL(string: "https://\(ChromeWebStore.host)/category/extensions")!)
        case "clearHistory":
            await browser.history.clear()
            return (await visits(browser, matching: ""), nil)
        case "history":
            return (await visits(browser, matching: value as? String ?? ""), nil)
        case "deleteVisit":
            if let id = value as? Int64 ?? (value as? NSNumber)?.int64Value { browser.history.delete(id: id) }
            return (nil, nil)
        default:
            return (nil, "Unknown action")
        }
        return (state(browser), nil)
    }

    /// A "#RRGGBB" color from a page, uppercased; nil for anything else.
    private static func hex(_ value: Any?) -> String? {
        guard let hex = value as? String, hex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { return nil }
        return hex.uppercased()
    }

    private static func dataURL(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    static let agentLogPageLength = 500

    /// The hub's while access is on, so the page never writes over a line being added.
    private func agentLog(_ browser: Browser) -> AgentLog {
        browser.agent?.log ?? AgentLog(folder: AgentLog.folder)
    }

    /// Saves the whole log where the user picks; true once written.
    private func exportAgentLog(_ browser: Browser, from window: NSWindow?) async -> Bool {
        let data = await agentLog(browser).export()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
        panel.directoryURL = .downloadsDirectory
        panel.nameFieldStringValue = "Lithium agent log \(Date.now.formatted(.iso8601.year().month().day())).jsonl"
        let response = if let window { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        guard response == .OK, let url = panel.url else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// Read off the main thread; nil for a query the page already replaced with a newer one.
    private func visits(_ browser: Browser, matching query: String) async -> [[String: Any]]? {
        await browser.history.visitsInBackground(matching: query)?.map {
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
                "sidebarReveal": defaults.string(forKey: Preference.sidebarReveal) ?? SidebarReveal.normal.rawValue,
                "miniPlayer": NowPlaying.isEnabled,
                "tabUsage": defaults.object(forKey: Preference.tabUsage) as? Bool ?? true,
                "websiteFont": PageStyle.usesDMSansEverywhere,
                "siteFontDomains": PageStyle.siteFontDomains,
                "startPage": [
                    "background": defaults.string(forKey: Preference.startBackground) ?? StartBackground.lithium.rawValue,
                    "color": defaults.string(forKey: Preference.startColor) ?? StartBackground.defaultColor,
                    "gradientFrom": defaults.string(forKey: Preference.startGradientFrom) ?? StartBackground.defaultGradient.0,
                    "gradientTo": defaults.string(forKey: Preference.startGradientTo) ?? StartBackground.defaultGradient.1,
                    "hasImage": StartImage.current != nil,
                ] as [String: Any],
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
            "appLinks": browser.appLinks.allowed.keys.sorted().flatMap { host in
                (browser.appLinks.allowed[host] ?? []).sorted().map { scheme in
                    let app = URL(string: "\(scheme):").flatMap(browser.appLinks.appOpening)
                    return ["host": host, "scheme": scheme, "app": app.map(AppLinks.name(ofApp:)) ?? ""]
                }
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
            "agents": [
                "enabled": browser.agent != nil,
                "stopped": browser.agent?.state == .stopped,
                "status": AgentStatus.text(browser.agent),
                "url": browser.agent?.url ?? "",
                "captureBodies": defaults.bool(forKey: Preference.agentCaptureBodies),
                "runScripts": defaults.bool(forKey: Preference.agentRunScripts),
                // Beside Lithium's own executable: Contents/MacOS in the app, the build folder in development.
                "bridge": Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "lithium-mcp").path ?? "",
            ] as [String: Any],
            "advanced": ["developerTools": browser.developerTools],
            "extensions": browser.extensions.installed.map { entry in
                let context = browser.extensions.contexts[entry.id]
                return [
                    "id": entry.id, "name": entry.name, "version": entry.version, "enabled": entry.isEnabled,
                    "hasOptions": context?.optionsPageURL != nil,
                    "icon": context?.webExtension.icon(for: CGSize(width: 32, height: 32)).flatMap(Self.dataURL) ?? "",
                ] as [String: Any]
            },
            "about": [
                "version": info["CFBundleShortVersionString"] as? String ?? "dev",
                "safari": safari?["CFBundleShortVersionString"] as? String ?? "",
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            ],
        ]
    }
}
