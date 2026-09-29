import Testing
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

    @MainActor
    final class Target: FindTarget {
        let matches: Int
        let knowsPosition: Bool
        private(set) var shown = 0
        private(set) var cleared = false
        var canShow = true
        /// Like a PDF: nothing to show once cleared, until counted again.
        var forgetsClearedMatches = false
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
            position = position % matches + 1
            return .shown(position: knowsPosition ? position : nil)
        }

        func selectedText() async -> String? { nil }

        func clearMatches() {
            cleared = true
            hasMatches = false
        }
    }
}
