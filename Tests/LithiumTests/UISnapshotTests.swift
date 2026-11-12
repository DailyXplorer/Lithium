import Foundation
import PDFKit
import SwiftUI
import Testing
import WebKit
@testable import Lithium

/// The shield panel and every settings section with sample values, for a look without launching
/// the app: `LITHIUM_SNAPSHOT_DIR=/tmp/shots ./scripts/test --filter UISnapshot`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] != nil, "Writes PNGs only when LITHIUM_SNAPSHOT_DIR is set"))
struct UISnapshotTests {
    private let directory = URL(filePath: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] ?? "/tmp")

    @Test func shieldSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let updated = DateComponents(calendar: .current, year: 2026, month: 10, day: 2).date
        for isOn in [true, false] {
            for isDark in [false, true] {
                let view = ShieldView(host: "youtube.com", isOn: .constant(isOn), updated: updated)
                let png = try render(view, isDark: isDark)
                try png.write(to: directory.appending(path: "shield-\(isOn ? "on" : "off")-\(isDark ? "dark" : "light").png"))
            }
        }
    }

    /// The PDF viewer's strip, for a PDF from the web and for a file on disk, which adds Show in Finder.
    @Test func pdfToolbarSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        document.insert(PDFPage(), at: 1)
        let data = try #require(document.dataRepresentation())
        for (name, url) in [("web", URL(string: "https://example.com/files/Annual%20report.pdf")!), ("local", URL(filePath: "/tmp/Annual report.pdf"))] {
            let reader = PDFReader(url: url)
            #expect(reader.open(data))
            for isDark in [false, true] {
                let toolbar = PDFToolbar(reader: reader, showsSidebar: .constant(true)).frame(width: 760)
                try render(toolbar, isDark: isDark).write(to: directory.appending(path: "pdf-toolbar-\(name)-\(isDark ? "dark" : "light").png"))
            }
        }
    }

    /// The space editor, for a new space (with its own cookies) and for one being edited.
    @Test func spaceEditorSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let work = Space(id: UUID(), name: "Work", color: Space.colors[1], icon: Phosphor.folder.rawValue, separatesData: true)
        for (name, isNew) in [("new", true), ("edit", false)] {
            for isDark in [false, true] {
                let editor = SpaceEditor(space: work, isNew: isNew, save: { _ in }, close: {})
                try render(editor, isDark: isDark).write(to: directory.appending(path: "space-editor-\(name)-\(isDark ? "dark" : "light").png"))
            }
        }
    }

    /// The space editor's icon picker with its catalog built, for a space with an icon and for one
    /// with an emoji saved by an earlier version (nothing picked).
    @Test func spaceIconPickerSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let catalog = SpaceIconCatalog.load()
        for (name, icon) in [("icons", "code"), ("saved-emoji", "🎮")] {
            for isDark in [false, true] {
                let picker = SpaceIconPicker(icon: .constant(icon), catalog: catalog)
                    .font(Theme.font(13))
                    .padding(14)
                    .frame(width: 252)
                try render(picker, isDark: isDark).write(to: directory.appending(path: "space-icon-picker-\(name)-\(isDark ? "dark" : "light").png"))
            }
        }
    }

    /// The foot of the sidebar with three spaces, the second shown, on its own color.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func spaceBarSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        SessionStore.save(Session())
        let browser = Browser()
        var work = browser.newSpaceDraft()
        work.name = "Work"
        browser.addSpace(work)
        browser.addSpace(browser.newSpaceDraft())
        browser.commandWindow.switchToSpace(work.id)
        defer {
            browser.spaces.reversed().forEach { browser.deleteSpace($0.id) }
            SessionStore.save(Session())
        }
        for isDark in [false, true] {
            let palette = SidebarPalette(style: .solid, colorHex: isDark ? "#2B2D42" : work.color ?? Theme.defaultSidebarHex, scheme: isDark ? .dark : .light)
            let bar = SpaceBar()
                .environment(browser).environment(browser.windows[0])
                .environment(\.sidebarPalette, palette)
                .foregroundStyle(palette.ink)
                .frame(width: Layout.sidebarWidth - 20)
                .padding(10)
                .background(Color(hex: isDark ? "#2B2D42" : work.color ?? Theme.defaultSidebarHex))
            try render(bar, isDark: isDark).write(to: directory.appending(path: "space-bar-\(isDark ? "dark" : "light").png"))
        }
    }

    /// Three space buttons, the second current, on light, saturated, very dark, near-black and
    /// translucent sidebars.
    @Test func spaceButtonSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let icons: [Phosphor] = [.globe, .folder, .code]
        let spaces = icons.map { Space(id: UUID(), name: $0.rawValue, color: nil, icon: $0.rawValue, separatesData: false) }
        let backdrops = [("light", SidebarStyle.solid, Theme.defaultSidebarHex), ("red", .solid, "#C0392B"), ("very-dark", .solid, "#1E1E24"),
                         ("near-black", .solid, "#0A0A14"), ("translucent-light", .translucent, "#E7E5EA"), ("translucent-dark", .translucent, "#2C2B30")]
        for (name, style, hex) in backdrops {
            let isDark = name.hasSuffix("dark") || name == "near-black"
            let palette = SidebarPalette(style: style, colorHex: hex, scheme: isDark ? .dark : .light)
            let bar = HStack(spacing: 2) {
                ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                    SpaceButton(space: space, number: index + 1, isCurrent: index == 1) {}
                }
                Spacer(minLength: 0)
            }
            .environment(\.sidebarPalette, palette)
            .foregroundStyle(palette.ink)
            .frame(width: Layout.sidebarWidth - 20)
            .padding(10)
            .background(Color(hex: hex))
            try render(bar, isDark: isDark).write(to: directory.appending(path: "space-buttons-\(name).png"))
        }
    }

    /// A download Lithium named, the site's name crossed out under it, with Use original name.
    @Test func renamedDownloadSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let item = DownloadItem(filename: "document(3).pdf", size: 48_213)
        item.setDestination(URL(filePath: "/tmp/Invoice October 2026.pdf"), renamedFrom: "document(3).pdf")
        item.finish(.finished)
        for isDark in [false, true] {
            let row = DownloadRow(item: item).font(Theme.font(13)).frame(width: 324).padding(8)
            try render(row, isDark: isDark).write(to: directory.appending(path: "download-renamed-\(isDark ? "dark" : "light").png"))
        }
    }

    @Test func settingsSnapshots() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = WKWebViewConfiguration()
        InternalSchemeHandler.shared.install(on: configuration)
        configuration.userContentController.addScriptMessageHandler(SampleBridge(), contentWorld: .page, name: InternalBridge.name)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 700), configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 960, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        defer { window.contentView = nil }
        webView.load(URLRequest(url: URL(string: "lithium://settings#appearance")!))
        #expect(await poll(15) { (try? await webView.evaluateJavaScript("document.querySelector('#version')?.textContent ?? ''") as? String)?.isEmpty == false })
        // A window never shown doesn't run the page's entrance animation, which starts transparent,
        // nor the switches' transitions, which stay at their start.
        _ = try await webView.evaluateJavaScript("document.head.append(Object.assign(document.createElement('style'), { textContent: '*, *::after { animation: none !important; transition: none !important }' }))")

        let sections: [(name: String, hash: String, script: String?)] = [
            ("appearance", "appearance", nil), ("search", "search", nil), ("privacy", "privacy", nil),
            ("privacy-details", "privacy", "document.querySelectorAll('details').forEach((d) => d.open = true)"),
            ("filters", "filters", nil),
            ("extensions", "extensions", nil),
            ("passwords", "passwords", nil),
            ("passwords-expanded", "passwords", "$('#password-more').click(); $('#never-saved-section').open = true"),
            ("max", "max", nil), ("agents", "agents", nil), ("permissions", "permissions", nil), ("advanced", "advanced", nil),
            ("site", "site/www.example.com", nil), ("about", "about", nil),
            // The segmented controls at the narrowest a tab gets: the smallest window with the sidebar.
            ("appearance-narrow", "appearance", nil), ("advanced-narrow", "advanced", nil),
            // Last: the page keeps the interface font it picked.
            ("appearance-interface-font", "appearance", "render({ ...lastState, appearance: { ...lastState.appearance, interfaceFont: 'Avenir Next' } })"),
        ]
        for section in sections {
            let width = section.name.hasSuffix("-narrow") ? 760 - Layout.sidebarWidth - Layout.margin : 960
            _ = try await webView.evaluateJavaScript("location.hash = '\(section.hash)'; \(section.script ?? ""); 0")
            try await Task.sleep(for: .milliseconds(100))
            // A window never shown keeps the sticky sidebar's old paint; redrawing it shows the current section.
            _ = try await webView.evaluateJavaScript("document.querySelector('nav').style.display = 'none'; document.body.offsetHeight; document.querySelector('nav').style.display = ''; 0")
            for isDark in [false, true] {
                window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
                window.setFrame(NSRect(x: -5000, y: 0, width: width, height: 700), display: false)
                try await Task.sleep(for: .milliseconds(400))
                let height = try await webView.evaluateJavaScript("document.querySelector('main').scrollHeight") as? Double ?? 700
                window.setFrame(NSRect(x: -5000, y: 0, width: width, height: max(700, height)), display: false)
                try await Task.sleep(for: .milliseconds(300))
                let image = try await webView.takeSnapshot(configuration: nil)
                let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
                try png.write(to: directory.appending(path: "settings-\(section.name)-\(isDark ? "dark" : "light").png"))
            }
        }
    }

    /// The indicator's panel with a tab where a connected agent met a challenge only the user can
    /// pass. Access is on and listening, as it is whenever an agent can meet one.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func agentPanelSnapshots() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        let browser = Browser()
        await browser.setAgentAccess(true)
        let client = try await AgentTabsTests.Client(browser: browser)
        let tab = browser.newTab()
        tab.customTitle = "Sign in · Shop"
        client.hub.agentTab(for: tab)?.challenge = AgentChallenge(kind: "cloudflare", page: true)
        for isDark in [false, true] {
            let png = try render(AgentPanel(agent: client.hub).environment(browser).environment(browser.windows[0]), isDark: isDark)
            try png.write(to: directory.appending(path: "agent-panel-challenge-\(isDark ? "dark" : "light").png"))
        }
        browser.tabs.forEach(browser.close)
        await browser.setAgentAccess(false)
    }

    /// What the user sees over the page while an agent acts in it: border, caption and pointer
    /// dot; and the tab's badge with its ring.
    @Test func agentActingSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let acting = AgentActing(session: "x", caption: "Clicking “Place order”", pointer: CGPoint(x: 528, y: 127))
        let page = VStack(alignment: .leading, spacing: 14) {
            Text("Your basket").font(Theme.font(22, .semibold))
            Text("2 items · €42.00").foregroundStyle(.secondary)
            Button("Place order") {}.controlSize(.large).padding(.leading, 440)
            Spacer()
        }
        .padding(40)
        .frame(width: 800, height: 420, alignment: .topLeading)
        .overlay { AgentActingOverlay(acting: acting) }
        let badge = Favicon(image: nil, fallback: "shop.example", size: 16)
            .frame(width: 16, height: 16)
            .overlay(alignment: .bottomTrailing) { AgentBadge(isActing: true) }
            .padding(12)
        for isDark in [false, true] {
            try render(page, isDark: isDark).write(to: directory.appending(path: "agent-acting-\(isDark ? "dark" : "light").png"))
            try render(badge, isDark: isDark).write(to: directory.appending(path: "agent-badge-acting-\(isDark ? "dark" : "light").png"))
        }
    }

    /// A private tab's row: the private badge at its end.
    @Test func privateTabSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let row = HStack(spacing: 8) {
            Favicon(image: nil, fallback: "shop.example", size: 16)
                .frame(width: 16, height: 16)
            Text("Checkout · Shop").lineLimit(1)
            Spacer(minLength: 0)
            PrivateTabBadge()
        }
        .font(Theme.font(13))
        .padding(.horizontal, 10)
        .frame(width: 240, height: 32)
        .padding(8)
        for isDark in [false, true] {
            try render(row, isDark: isDark).write(to: directory.appending(path: "private-tab-\(isDark ? "dark" : "light").png"))
        }
    }

    /// The address bar's list with two actions under the typed text, the first one selected.
    @Test func barActionSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let rows: [Suggestion] = [.search("exit"), .action(.exitSplitView), .action(.exitZenMode),
                                  .history(title: "Exit polls", url: URL(string: "https://news.example/exit-polls")!)]
        let list = VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                SuggestionRow(suggestion: row, isSelected: index == 1)
            }
        }
        .padding(6)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .font(Theme.font(13))
        .frame(width: 460)
        .padding(12)
        for isDark in [false, true] {
            try render(list, isDark: isDark).write(to: directory.appending(path: "bar-actions-\(isDark ? "dark" : "light").png"))
        }
    }

    /// The bar of a link's own window, on a secure page and on one that isn't.
    @Test func quickLinkBarSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        for (name, url, isSecure) in [("secure", "https://www.example.com/docs/start", true), ("insecure", "http://example.org/", false)] {
            let bar = QuickLinkBar(url: URL(string: url), isSecure: isSecure, onClose: {}, onMove: {})
                .font(Theme.font(13))
                .frame(width: 520)
            for isDark in [false, true] {
                try render(bar, isDark: isDark).write(to: directory.appending(path: "quick-link-bar-\(name)-\(isDark ? "dark" : "light").png"))
            }
        }
    }

    /// Zen mode's top bar as it peeks over the page, on the start page, solid and translucent.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func zenTopBarSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let browser = Browser()
        for style in SidebarStyle.allCases {
            for isDark in [false, true] {
                let palette = SidebarPalette(style: style, colorHex: Theme.defaultSidebarHex, scheme: isDark ? .dark : .light)
                let bar = ZenTopBar(style: style, colorHex: Theme.defaultSidebarHex)
                    .foregroundStyle(palette.ink)
                    .environment(\.sidebarPalette, palette)
                    .environment(browser).environment(browser.windows[0])
                    .font(Theme.font(13))
                    .frame(width: 1100)
                    .padding(.bottom, 16)
                try render(bar, isDark: isDark).write(to: directory.appending(path: "zen-top-bar-\(style.rawValue)-\(isDark ? "dark" : "light").png"))
            }
        }
    }

    /// The toolbar with agent access on, without an agent and with one connected (the robot shows
    /// only then), in a wide window and a narrow one.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func toolbarSnapshots() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        let browser = Browser()
        await browser.setAgentAccess(true)
        func shoot(_ name: String) throws {
            for width in [1100, 640] {
                for isDark in [false, true] {
                    let palette = SidebarPalette(style: .solid, colorHex: Theme.defaultSidebarHex, scheme: isDark ? .dark : .light)
                    let toolbar = ToolbarView()
                        .foregroundStyle(palette.ink)
                        .environment(\.sidebarPalette, palette)
                        .environment(browser).environment(browser.windows[0])
                        .font(Theme.font(13))
                        .frame(width: CGFloat(width))
                        .padding(.vertical, 8)
                    try render(toolbar, isDark: isDark).write(to: directory.appending(path: "toolbar-\(name)-\(width)-\(isDark ? "dark" : "light").png"))
                }
            }
        }
        try shoot("no-agent")
        _ = try await AgentTabsTests.Client(browser: browser)
        try shoot("agent")
        await browser.setAgentAccess(false)
    }

    /// The ⋯ menu's items for a web page, drawn as a list: a menu only draws once it is open.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func pageMenuSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        SessionStore.save(Session())
        let browser = Browser()
        let tab = browser.newTab(selecting: false)
        tab.restore(url: URL(string: "https://www.example.com/")!, title: "Example")
        defer {
            browser.close(tab, remembering: false)
            SessionStore.save(Session())
        }
        for isDark in [false, true] {
            let menu = VStack(alignment: .leading, spacing: 6) {
                PageMenuItems(tab: tab, panel: .constant(nil))
            }
            .buttonStyle(.plain)
            .font(Theme.font(13))
            .padding(12)
            .frame(width: 220, alignment: .leading)
            .environment(browser).environment(browser.windows[0])
            try render(menu, isDark: isDark).write(to: directory.appending(path: "page-menu-\(isDark ? "dark" : "light").png"))
        }
    }

    /// The lock's panel with its two switches, on and off, each one right-aligned in its row.
    @Test func siteInfoProtectionsSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        for isOn in [true, false] {
            for isDark in [false, true] {
                let panel = SiteInfoView(host: "www.youtube.com", favicon: nil, connection: .secure, certificate: .loading, cookieCount: 29, canClear: true, permissions: [:], protections: .constant(isOn), usesSiteFont: .constant(!isOn), showsCertificate: .constant(false))
                try render(panel, isDark: isDark).write(to: directory.appending(path: "site-info-protections-\(isOn ? "on" : "off")-\(isDark ? "dark" : "light").png"))
            }
        }
    }

    /// The translate popover offered, downloading, translated and failed, and the address bar's
    /// button in each state.
    @Test func translateSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let french = Locale.Language(identifier: "fr"), english = Locale.Language(identifier: "en")
        let states: [(name: String, status: TabTranslation.Status)] = [
            ("offered", .offered), ("downloading", .downloading), ("translated", .translated), ("failed", .failed("This page couldn’t be translated.")),
        ]
        for isDark in [false, true] {
            let scheme = isDark ? "dark" : "light"
            for state in states {
                let view = TranslateView(state: TabTranslation(source: french, target: english, status: state.status), site: "lemonde.fr",
                                         alwaysTranslates: .constant(state.status == .translated), neverTranslates: .constant(false))
                try render(view, isDark: isDark).write(to: directory.appending(path: "translate-\(state.name)-\(scheme).png"))
            }
            let buttons = HStack(spacing: 8) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in TranslateButtonLabel(status: state.status) }
            }
            .padding(8)
            try render(buttons, isDark: isDark).write(to: directory.appending(path: "translate-buttons-\(scheme).png"))
        }
    }

    /// The sidebar with two folders: one open with its tabs, the selected one among them, and one
    /// collapsed with its count; a tab outside folders below them.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func tabFolderSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        SessionStore.save(Session())
        PinStore.save([])
        let browser = Browser()
        defer {
            browser.tabs.forEach { browser.close($0, remembering: false) }
            SessionStore.save(Session())
        }
        func tab(_ title: String, _ host: String) -> Lithium.Tab {
            let tab = browser.newTab(selecting: false)
            tab.restore(url: URL(string: "https://\(host)/")!, title: title)
            return tab
        }
        _ = tab("Weather · Paris", "weather.example")
        let article = tab("How tab folders work", "news.example")
        // Selected, so without an address: a restored tab would wake and load its page.
        let docs = browser.newTab(selecting: false)
        docs.customTitle = "Design notes"
        let issue = tab("Issue tracker", "code.example")
        let work = browser.newFolder(with: issue)
        browser.renameFolder(work.id, to: "Work")
        browser.moveTab(docs, toFolder: work.id)
        let reading = browser.newFolder(with: article)
        browser.renameFolder(reading.id, to: "Reading")
        browser.toggleFolder(reading.id)
        browser.select(docs)
        for isDark in [false, true] {
            let hex = isDark ? "#2B2D42" : Theme.defaultSidebarHex
            let palette = SidebarPalette(style: .solid, colorHex: hex, scheme: isDark ? .dark : .light)
            let sidebar = SidebarView()
                .environment(browser).environment(browser.windows[0])
                .environment(\.sidebarPalette, palette)
                .foregroundStyle(palette.ink)
                .font(Theme.font(13))
                .frame(width: Layout.sidebarWidth, height: 400)
                .background(Color(hex: hex))
            try render(sidebar, isDark: isDark).write(to: directory.appending(path: "tab-folders-\(isDark ? "dark" : "light").png"))
        }
    }

    /// The page shown for a blocked address: while its lists are read, with the list and filter that
    /// blocked it, with none found, and in a private tab.
    @Test func blockedPageSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let url = URL(string: "https://tlauncher.org/en/")!
        let states: [(name: String, reason: BlockedPage.Reason?, isPrivate: Bool)] = [
            ("looking", nil, false),
            ("badware", BlockedPage.Reason(list: "ubo-badware", filter: "||tlauncher.org^$doc", groups: ["security"]), false),
            ("unknown", BlockedPage.Reason(groups: ["ads", "security"]), false),
            ("private", BlockedPage.Reason(list: "urlhaus", filter: "||tlauncher.org^", groups: ["security"]), true),
            // A filter naming hundreds of sites is cut short, the buttons still in view.
            ("long-filter", BlockedPage.Reason(list: "ubo-badware", filter: "*$doc,domain=" + (1...400).map { "site\($0).example" }.joined(separator: "|") + "|tlauncher.org",
                                               groups: ["security"]), false),
        ]
        for state in states {
            for isDark in [false, true] {
                let view = BlockedPageView(page: BlockedPage(url: url, reason: state.reason), isPrivate: state.isPrivate, onBack: {}, onOpen: { _ in })
                    .frame(width: 760, height: 520)
                try render(view, isDark: isDark).write(to: directory.appending(path: "blocked-page-\(state.name)-\(isDark ? "dark" : "light").png"))
            }
        }
    }

    /// The list under a sign-in field, with a site's accounts and with a strong password, and the
    /// bar after a sign-in, to save an account and to update one.
    @Test func passwordSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let field = CGRect(x: 0, y: 0, width: 280, height: 34)
        let lists = [
            ("accounts", PasswordDropdown(tabID: UUID(), host: "www.example.com", field: .username, rect: field, rows: [
                .account(UUID(), username: "alice@example.com", host: "www.example.com"), .account(UUID(), username: "bob", host: "accounts.example.com"),
            ])),
            ("strong", PasswordDropdown(tabID: UUID(), host: "www.example.com", field: .newPassword, rect: field, rows: [.strongPassword])),
        ]
        let bars = [
            ("save", PasswordSaveRequest(tabID: UUID(), host: "accounts.example.com", username: "alice", password: "", offer: .save)),
            ("update", PasswordSaveRequest(tabID: UUID(), host: "accounts.example.com", username: "alice", password: "", offer: .update(UUID()))),
        ]
        for isDark in [false, true] {
            let scheme = isDark ? "dark" : "light"
            for (name, dropdown) in lists {
                let frame = dropdown.frame(in: CGSize(width: 1000, height: 1000))
                let list = PasswordDropdownView(dropdown: dropdown) { _ in }.frame(width: frame.width, height: frame.height).padding(20)
                try render(list, isDark: isDark).write(to: directory.appending(path: "password-list-\(name)-\(scheme).png"))
            }
            for (name, request) in bars {
                let bar = PasswordSaveBar(request: request) { _ in }.frame(width: 900)
                try render(bar, isDark: isDark).write(to: directory.appending(path: "password-bar-\(name)-\(scheme).png"))
            }
        }
    }

    /// Through an off-screen window, so AppKit controls such as switches draw as they do in the app.
    private func render(_ view: some View, isDark: Bool) throws -> Data {
        let hosting = NSHostingView(rootView: view.background(isDark ? Color(white: 0.17) : Color(white: 0.97)))
        hosting.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: hosting.frame.width, height: hosting.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        bitmap.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func poll(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }
}

/// Answers the settings page the way `InternalBridge` does, with a fixed sample state.
@MainActor
final class SampleBridge: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let action = (message.body as? [String: Any])?["action"] as? String
        if action == "site" { return (["cookies": 14, "hasData": true], nil) }
        if action == "fonts" { return (["DM Sans", "Avenir Next", "Georgia", "Helvetica Neue", "Menlo", "New York"], nil) }
        if action == "filterLists" { return (Self.filterLists, nil) }
        if action == "passwords" { return (Self.passwords, nil) }
        return (Self.state, nil)
    }

    static let passwords: [String: Any] = [
        "offers": true, "unlock": "oncePerLaunch",
        "accounts": [
            ["id": UUID().uuidString, "site": "example.com", "host": "accounts.example.com", "username": "alice@example.com"],
            ["id": UUID().uuidString, "site": "example.com", "host": "www.example.com", "username": "bob"],
            ["id": UUID().uuidString, "site": "github.com", "host": "github.com", "username": "alice"],
            ["id": UUID().uuidString, "site": "mail.example", "host": "mail.example", "username": "alice@mail.example"],
            ["id": UUID().uuidString, "site": "news.example", "host": "news.example", "username": "alice"],
            ["id": UUID().uuidString, "site": "shop.example", "host": "shop.example", "username": ""],
            ["id": UUID().uuidString, "site": "travel.example", "host": "travel.example", "username": "alice"],
            ["id": UUID().uuidString, "site": "wiki.example", "host": "wiki.example", "username": "bob"],
        ],
        "neverSaved": ["bank.example", "tax.example"],
        "error": "",
        "report": "Added 3, updated 1, skipped 2",
    ]

    static let filterLists: [String: Any] = {
        let updated = Date().addingTimeInterval(-3 * 3600).timeIntervalSince1970 * 1000
        func list(_ id: String, _ name: String, _ summary: String, enabled: Bool, rules: Int, failed: Bool = false, removable: Bool = false) -> [String: Any] {
            ["id": id, "name": name, "summary": summary, "homepage": "https://example.com", "enabled": enabled, "rules": rules,
             "updated": updated, "failed": failed, "removable": removable]
        }
        return [
            "sections": [
                ["title": "uBlock Origin", "lists": [
                    list("ubo-filters", "uBlock Origin filters", "Ads, pop-ups and trackers.", enabled: true, rules: 38_211),
                    list("ubo-unbreak", "uBlock Origin unbreak", "Keeps sites working that other lists break.", enabled: false, rules: 2_310),
                ]] as [String: Any],
                ["title": "Annoyances", "lists": [
                    list("ubo-annoyances", "uBlock Origin annoyances", "Pop-ups, overlays and other distractions.", enabled: true, rules: 9_402),
                    list("adguard-annoyances", "AdGuard annoyances", "Pop-ups, widgets and app banners.", enabled: false, rules: -1),
                ]] as [String: Any],
                ["title": "Community", "lists": [
                    list("hide-youtube-shorts", "Hide YouTube Shorts", "Removes Shorts from YouTube’s pages and menus.", enabled: true, rules: 64, failed: true),
                ]] as [String: Any],
                ["title": "Added by you", "lists": [
                    list("url-1", "lists.example.org", "https://lists.example.org/filters.txt", enabled: true, rules: 120, removable: true),
                ]] as [String: Any],
            ],
            "myFilters": "example.com##.newsletter-popup\n||tracker.example^\nexample.org##+js(nope)",
            "problems": [["line": 3, "text": "example.org##+js(nope)", "message": "Unknown scriptlet “nope”."]],
            "error": "That address doesn’t lead to a filter list.",
        ]
    }()

    static let state: [String: Any] = [
        "appearance": [
            "sidebarStyle": "solid", "sidebarColor": "#D5DAF5", "defaultColor": "#D5DAF5", "sidebarReveal": "normal",
            "miniPlayer": true, "tabUsage": true, "websiteFont": true, "readerButton": true,
            "translateOffer": true, "translateLanguages": [["code": "de", "name": "German"]], "translateSites": ["example.net"],
            "interfaceFont": "DM Sans", "websiteFamily": "Georgia", "websiteFontName": "Georgia", "siteFontDomains": ["example.org"],
            "startPage": ["background": "gradient", "color": "#2B2D42", "gradientFrom": "#1F3A5F", "gradientTo": "#3D2C4E", "hasImage": false] as [String: Any],
        ] as [String: Any],
        "search": [
            "engine": "duckduckgo",
            "engines": [["id": "google", "name": "Google", "host": "www.google.com"], ["id": "duckduckgo", "name": "DuckDuckGo", "host": "duckduckgo.com"], ["id": "ecosia", "name": "Ecosia", "host": "www.ecosia.org"]],
        ] as [String: Any],
        "protections": [
            "ruleCount": 183_402,
            "updated": Date().addingTimeInterval(-3 * 3600).timeIntervalSince1970 * 1000,
            "updating": false,
            "disabledHosts": ["bank.example.com"],
            "spaceDisabledHosts": [] as [[String: String]],
            "allowedPages": ["tlauncher.org"],
        ] as [String: Any],
        "permissions": [["host": "meet.google.com", "camera": "allow", "microphone": "allow"], ["host": "www.example.com", "location": "deny"]],
        // Settings' render reads every key: one missing stops it before the rest of the page.
        "appLinks": [[String: String]](),
        "max": [
            "tidyTitles": true, "tidyDownloads": true, "summaries": true, "summaryLanguage": "", "summarySystemLanguage": "English",
            "summaryLanguages": [["code": "en", "name": "English"], ["code": "fr", "name": "French"]],
            "modelAvailable": false,
            "modelMessage": "Turn on Apple Intelligence in System Settings. Basic tidying still works.",
        ] as [String: Any],
        "agents": ["enabled": true, "stopped": false, "status": "On. 1 agent connected.", "url": "http://127.0.0.1:52817/mcp", "captureBodies": false, "runScripts": true,
                   "bridge": "/Applications/Lithium.app/Contents/MacOS/lithium-mcp"] as [String: Any],
        "advanced": ["developerTools": true, "quickLinks": true, "energySaving": "onBattery"] as [String: Any],
        "extensions": [["id": "abc", "name": "1Password", "version": "8.11.4", "enabled": true, "hasOptions": true, "icon": "lithium://pages/app-icon"] as [String: Any]],
        "about": ["version": "1.0", "safari": "26.0", "macOS": "Version 26.0 (Build 25A354)"],
    ]
}
