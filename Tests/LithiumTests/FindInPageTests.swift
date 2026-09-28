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

    @MainActor
    final class Target: FindTarget {
        let matches: Int
        let knowsPosition: Bool
        private(set) var shown = 0
        private(set) var cleared = false
        var canShow = true
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
            return matches
        }

        func showNextMatch(of query: String, forward: Bool) async -> FindStep {
            guard canShow else { return .none }
            shown += 1
            return .shown(position: knowsPosition ? shown : nil)
        }

        func selectedText() async -> String? { nil }

        func clearMatches() {
            cleared = true
        }
    }
}
