import Foundation
import Testing
import WebKit
@testable import Lithium

/// Tabs of a whole Browser with a stand-in for the model. Only in a throwaway home folder (see
/// `BrowserTests`).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct TidyTitlesTests {
    @MainActor
    final class Model {
        var asked: [String] = []
        var answers = false
    }

    /// Two tabs showing the same long title while the model is asked about it both get its
    /// answer, not only the tab that asked.
    @Test func everyTabWithTheTitleGetsTheShortName() async throws {
        let title = "Swift concurrency explained with many practical examples for beginners"
        let page = (headers: "Content-Type: text/html", body: "<title>\(title)</title><p>Page</p>")
        let (listener, base) = try await LocalHTTP.serve(["/one": page, "/two": page])
        defer { listener.cancel() }
        let browser = Browser()
        let titles = browser.tidyTitles
        let wasEnabled = titles.isEnabled
        titles.isEnabled = true
        defer { titles.isEnabled = wasEnabled }
        let model = Model()
        titles.shortener = { cleaned, _ in
            model.asked.append(cleaned)
            while !model.answers { try? await Task.sleep(for: .milliseconds(20)) }
            // The model can answer all lowercase; the title's capitals come back.
            return .title("swift concurrency")
        }
        // Answers whatever happens, so the stand-in never outlives the test.
        defer { model.answers = true }

        let one = browser.newTab(url: base.appending(path: "one"))
        let two = browser.newTab(url: base.appending(path: "two"))
        defer { [one, two].forEach { browser.close($0) } }
        #expect(await waitUntil(30) { [one, two].allSatisfy { !$0.webView.isLoading && $0.title == title } })
        #expect(await waitUntil(10) { !model.asked.isEmpty })
        model.answers = true

        #expect(await waitUntil(10) { [one, two].allSatisfy { $0.tidyTitle == "Swift concurrency" } })
        #expect(model.asked == [title], "asked once for both tabs")
    }

    /// A long title that keeps changing while the model answers (a live count) asks one title at
    /// a time, and only once for the page: the titles after it keep the rules' tidying.
    @Test func aLiveTitleAsksTheModelOncePerPage() async throws {
        let first = "Live match commentary and every score update from the stadium tonight"
        let page = (headers: "Content-Type: text/html", body: "<title>\(first)</title><p>Page</p>")
        let (listener, base) = try await LocalHTTP.serve(["/live": page])
        defer { listener.cancel() }
        let browser = Browser()
        let titles = browser.tidyTitles
        let wasEnabled = titles.isEnabled
        titles.isEnabled = true
        defer { titles.isEnabled = wasEnabled }
        let model = Model()
        titles.shortener = { cleaned, _ in
            model.asked.append(cleaned)
            while !model.answers { try? await Task.sleep(for: .milliseconds(20)) }
            return .title("Live match")
        }
        defer { model.answers = true }

        let tab = browser.newTab(url: base.appending(path: "live"))
        defer { browser.close(tab) }
        #expect(await waitUntil(30) { !tab.webView.isLoading && tab.title == first })
        #expect(await waitUntil(10) { model.asked == [first] })

        // Each a new long title while the first is still answered, each held past the settling
        // delay: only the wait for the request before it keeps it from the model.
        var last = first
        for minute in 1...5 {
            last = "Live match commentary at minute \(minute) with every score update from the stadium"
            _ = try await tab.webView.evaluateJavaScript("document.title = '\(last)'")
            #expect(await waitUntil(5) { tab.title == last })
            try await Task.sleep(for: .seconds(1))
        }
        #expect(model.asked == [first], "one title at a time")
        model.answers = true

        _ = try await tab.webView.evaluateJavaScript("document.title = '\(last) again'")
        #expect(await waitUntil(5) { tab.title == last + " again" })
        try await Task.sleep(for: .seconds(1.5))
        #expect(model.asked == [first], "the page already asked")
        #expect(tab.displayTitle == last + " again")
    }

    /// A tab opened in the background asks the model nothing until it's shown.
    @Test func aTabOffScreenAsksOnceShown() async throws {
        let title = "Swift concurrency explained with many practical examples for beginners"
        let page = (headers: "Content-Type: text/html", body: "<title>\(title)</title><p>Page</p>")
        let (listener, base) = try await LocalHTTP.serve(["/page": page])
        defer { listener.cancel() }
        let browser = Browser()
        let titles = browser.tidyTitles
        let wasEnabled = titles.isEnabled
        titles.isEnabled = true
        defer { titles.isEnabled = wasEnabled }
        let model = Model()
        titles.shortener = { cleaned, _ in
            model.asked.append(cleaned)
            return .title("Swift concurrency")
        }

        let shown = browser.newTab()
        let background = browser.newTab(url: base.appending(path: "page"), selecting: false)
        defer { [shown, background].forEach { browser.close($0) } }
        #expect(await waitUntil(30) { !background.webView.isLoading && background.title == title })
        try await Task.sleep(for: .seconds(1.5))
        #expect(model.asked.isEmpty)

        browser.select(background)
        #expect(await waitUntil(10) { background.tidyTitle == "Swift concurrency" })
        #expect(model.asked == [title])
    }

    /// A page whose address changes with its title (a timestamp in the URL) is capped per site.
    @Test func aSiteAsksTheModelAtMostTenTimesAMinute() async throws {
        let browser = Browser()
        let titles = browser.tidyTitles
        let wasEnabled = titles.isEnabled
        titles.isEnabled = true
        defer { titles.isEnabled = wasEnabled }
        let model = Model()
        titles.shortener = { cleaned, _ in
            model.asked.append(cleaned)
            return .title("Live match")
        }
        let tab = browser.newTab()
        defer { browser.close(tab) }
        for minute in 1...11 {
            tab.restore(url: URL(string: "https://live.example/match?t=\(minute)")!,
                        title: "Live match commentary at minute \(minute) with every score update")
            titles.update(tab)
            #expect(await waitUntil(5) { model.asked.count == min(minute, 10) })
        }
        try await Task.sleep(for: .seconds(1.5))
        #expect(model.asked.count == 10)
    }

    /// A request the model couldn't answer doesn't use up the page's: its next title asks again.
    @Test func aFailedRequestIsAskedAgainAtTheNextTitle() async throws {
        let browser = Browser()
        let titles = browser.tidyTitles
        let wasEnabled = titles.isEnabled
        titles.isEnabled = true
        defer { titles.isEnabled = wasEnabled }
        let model = Model()
        titles.shortener = { cleaned, _ in
            model.asked.append(cleaned)
            return model.asked.count == 1 ? .failed : .title("Live match")
        }
        let tab = browser.newTab()
        defer { browser.close(tab) }
        let page = URL(string: "https://live.example/match")!
        tab.restore(url: page, title: "Live match commentary at minute 1 with every score update")
        titles.update(tab)
        #expect(await waitUntil(5) { model.asked.count == 1 })
        try await Task.sleep(for: .milliseconds(100))

        tab.restore(url: page, title: "Live match commentary at minute 2 with every score update")
        titles.update(tab)
        #expect(await waitUntil(5) { model.asked.count == 2 })
        #expect(await waitUntil(5) { tab.tidyTitle == "Live match" })
    }

    /// Tabs restored asleep at launch show their tidy titles at once, from the rules alone.
    @Test func restoredTabsGetTidyTitles() throws {
        let wasEnabled = UserDefaults.standard.object(forKey: TidyTitles.preferenceKey)
        UserDefaults.standard.set(true, forKey: TidyTitles.preferenceKey)
        defer { UserDefaults.standard.set(wasEnabled, forKey: TidyTitles.preferenceKey) }
        let url = URL(string: "https://github.com/login")!
        SessionStore.save(Session(tabs: [.init(url: url, title: "Sign in to GitHub · GitHub", customTitle: nil, pinID: nil)], selectedIndex: nil))
        defer { SessionStore.save(Session()) }
        let browser = Browser()
        let tab = try #require(browser.tabs.first { $0.url == url })
        #expect(tab.isAsleep)
        #expect(tab.displayTitle == "Sign in to GitHub")
    }

    /// Turned off, the feature sends the model none of the titles still waiting their turn.
    @Test func turnedOffItAsksTheModelNothingMore() async throws {
        let browser = Browser()
        let titles = browser.tidyTitles
        let wasEnabled = titles.isEnabled
        titles.isEnabled = true
        defer { titles.isEnabled = wasEnabled }
        let model = Model()
        titles.shortener = { cleaned, _ in
            model.asked.append(cleaned)
            while !model.answers { try? await Task.sleep(for: .milliseconds(20)) }
            return .title("Short")
        }
        defer { model.answers = true }
        // On screen, where tabs ask; the second page waits for the model to answer the first.
        let tab = browser.newTab()
        defer { browser.close(tab) }
        tab.restore(url: URL(string: "https://one.example/")!, title: "Swift concurrency explained with many practical examples for beginners")
        titles.update(tab)
        #expect(await waitUntil(10) { model.asked.count == 1 })
        tab.restore(url: URL(string: "https://two.example/")!, title: "Live match commentary and every score update from the stadium tonight")
        titles.update(tab)

        titles.isEnabled = false
        model.answers = true
        try await Task.sleep(for: .seconds(1.5))
        #expect(model.asked.count == 1)
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
