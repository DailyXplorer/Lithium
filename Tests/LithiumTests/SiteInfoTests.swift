import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Lithium

@MainActor
struct SiteInfoTests {
    /// The panel and the lock in the address bar both go by the address: WebKit commits an https
    /// page only with a valid certificate, whether or not its web view has the trust to show.
    @Test func siteInfoIsSecureForHTTPSOnly() {
        #expect(SiteInfo(url: URL(string: "https://www.youtube.com/watch?v=x")!).isSecure)
        #expect(SiteInfo(url: URL(string: "HTTPS://example.com/")!).isSecure)
        #expect(!SiteInfo(url: URL(string: "http://example.com/")!).isSecure)
        #expect(!SiteInfo.isSecure(nil))
        #expect(SiteInfo(url: URL(string: "https://gist.github.com/")!).site == "github.com")
    }

    @Test func siteInfoSummarizesPermissions() {
        #expect(SiteInfoView.permissionSummary([:]) == "Ask")
        #expect(SiteInfoView.permissionSummary([.camera: .allow]) == "Camera allowed")
        #expect(SiteInfoView.permissionSummary([.location: .deny]) == "Location blocked")
        #expect(SiteInfoView.permissionSummary([.camera: .allow, .microphone: .allow]) == "2 allowed")
        #expect(SiteInfoView.permissionSummary([.camera: .allow, .microphone: .allow, .downloads: .deny]) == "2 allowed, 1 blocked")
    }

    /// The panel with sample values, for a look without launching the app:
    /// `LITHIUM_SNAPSHOT_DIR=/tmp/shots ./scripts/test --filter SiteInfo`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] != nil, "Writes PNGs only when LITHIUM_SNAPSHOT_DIR is set"))
    func siteInfoSnapshots() throws {
        let directory = URL(filePath: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let certificate = SiteInfo.Certificate(subject: "*.google.com", issuer: "WR2", validUntil: DateComponents(calendar: .current, year: 2026, month: 12, day: 8).date)
        let shots: [(String, SiteInfoView)] = [
            ("secure", SiteInfoView(host: "www.youtube.com", favicon: nil, isSecure: true, certificate: .loading, cookieCount: 29, canClear: true, permissions: [:], showsCertificate: .constant(false))),
            ("secure-certificate", SiteInfoView(host: "www.youtube.com", favicon: nil, isSecure: true, certificate: .found(certificate), cookieCount: 29, canClear: true, permissions: [:], showsCertificate: .constant(true))),
            ("http", SiteInfoView(host: "neverssl.com", favicon: nil, isSecure: false, certificate: .loading, cookieCount: 0, canClear: false, permissions: [:], showsCertificate: .constant(false))),
            ("camera", SiteInfoView(host: "meet.google.com", favicon: nil, isSecure: true, certificate: .loading, cookieCount: 12, canClear: true, permissions: [.camera: .allow], showsCertificate: .constant(false))),
        ]
        for (name, view) in shots {
            for isDark in [false, true] {
                let renderer = ImageRenderer(content: view
                    .foregroundStyle(isDark ? Color.white : Color.black)
                    .background(isDark ? Color(white: 0.17) : Color(white: 0.97))
                    .environment(\.colorScheme, isDark ? .dark : .light))
                renderer.scale = 2
                let image = try #require(renderer.nsImage)
                let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
                try png.write(to: directory.appending(path: "site-info-\(name)-\(isDark ? "dark" : "light").png"))
            }
        }
    }
}

extension BrowserTests {
    /// youtube.com's page comes from its service worker, or over a connection already open: its
    /// web view has no `serverTrust`, which made the panel call it not secure.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHIUM_NETWORK_TESTS"] == "1", "Loads youtube.com"))
    func siteInfoOfAPageWithoutServerTrust() async throws {
        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "https://www.youtube.com/")!)
        defer { browser.close(tab) }
        #expect(await siteInfoPoll(30) { tab.loadedWebView?.isLoading == false && tab.loadedWebView?.url?.host() == "www.youtube.com" })
        let trust = tab.loadedWebView?.serverTrust
        print("youtube.com serverTrust:", trust as Any)
        let info = SiteInfo(url: try #require(tab.url))
        #expect(info.isSecure)
        await info.loadCertificate(trust: trust)
        guard case .found(let certificate) = info.certificate else { Issue.record("no certificate: \(info.certificate)"); return }
        #expect(certificate.subject.hasSuffix("google.com"))
        #expect((certificate.validUntil ?? .distantPast) > Date())
    }

    /// Site settings… opens one site's settings: its permissions and its cookies.
    @Test func siteInfoOpensTheSiteSettings() async throws {
        let browser = Browser()
        browser.permissions.set(.allow, for: .camera, host: "www.example.com")
        defer { browser.permissions.set(nil, for: .camera, host: "www.example.com") }
        browser.openSettings(section: "site/www.example.com")
        let tab = try #require(browser.selectedTab)
        defer { browser.close(tab) }
        var page: [String: Any]?
        let deadline = Date().addingTimeInterval(15)
        while page == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            page = try? await tab.webView.callAsyncJavaScript("""
                const cookies = document.querySelector('#site-cookies')?.textContent;
                if (!cookies) return null;
                return {
                    active: document.querySelector('section.active')?.id,
                    host: document.querySelector('#site-host').textContent,
                    rows: [...document.querySelectorAll('#site-permissions .row')].map((r) => r.querySelector('.title').textContent + ':' + r.querySelector('select').value),
                    cookies,
                    clear: document.querySelector('#site-clear').textContent,
                    nav: document.querySelector('nav a.active')?.textContent,
                };
                """, contentWorld: .page) as? [String: Any]
        }
        let values = try #require(page)
        #expect(values["active"] as? String == "site")
        #expect(values["host"] as? String == "example.com")
        #expect(values["rows"] as? [String] == ["Camera:allow", "Microphone:", "Location:", "Downloads:"])
        #expect(values["cookies"] as? String == "0 cookies")
        #expect(values["clear"] as? String == "Clear site data")
        #expect(values["nav"] as? String == "Site permissions")

        if let path = ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] {
            let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 900, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = tab.webView
            // A window never shown doesn't run the page's entrance animation, which starts transparent.
            _ = try await tab.webView.evaluateJavaScript("document.head.append(Object.assign(document.createElement('style'), { textContent: '* { animation: none !important }' }))")
            for isDark in [false, true] {
                window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
                try await Task.sleep(for: .milliseconds(500))
                let image = try await tab.webView.takeSnapshot(configuration: nil)
                let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
                try png.write(to: URL(filePath: path).appending(path: "site-settings-\(isDark ? "dark" : "light").png"))
            }
            window.contentView = nil
        }
    }

    /// The rule count and the list sources wait behind Details; the update action stays up front.
    @Test func settingsKeepsRuleCountBehindDetails() async throws {
        let browser = Browser()
        browser.openSettings(section: "privacy")
        let tab = try #require(browser.selectedTab)
        defer { browser.close(tab) }
        var page: [String: Any]?
        let deadline = Date().addingTimeInterval(15)
        while page == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            page = try? await tab.webView.callAsyncJavaScript("""
                const rules = document.querySelector('#rules')?.textContent;
                if (!rules) return null;
                const details = document.querySelector('#privacy details');
                return {
                    rules,
                    inDetails: details.contains(document.querySelector('#rules')),
                    open: details.open,
                    updated: document.querySelector('#updated').textContent,
                    update: document.querySelector('#update').textContent,
                    active: document.querySelector('section.active')?.id,
                };
                """, contentWorld: .page) as? [String: Any]
        }
        let values = try #require(page)
        #expect(values["active"] as? String == "privacy")
        #expect(values["rules"] as? String == "\(browser.privacy.ruleCount.formatted(.number.locale(Locale(identifier: "en")))) rules from:")
        #expect(values["inDetails"] as? Bool == true)
        #expect(values["open"] as? Bool == false)
        // With no lists bundled in tests, the browser may be downloading them.
        let updated = try #require(values["updated"] as? String)
        if values["update"] as? String == "Updating" {
            #expect(updated == "Updating…")
        } else {
            #expect(values["update"] as? String == "Update now")
            #expect(updated.hasPrefix("Updated ") || updated == "Not updated yet", "\(updated)")
        }
    }

    private func siteInfoPoll(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
