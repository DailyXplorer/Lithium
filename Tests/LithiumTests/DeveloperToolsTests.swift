import Foundation
import Testing
import WebKit
@testable import Lithium

/// Settings › Advanced › Developer tools. A whole Browser keeps its data in the home folder, so
/// this suite only runs in a throwaway one: `scripts/test --filter DeveloperToolsTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct DeveloperToolsTests {
    private func developerExtras(_ webView: WKWebView) -> Bool {
        webView.configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool ?? false
    }

    @Test func newTabsAreInspectableOnlyWithTheSettingOn() {
        UserDefaults.standard.removeObject(forKey: Preference.developerTools)
        defer { UserDefaults.standard.removeObject(forKey: Preference.developerTools) }
        let browser = Browser()
        #expect(browser.developerTools)

        let on = browser.newTab().webView
        #expect(on.isInspectable)
        #expect(developerExtras(on))

        browser.developerTools = false
        #expect(!on.isInspectable)
        #expect(!developerExtras(on))
        let off = browser.newTab().webView
        #expect(!off.isInspectable)
        #expect(!developerExtras(off))
        #expect(UserDefaults.standard.object(forKey: Preference.developerTools) as? Bool == false)
    }

    /// A Quick Link window's page is kept out of the tab list, and follows the setting all the same.
    @Test func quickLinkPagesFollowTheSetting() throws {
        UserDefaults.standard.removeObject(forKey: Preference.developerTools)
        defer { UserDefaults.standard.removeObject(forKey: Preference.developerTools) }
        let browser = Browser()
        browser.quickLinks.showWindow = { _, _ in nil }
        let tab = try #require(browser.quickLinks.open())
        defer { browser.quickLinks.close(tab) }
        #expect(tab.webView.isInspectable)

        browser.developerTools = false
        #expect(!tab.webView.isInspectable)
        #expect(!developerExtras(tab.webView))
        browser.developerTools = true
        #expect(tab.webView.isInspectable)
    }

    @Test func menuItemsNeedATabAndTheSetting() {
        UserDefaults.standard.removeObject(forKey: Preference.developerTools)
        defer { UserDefaults.standard.removeObject(forKey: Preference.developerTools) }
        let browser = Browser()
        browser.tabs.forEach(browser.close)
        #expect(!browser.canShowWebInspector)

        browser.newTab()
        #expect(browser.canShowWebInspector)
        browser.developerTools = false
        #expect(!browser.canShowWebInspector)
    }
}
