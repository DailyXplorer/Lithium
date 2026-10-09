import Testing
import WebKit
@testable import Lithium

/// Searches that finish out of order, driven by targets that answer when told to.
@MainActor
struct FindInPageTests {
    @Test func anOlderSearchFinishingLastLeavesTheCountAlone() async {
        let find = FindInPage()
        let slow = Target(matches: 7)
        let fast = Target(matches: 3)
        let first = Task { await find.update(query: "licence", in: slow) }
        await slow.waitUntilAsked()
        fast.answer()
        await find.update(query: "licence", in: fast)
        slow.answer()
        await first.value
        #expect(find.matchCount == 3)
        #expect(find.currentMatch == 1)
        #expect(slow.shown == 0)
    }

    @Test func closingTheBarStopsTheSearchStillRunning() async {
        let find = FindInPage()
        let page = Target(matches: 5)
        find.show()
        let search = Task { await find.update(query: "licence", in: page) }
        await page.waitUntilAsked()
        find.hide()
        page.answer()
        await search.value
        #expect(page.shown == 0)
        #expect(page.cleared)
    }

    @Test func steppingBackFromNoMatchLandsOnTheLast() async {
        let find = FindInPage()
        // A web page counts 5 matches but can't show the first (hidden text), so none is current.
        let page = Target(matches: 5, knowsPosition: false)
        page.canShow = false
        page.answer()
        await find.update(query: "licence", in: page)
        #expect(find.currentMatch == 0)
        page.canShow = true
        await find.step(forward: false, in: page)
        #expect(find.currentMatch == 5)
    }

    /// A PDF forgets its matches when the bar closes, so the next step searches it again rather
    /// than finding nothing under the old count.
    @Test func steppingAfterTheBarClosedSearchesAgain() async {
        let find = FindInPage()
        let pdf = Target(matches: 5)
        pdf.forgetsClearedMatches = true
        pdf.answer()
        find.show()
        await find.update(query: "licence", in: pdf)
        await find.step(forward: true, in: pdf)
        #expect(find.currentMatch == 2)
        find.hide()
        find.show()
        await find.step(forward: true, in: pdf)
        #expect(find.matchCount == 5)
        #expect(find.currentMatch == 1)
        await find.step(forward: true, in: pdf)
        #expect(find.currentMatch == 2)
    }

    /// Searching again after the bar closed keeps the direction asked for: Find Previous lands on the last match.
    @Test func steppingBackAfterTheBarClosedLandsOnTheLast() async {
        let find = FindInPage()
        let pdf = Target(matches: 5)
        pdf.forgetsClearedMatches = true
        pdf.answer()
        find.show()
        await find.update(query: "licence", in: pdf)
        find.hide()
        find.show()
        await find.step(forward: false, in: pdf)
        #expect(find.currentMatch == 5)
    }

    /// Each count reads the whole page text: a burst of keystrokes counts once, for the last text.
    @Test func typingCountsOnceThePauseComes() async {
        let find = FindInPage()
        let page = Target(matches: 2)
        page.answer()
        let keystrokes = ["l", "li", "lic", "lice"].map { text in Task { await find.type(query: text, in: page) } }
        for keystroke in keystrokes { await keystroke.value }
        #expect(page.counted == ["lice"])
        #expect(find.query == "lice" && find.matchCount == 2)
    }

    /// Return right after typing searches the new text at once, and the pending search doesn't run again.
    @Test func searchingBeforeThePauseDropsThePendingSearch() async {
        let find = FindInPage()
        let page = Target(matches: 2)
        page.answer()
        let typed = Task { await find.type(query: "licence", in: page) }
        // The keystroke came first: its task waits out the pause before Return.
        await Task.yield()
        await find.update(query: "licence", in: page)
        await typed.value
        #expect(page.counted == ["licence"])
    }

    /// A page finishing loading during the pause searches the old text again: the new text still searches after.
    @Test func searchingTheOldTextAgainKeepsThePendingSearch() async {
        let find = FindInPage()
        let page = Target(matches: 2)
        page.answer()
        await find.update(query: "lic", in: page)
        let typed = Task { await find.type(query: "lice", in: page) }
        await Task.yield()
        await find.update(query: find.query, in: page)
        await typed.value
        #expect(page.counted == ["lic", "lic", "lice"])
        #expect(find.query == "lice")
    }

    /// Closing the bar during the pause drops the pending search.
    @Test func closingTheBarDropsThePendingSearch() async {
        let find = FindInPage()
        let page = Target(matches: 2)
        page.answer()
        find.show()
        let typed = Task { await find.type(query: "licence", in: page) }
        await Task.yield()
        find.hide()
        await typed.value
        #expect(page.counted.isEmpty)
    }

    /// Only Find… gives the find field the keyboard: Find Next and Use Selection for Find show the
    /// bar but leave the keyboard where it was, such as a form field in the page.
    @Test func onlyFindTakesTheKeyboard() async {
        let find = FindInPage()
        let page = Target(matches: 2)
        page.selection = "licence"
        page.answer()
        await find.useSelection(in: page)
        #expect(find.isVisible && find.query == "licence")
        #expect(find.focusToken == 0 && !find.focusesField)
        find.show(focusingField: false)
        #expect(find.focusToken == 0 && !find.focusesField)
        find.show()
        #expect(find.focusToken == 1 && find.focusesField)
    }

    /// Each step in a long page scrolls its match into view, in the window and in a box that
    /// scrolls on its own, and marks it; closing the bar unmarks it and leaves it selected.
    @Test(.timeLimit(.minutes(1))) func stepsScrollEachMatchIntoView() async throws {
        let gap = "<div style='height: 3000px'></div>"
        let page = """
            <!doctype html><body style="font: 16px sans-serif">
            <p id="one">Needle at the top</p>\(gap)
            <p id="two">Needle in the middle</p>\(gap)
            <div style="height: 300px; overflow: auto">\(gap)<p id="three">Needle in a box</p>\(gap)</div>\(gap)
            </body>
            """
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(page, baseURL: URL(string: "https://example.com/")!)
        try await loaded.wait()

        /// The id of the marked match's paragraph, if the page shows it there: nothing covers it.
        func shown() async throws -> String? {
            let script = """
                const range = CSS.highlights.get('lithium-find')?.values().next().value;
                if (!range) return null;
                const box = range.getBoundingClientRect();
                const seen = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
                return seen === range.startContainer.parentElement ? seen.id : null;
                """
            // Lithium's world: each world keeps its own copy of the highlights' list.
            return try await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? String
        }

        let find = FindInPage()
        await find.update(query: "needle", in: webView)
        #expect(find.matchCount == 3)
        #expect(try await shown() == "one")
        for (forward, id) in [(true, "two"), (true, "three"), (true, "one"), (false, "three"), (false, "two")] {
            await find.step(forward: forward, in: webView)
            #expect(try await shown() == id, "stepping \(forward ? "forward" : "back") to \(id)")
        }

        find.hide()
        let deadline = ContinuousClock.now + .seconds(5)
        var selected: String?
        while ContinuousClock.now < deadline {
            selected = try await webView.callAsyncJavaScript("return CSS.highlights.size ? null : String(getSelection());", contentWorld: .defaultClient) as? String
            if selected != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(selected == "Needle")
    }

    /// A search starting mid-page (the user clicked there) counts from the match it shows, not
    /// from 1, and steps and wraps from there. Hidden text is left out, as the count leaves it out.
    @Test(.timeLimit(.minutes(1))) func theCounterShowsTheMatchsPlaceInThePage() async throws {
        let page = """
            <!doctype html><body>
            <p>Needle one</p><p style="display: none">Needle hidden</p><p>Needle two</p>
            <p id="clicked">Needle three</p><p>Needle four</p><p>Needle five</p>
            </body>
            """
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(page, baseURL: URL(string: "https://example.com/")!)
        try await loaded.wait()
        _ = try await webView.callAsyncJavaScript("getSelection().collapse(document.getElementById('clicked').firstChild, 6)", contentWorld: .page)

        let find = FindInPage()
        await find.update(query: "needle", in: webView)
        #expect(find.matchCount == 5)
        #expect(find.currentMatch == 4)
        await find.step(forward: true, in: webView)
        #expect(find.currentMatch == 5)
        await find.step(forward: true, in: webView)
        #expect(find.currentMatch == 1)
        await find.step(forward: false, in: webView)
        #expect(find.currentMatch == 5)
    }

    @MainActor
    final class Target: FindTarget {
        let matches: Int
        let knowsPosition: Bool
        private(set) var shown = 0
        private(set) var cleared = false
        /// The queries counted, each a read of the whole page text in a web page.
        private(set) var counted: [String] = []
        var canShow = true
        /// Like a PDF: nothing to show once cleared, until counted again.
        var forgetsClearedMatches = false
        var selection: String?
        private var position = 0
        private var hasMatches = false
        private var isAnswered = false
        private var gate: CheckedContinuation<Void, Never>?
        private var asked: CheckedContinuation<Void, Never>?
        private var wasAsked = false

        init(matches: Int, knowsPosition: Bool = true) {
            self.matches = matches
            self.knowsPosition = knowsPosition
        }

        func answer() {
            isAnswered = true
            gate?.resume()
            gate = nil
        }

        func waitUntilAsked() async {
            if wasAsked { return }
            await withCheckedContinuation { asked = $0 }
        }

        func countMatches(of query: String) async -> Int {
            counted.append(query)
            wasAsked = true
            asked?.resume()
            asked = nil
            if !isAnswered { await withCheckedContinuation { gate = $0 } }
            hasMatches = true
            position = 0
            return matches
        }

        func showNextMatch(of query: String, forward: Bool) async -> FindStep {
            guard canShow, hasMatches || !forgetsClearedMatches else { return .none }
            shown += 1
            position = forward ? position % matches + 1 : (position <= 1 ? matches : position - 1)
            return .shown(position: knowsPosition ? position : nil)
        }

        func selectedText() async -> String? { selection }

        func clearMatches() {
            cleared = true
            hasMatches = false
        }
    }
}
