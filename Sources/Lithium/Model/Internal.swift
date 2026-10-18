import AppKit
import UniformTypeIdentifiers
import WebKit

/// Lithium's own pages (`lithium://settings`, `lithium://history`), served from the app bundle.
/// Since they can change settings: only the user or the app can open one (see `Tab`'s navigation
/// policy); files are served only to `lithium://` documents, so a website cannot probe for Lithium;
/// the message bridge exists only while a tab shows one, and answers its main frame only.
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

    private static let mimeTypes = ["woff2": "font/woff2"]

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, fileExtension: String) {
        let type = Self.mimeTypes[fileExtension] ?? UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": type,
            // Masks and fonts are fetched with CORS across lithium:// hosts; only lithium:// documents get here.
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
        guard let file, var data = try? Data(contentsOf: file) else { return nil }
        if file.lastPathComponent == "lithium.css" { data.append(Data(interfaceFontCSS(FontChoice.shared.interface).utf8)) }
        return (data, file.pathExtension)
    }

    /// The interface font for Lithium's pages; nothing for DM Sans, which the style sheet already names.
    static func interfaceFontCSS(_ family: String?) -> String {
        guard let family else { return "" }
        return #"body { font-family: "\#(family.replacingOccurrences(of: "\"", with: ""))", "DM Sans", -apple-system, sans-serif; }"#
    }
}

/// The internal pages' line to the app. Settings calls return the full settings state.
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
        case "pickColor":
            // Answers at once; each color picked goes to the page's `colorPicked` as it comes.
            guard let entry = value as? [String: Any], let webView = message.webView, let hex = Self.hex(entry["color"]),
                  let x = entry["x"] as? Double, let y = entry["y"] as? Double,
                  let width = entry["width"] as? Double, let height = entry["height"] as? Double else { return (nil, "No swatch") }
            let viewport = PageViewport(w: 0, h: 0, sx: 0, sy: 0, pw: 0, ph: 0, dpr: 1, vx: entry["offsetLeft"] as? Double ?? 0,
                                        vy: entry["offsetTop"] as? Double ?? 0, vs: entry["scale"] as? Double ?? 1)
            browser.colorPicker.pick(css: CGRect(x: x, y: y, width: width, height: height), viewport: viewport, hex: hex, in: webView) { [weak webView] hex in
                // Not into a page the tab has since left.
                guard let webView, Internal.isInternal(webView.url) else { return }
                webView.callAsyncJavaScript("colorPicked(hex)", arguments: ["hex": hex], in: nil, in: .page)
            }
            return (nil, nil)
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
            browser.changePageFont { PageStyle.usesFontEverywhere = value as? Bool ?? true }
        case "fonts":
            return (FontChoice.families(), nil)
        case "setInterfaceFont":
            browser.changePageFont { FontChoice.shared.setInterface(value as? String) }
        case "setWebsiteFamily":
            browser.changePageFont { FontChoice.shared.setWebsite(value as? String) }
        case "setReaderButton":
            browser.setReaderButton(value as? Bool ?? true)
        case "setTranslateOffer":
            browser.translator.setOffers(value as? Bool ?? true)
        case "removeTranslateLanguage":
            if let code = value as? String { browser.translator.setAlwaysTranslates(false, Locale.Language(identifier: code), privateSession: nil) }
        case "removeTranslateSite":
            if let site = value as? String { browser.translator.setNeverTranslates(false, site: site, privateSession: nil) }
        case "setSiteFont":
            guard let entry = value as? [String: Any], let text = entry["site"] as? String,
                  let host = Self.siteFontHost(text) else { return (nil, "No site") }
            browser.changePageFont { PageStyle.setKeepsSiteFont(entry["keep"] as? Bool ?? true, for: host) }
        case "setSearchEngine":
            if let engine = (value as? String).flatMap(SearchEngine.init(rawValue:)) { defaults.set(engine.rawValue, forKey: SearchEngine.preferenceKey) }
        case "updateFilters":
            browser.privacy.updateFiltersNow()
        case "filterLists":
            return (await filterLists(browser), nil)
        case "setFilterList":
            guard let entry = value as? [String: Any], let id = entry["id"] as? String else { return (nil, "No list") }
            let error = await browser.privacy.setFilterList(id, enabled: entry["enabled"] as? Bool ?? true)
            return (await filterLists(browser, error: error), nil)
        case "addFilterList":
            let error = await browser.privacy.addFilterList(value as? String ?? "")
            return (await filterLists(browser, error: error), nil)
        case "setMyFilters":
            let error = await browser.privacy.setMyFilters(value as? String ?? "")
            return (await filterLists(browser, error: error), nil)
        case "enableProtections":
            // A site turned off in a separate space comes with that space's id.
            if let host = value as? String {
                browser.setProtections(true, host: host)
            } else if let entry = value as? [String: String], let host = entry["host"], let space = entry["space"].flatMap(UUID.init(uuidString:)) {
                browser.setProtections(true, host: host, space: space)
            }
        case "removeAllowedPage":
            // Open pages of the site keep theirs until their next load.
            if let host = value as? String { browser.privacy.removeAllowedPages(host: host) }
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
            // Spaces that keep their own cookies hold the site's data apart from the default store.
            let infos = browser.siteDataStores.map { SiteInfo(host: host, store: $0) }
            for info in infos { await info.load() }
            if action == "clearSiteData" {
                await browser.clearData(infos).value
                // Its open pages would go on without the data they expect; private tabs keep theirs.
                let site = SiteInfo.registrable(host)
                browser.tabs.filter { !$0.isAsleep && !$0.isEphemeral && SiteInfo.registrable($0.url?.host() ?? "") == site }.forEach { browser.navigate($0, .reload) }
            }
            return (["host": host, "cookies": infos.reduce(0) { $0 + ($1.cookieCount ?? 0) }, "hasData": infos.contains(where: \.hasData)], nil)
        case "setTidyTitles":
            browser.tidyTitles.isEnabled = value as? Bool ?? true
            if browser.tidyTitles.isEnabled {
                browser.tidyTitles.prepare()
                browser.tabs.forEach { browser.tidyTitles.update($0) }
            }
        case "setTidyDownloads":
            Downloads.shared.tidy.isEnabled = value as? Bool ?? false
        case "setSummaries":
            browser.setSummaries(enabled: value as? Bool ?? true)
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
        case "setQuickLinks":
            browser.quickLinks.isEnabled = value as? Bool ?? false
        case "setEnergySaving":
            if let mode = (value as? String).flatMap(EnergySaving.init(rawValue:)) { browser.energy.mode = mode }
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
        case "updateExtension":
            if let id = value as? String { await updateExtension(id, in: browser, window: message.webView?.window) }
        case "openExtensionOptions":
            if let id = value as? String { browser.extensions.openOptions(id: id) }
        case "openWebStore":
            browser.newTab(url: URL(string: "https://\(ChromeWebStore.host)/category/extensions")!)
        case "openPasswords":
            Passwords.open()
        case "passwords", "setPasswordOffers", "setPasswordUnlock", "revealPassword", "copyPassword", "savePasswordEdit",
             "deletePassword", "removeNeverSaved", "importPasswords", "exportPasswords":
            // Their own state, apart from the settings': it reads the vault.
            return await browser.passwords.answerSettings(action, value, window: message.webView?.window)
        case "clearHistory":
            await browser.clearHistory()
            return (await visits(browser, matching: ""), nil)
        case "history":
            // A search, or the next page of one: `{ query, before }`, the id of the last visit shown.
            let more = value as? [String: Any]
            let before = more?["before"] as? Int64 ?? (more?["before"] as? NSNumber)?.int64Value
            return (await visits(browser, matching: more?["query"] as? String ?? value as? String ?? "", before: before), nil)
        case "deleteVisit":
            if let id = value as? Int64 ?? (value as? NSNumber)?.int64Value { browser.history.delete(id: id) }
            return (nil, nil)
        default:
            return (nil, "Unknown action")
        }
        return (state(browser), nil)
    }

    /// The host of a site typed in, or sent back by a Remove button. The list shows an IPv6
    /// address bare, which reads as no host once in a URL without its brackets.
    static func siteFontHost(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        var address = in6_addr()
        if inet_pton(AF_INET6, text, &address) == 1 { return text.lowercased() }
        guard let host = URL(string: text.contains("://") ? text : "https://\(text)")?.host()?.lowercased(),
              !host.isEmpty, !host.contains(" ") else { return nil }
        return host
    }

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
    /// `history.html` asks for the next page once it has shown a full one.
    static let historyPageLength = 500

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
        panel.nameFieldStringValue = AgentLog.exportName(for: .now)
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

    /// Shows what the refused version can do, as adding it from the store does, before it replaces
    /// the installed one.
    private func updateExtension(_ id: String, in browser: Browser, window: NSWindow?) async {
        let name = browser.extensions.installed.first { $0.id == id }?.name ?? id
        let present = { @MainActor (alert: NSAlert) async -> NSApplication.ModalResponse in
            // Closed while it downloaded, the window would never show the sheet nor end the update.
            if let window, window.isVisible { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
        do {
            try await browser.extensions.updateRefused(id: id) { warnings in
                let alert = NSAlert()
                alert.messageText = "Update “\(name)”?"
                alert.informativeText = warnings.isEmpty ? "It asks for more access than the installed version." : "It can:\n" + warnings.map { "• \($0)" }.joined(separator: "\n")
                alert.addButton(withTitle: "Update")
                alert.addButton(withTitle: "Cancel")
                return await present(alert) == .alertFirstButtonReturn
            }
        } catch ChromeWebStore.PackageError.moreAccess {
            // Declined: the installed version stays, and Settings still offers the newer one.
        } catch {
            _ = await present(NSAlert(error: error))
        }
    }

    /// Read off the main thread; nil for a query the page already replaced with a newer one.
    private func visits(_ browser: Browser, matching query: String, before: Int64? = nil) async -> [[String: Any]]? {
        await browser.history.visitsInBackground(matching: query, before: before, limit: Self.historyPageLength)?.map {
            ["id": $0.id, "url": $0.url.absoluteString, "title": $0.title, "time": $0.date.timeIntervalSince1970 * 1000]
        }
    }

    /// The Filter lists page, apart from the settings state: it reads lists from disk, which the
    /// state, sent many times a second while a color is dragged, must not.
    private func filterLists(_ browser: Browser, error: String? = nil) async -> [String: Any] {
        let privacy = browser.privacy
        let choices = privacy.filterChoices
        let counts = await privacy.filterListRules()
        let failed = Set(privacy.failedFilterLists)
        let updated = privacy.filtersUpdated.map { $0.timeIntervalSince1970 * 1000 } ?? 0
        let entry = { (info: FilterListInfo, enabled: Bool, rules: Int?, updated: Double, failed: Bool, removable: Bool) -> [String: Any] in
            ["id": info.id, "name": info.name, "summary": info.summary, "homepage": info.homepage?.absoluteString ?? "",
             "enabled": enabled, "rules": rules ?? -1, "updated": updated, "failed": failed, "removable": removable]
        }
        let copy = { (id: String) in choices.copies[id] }
        var sections: [(title: String, lists: [[String: Any]])] = []
        func add(_ title: String, _ list: [String: Any]) {
            if let index = sections.firstIndex(where: { $0.title == title }) { sections[index].lists.append(list) } else { sections.append((title, [list])) }
        }
        for info in FilterLists.shipped {
            add(info.section, entry(info, !choices.off.contains(info.id), counts[info.id], updated, failed.contains(info.id), false))
        }
        for info in FilterLists.catalog {
            let on = choices.on.contains(info.id)
            add(info.section, entry(info, on, on ? copy(info.id)?.rules : nil, (copy(info.id)?.updated.timeIntervalSince1970 ?? 0) * 1000, copy(info.id)?.failed ?? false, false))
        }
        for url in choices.added {
            let id = FilterLists.id(of: url)
            let info = FilterListInfo(id: id, name: url.host() ?? url.absoluteString, summary: url.absoluteString, section: "Added by you", homepage: url)
            add(info.section, entry(info, true, copy(id)?.rules, (copy(id)?.updated.timeIntervalSince1970 ?? 0) * 1000, copy(id)?.failed ?? false, true))
        }
        let text = privacy.myFilters
        let problems = await Task.detached(priority: .userInitiated) { FilterLists.problems(in: text) }.value
        var reply: [String: Any] = [
            "sections": sections.map { ["title": $0.title, "lists": $0.lists] as [String: Any] },
            "myFilters": text,
            "problems": problems.map { ["line": $0.line, "text": $0.text, "message": $0.message] as [String: Any] },
        ]
        for (key, message) in Self.filterMessages(failed: error, notice: privacy.filterError) { reply[key] = message }
        return reply
    }

    /// The action's own failure in `failed`, as `filterError` may be about another list. The page
    /// shows `error`: both, so one doesn't hide the other.
    static func filterMessages(failed: String?, notice: String?) -> [String: String] {
        ["error": [failed, notice].compactMap { $0 }.joined(separator: " "), "failed": failed ?? ""]
    }

    /// Read once: the state is sent many times a second while a color is dragged, and the WebKit
    /// Lithium runs is the one it launched with, whatever Safari update comes after.
    private static let safariVersion = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")?["CFBundleShortVersionString"] as? String ?? ""
    private var icons: [String: String] = [:]

    /// A turned-off extension has no context but keeps its icon (`Extensions.icon`).
    private func icon(of entry: InstalledExtension, in extensions: Extensions) -> String {
        let key = "\(entry.id) \(entry.version)"
        if let icon = icons[key] { return icon }
        let icon = extensions.icon(entry.id).flatMap(Self.dataURL) ?? ""
        icons[key] = icon
        return icon
    }

    private func state(_ browser: Browser) -> [String: Any] {
        let defaults = UserDefaults.standard
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "appearance": [
                "sidebarStyle": defaults.string(forKey: Preference.sidebarStyle) ?? SidebarStyle.solid.rawValue,
                "sidebarColor": defaults.string(forKey: Preference.sidebarColor) ?? Theme.defaultSidebarHex,
                "defaultColor": Theme.defaultSidebarHex,
                "sidebarReveal": defaults.string(forKey: Preference.sidebarReveal) ?? SidebarReveal.normal.rawValue,
                "miniPlayer": NowPlaying.isEnabled,
                "tabUsage": defaults.object(forKey: Preference.tabUsage) as? Bool ?? true,
                "websiteFont": PageStyle.usesFontEverywhere,
                "interfaceFont": FontChoice.shared.interface ?? FontChoice.dmSans,
                // Empty while websites follow the interface font.
                "websiteFamily": FontChoice.shared.website ?? "",
                "websiteFontName": PageStyle.websiteFamily,
                "readerButton": ReaderMode.showsButton,
                "translateOffer": browser.translator.offers,
                "translateLanguages": browser.translator.alwaysLanguages.map { (code: $0, name: PageTranslator.name(of: Locale.Language(identifier: $0))) }
                    .sorted { $0.name < $1.name }.map { ["code": $0.code, "name": $0.name] },
                "translateSites": browser.translator.neverSites,
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
                "spaceDisabledHosts": browser.privacy.spaceDisabledHosts.compactMap { entry in
                    browser.spaces.first { $0.id == entry.space }.map { ["host": entry.host, "space": entry.space.uuidString, "spaceName": $0.name] }
                },
                "allowedPages": browser.privacy.allowedPages.keys.sorted(),
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
                "tidyDownloads": Downloads.shared.tidy.isEnabled,
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
            "advanced": [
                "developerTools": browser.developerTools, "quickLinks": browser.quickLinks.isEnabled,
                "energySaving": browser.energy.mode.rawValue,
            ] as [String: Any],
            "extensions": browser.extensions.installed.map { entry in
                let context = browser.extensions.contexts[entry.id]
                return [
                    "id": entry.id, "name": entry.name, "version": entry.version, "enabled": entry.isEnabled,
                    "hasOptions": context?.optionsPageURL != nil,
                    "icon": icon(of: entry, in: browser.extensions),
                    "refusedVersion": entry.refusedVersion ?? "",
                ] as [String: Any]
            },
            "about": [
                "version": info["CFBundleShortVersionString"] as? String ?? "dev",
                "safari": Self.safariVersion,
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            ],
        ]
    }
}
