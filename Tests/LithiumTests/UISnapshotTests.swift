import Foundation
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
            ("extensions", "extensions", nil), ("max", "max", nil), ("agents", "agents", nil), ("permissions", "permissions", nil), ("advanced", "advanced", nil),
            ("site", "site/www.example.com", nil), ("about", "about", nil),
        ]
        for section in sections {
            _ = try await webView.evaluateJavaScript("location.hash = '\(section.hash)'; \(section.script ?? ""); 0")
            try await Task.sleep(for: .milliseconds(100))
            // A window never shown keeps the sticky sidebar's old paint; redrawing it shows the current section.
            _ = try await webView.evaluateJavaScript("document.querySelector('nav').style.display = 'none'; document.body.offsetHeight; document.querySelector('nav').style.display = ''; 0")
            for isDark in [false, true] {
                window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
                window.setFrame(NSRect(x: -5000, y: 0, width: 960, height: 700), display: false)
                try await Task.sleep(for: .milliseconds(400))
                let height = try await webView.evaluateJavaScript("document.querySelector('main').scrollHeight") as? Double ?? 700
                window.setFrame(NSRect(x: -5000, y: 0, width: 960, height: max(700, height)), display: false)
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
            let png = try render(AgentPanel(agent: client.hub).environment(browser), isDark: isDark)
            try png.write(to: directory.appending(path: "agent-panel-challenge-\(isDark ? "dark" : "light").png"))
        }
        browser.tabs.forEach(browser.close)
        await browser.setAgentAccess(false)
    }

    /// The confirmation banner for each kind of prompt, over the tab it is about and over another
    /// one, and the indicator's panel with a prompt waiting and a site grant.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func agentConfirmationSnapshots() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        let browser = Browser()
        await browser.setAgentAccess(true)
        let client = try await AgentTabsTests.Client(browser: browser)
        let confirmations = client.hub.confirmations
        let tab = browser.newTab()
        tab.customTitle = "Checkout · Shop"
        let asks: [(kind: ConfirmationKind, action: String, site: String?)] = [
            (.payment, "click “Pay €42.00” on shop.example", "shop.example"),
            (.password, "type into the password field on accounts.example.com", "example.com"),
            (.download, "download “report.csv” (1.2 MB) from files.example.com", "example.com"),
            (.upload, "upload invoice.pdf (88 KB) from /Users/ann/Documents to forms.example.com", "example.com"),
            (.file, "open the local file “notes.html” (its folder becomes readable to the page)", nil),
        ]
        for ask in asks {
            let confirmation = AgentConfirmation(kind: ask.kind, session: "x", sessionLabel: "s1", client: "claude-code", tabID: tab.id, action: ask.action, site: ask.site)
            for isDark in [false, true] {
                let banner = AgentConfirmationBanner(confirmation: confirmation, confirmations: confirmations).frame(width: 900).environment(browser)
                try render(banner, isDark: isDark).write(to: directory.appending(path: "agent-banner-\(ask.kind.rawValue)-\(isDark ? "dark" : "light").png"))
            }
        }
        let elsewhere = AgentConfirmation(kind: .download, session: "x", sessionLabel: "s1", client: "claude-code", tabID: tab.id, action: asks[2].action, site: "example.com")
        for isDark in [false, true] {
            let banner = AgentConfirmationBanner(confirmation: elsewhere, confirmations: confirmations, otherTab: tab, queued: 1).frame(width: 900).environment(browser)
            try render(banner, isDark: isDark).write(to: directory.appending(path: "agent-banner-other-tab-\(isDark ? "dark" : "light").png"))
        }

        let granted = AgentConfirmation(kind: .download, session: "x", sessionLabel: "s1", client: "claude-code", tabID: tab.id, action: asks[2].action, site: "example.com")
        confirmations.ask(granted)
        confirmations.answer(granted.id, .allowOnSite)
        confirmations.ask(AgentConfirmation(kind: .payment, session: "x", sessionLabel: "s1", client: "claude-code", tabID: tab.id, action: asks[0].action, site: "shop.example"))
        for isDark in [false, true] {
            let png = try render(AgentPanel(agent: client.hub).environment(browser), isDark: isDark)
            try png.write(to: directory.appending(path: "agent-panel-grants-\(isDark ? "dark" : "light").png"))
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
private final class SampleBridge: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let action = (message.body as? [String: Any])?["action"] as? String
        if action == "site" { return (["cookies": 14, "hasData": true], nil) }
        return (Self.state, nil)
    }

    static let state: [String: Any] = [
        "appearance": [
            "sidebarStyle": "solid", "sidebarColor": "#D5DAF5", "defaultColor": "#D5DAF5", "sidebarReveal": "normal",
            "miniPlayer": true, "tabUsage": true, "websiteFont": true,
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
        ] as [String: Any],
        "permissions": [["host": "meet.google.com", "camera": "allow", "microphone": "allow"], ["host": "www.example.com", "location": "deny"]],
        "max": [
            "tidyTitles": true, "summaries": true, "summaryLanguage": "", "summarySystemLanguage": "English",
            "summaryLanguages": [["code": "en", "name": "English"], ["code": "fr", "name": "French"]],
            "modelAvailable": false,
            "modelMessage": "Turn on Apple Intelligence in System Settings. Basic tidying still works.",
        ] as [String: Any],
        "agents": ["enabled": true, "stopped": false, "status": "On. 1 agent connected.", "url": "http://127.0.0.1:52817/mcp", "captureBodies": false, "runScripts": true,
                   "bridge": "/Applications/Lithium.app/Contents/MacOS/lithium-mcp"] as [String: Any],
        "advanced": ["developerTools": true],
        "extensions": [["id": "abc", "name": "1Password", "version": "8.11.4", "enabled": true, "hasOptions": true, "icon": "lithium://pages/app-icon"] as [String: Any]],
        "about": ["version": "1.0", "safari": "26.0", "macOS": "Version 26.0 (Build 25A354)"],
    ]
}
