import Foundation
import Testing
import WebKit
@testable import Lithium

private typealias Tab = Lithium.Tab

/// Energy saving mode: when it is on, what it watches, and what it does to background tabs. A
/// whole Browser keeps its data in the home folder, so this suite only runs in a throwaway one:
/// `./scripts/test --filter EnergySavingTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct EnergySavingTests {
    /// On battery (the default) follows the power source and is the only choice that watches it;
    /// Always and Off watch nothing. The choice outlives the app.
    @Test func modeDecidesWhenItIsOnAndWhatIsWatched() {
        UserDefaults.standard.removeObject(forKey: Preference.energySaving)
        defer { UserDefaults.standard.removeObject(forKey: Preference.energySaving) }
        let energy = EnergySaver()
        #expect(energy.mode == .onBattery)
        #expect(energy.isWatchingPower)

        var onBattery = true
        var changes = 0
        energy.isOnLimitedPower = { onBattery }
        energy.update()
        #expect(energy.isOn)
        energy.onChange = { changes += 1 }
        energy.update()
        #expect(changes == 0, "told only when it changes")
        onBattery = false
        energy.update()
        #expect(!energy.isOn)
        #expect(changes == 1)

        energy.mode = .always
        #expect(energy.isOn)
        #expect(!energy.isWatchingPower)
        energy.mode = .off
        #expect(!energy.isOn)
        #expect(!energy.isWatchingPower)
        #expect(EnergySaver().mode == .off)

        energy.mode = .onBattery
        #expect(energy.isWatchingPower)
        #expect(UserDefaults.standard.string(forKey: Preference.energySaving) == "onBattery")
    }

    /// Background tabs sleep after 5 minutes instead of 10 while it is on.
    @Test func backgroundTabsSleepSooner() {
        UserDefaults.standard.removeObject(forKey: "tabIdleSeconds")
        defer { UserDefaults.standard.removeObject(forKey: Preference.energySaving) }
        let browser = Browser()
        browser.energy.mode = .off
        #expect(browser.idleInterval == Browser.tabIdleInterval)
        browser.energy.mode = .always
        #expect(browser.idleInterval == Browser.shortIdleInterval)
    }

    /// Off stays off in Low Power Mode or when the Mac runs hot; On battery follows the Mac.
    @Test func offIgnoresTheMacSavingEnergy() {
        UserDefaults.standard.removeObject(forKey: "tabIdleSeconds")
        defer { UserDefaults.standard.removeObject(forKey: Preference.energySaving) }
        let browser = Browser()
        browser.energy.isOnLimitedPower = { false }
        browser.energy.mode = .off
        #expect(browser.idleInterval(macSavesEnergy: true) == 10 * 60)
        browser.energy.mode = .onBattery
        #expect(browser.idleInterval(macSavesEnergy: true) == Browser.shortIdleInterval)
    }

    /// Only a background tab WebKit hears nothing from pauses: never the tab shown, its split
    /// partner, a tab playing sound or muted by the user, one in a call, or one WebKit can't tell
    /// about. Nothing pauses with energy saving off.
    @Test func pausesOnlySilentBackgroundMedia() {
        let browser = Browser()
        browser.regularTabs.forEach(browser.close)
        defer {
            UserDefaults.standard.removeObject(forKey: Preference.energySaving)
            browser.tabs.forEach(browser.close)
        }
        browser.energy.mode = .off
        let page = { (name: String) in URL(string: "data:text/html,\(name)")! }
        let silent = browser.newTab(url: page("silent"), selecting: false)
        let heard = browser.newTab(url: page("heard"), selecting: false)
        let muted = browser.newTab(url: page("muted"), selecting: false)
        let call = browser.newTab(url: page("call"), selecting: false)
        let unknown = browser.newTab(url: page("unknown"), selecting: false)
        let partner = browser.newTab(url: page("partner"), selecting: false)
        let shown = browser.newTab(url: page("shown"))
        browser.openInSplit(partner)
        browser.select(shown)
        #expect(browser.shownPartner === partner)
        muted.isMuted = true

        // Favorites' pages from an earlier session aren't part of this.
        let mine = Set([silent, heard, muted, call, unknown, partner, shown].map(\.id))
        var paused: [Tab.ID] = []
        browser.nowPlaying.pause = { if mine.contains($0.id) { paused.append($0.id) } }
        browser.nowPlaying.isHeard = { $0 === heard ? true : $0 === unknown ? nil : false }
        browser.nowPlaying.isInCall = { $0 === call }

        browser.pauseSilentMedia()
        #expect(paused.isEmpty)

        browser.energy.mode = .always
        #expect(paused == [silent.id], "turning it on applies it at once")
        paused = []
        browser.pauseSilentMedia()
        #expect(paused == [silent.id])
    }

    /// Open pages' hidden timers slow down further while it is on, a page made meanwhile too, and
    /// go back to WebKit's own setting when it ends.
    @Test func backgroundTimersSlowDownWhileOn() throws {
        let browser = Browser()
        defer {
            UserDefaults.standard.removeObject(forKey: Preference.energySaving)
            browser.tabs.forEach(browser.close)
        }
        browser.energy.mode = .off
        let open = browser.newTab(url: URL(string: "data:text/html,open")!)
        let standard = BackgroundThrottling.increases(in: WKWebView())
        try #require(standard != nil, "this WebKit has the preference")
        #expect(BackgroundThrottling.increases(in: open.webView) == standard)

        browser.energy.mode = .always
        #expect(BackgroundThrottling.increases(in: open.webView) == true)
        let later = browser.newTab(url: URL(string: "data:text/html,later")!)
        #expect(BackgroundThrottling.increases(in: later.webView) == true)
        // A link's own window, made while it is on, never shown.
        browser.quickLinks.showWindow = { _, _ in nil }
        let link = try #require(browser.quickLinks.open(URL(string: "data:text/html,link")!))
        defer { browser.quickLinks.close(link) }
        #expect(BackgroundThrottling.increases(in: link.webView) == true)

        browser.energy.mode = .off
        #expect(BackgroundThrottling.increases(in: open.webView) == standard)
        #expect(BackgroundThrottling.increases(in: later.webView) == standard)
        #expect(BackgroundThrottling.increases(in: link.webView) == standard)
    }
}
