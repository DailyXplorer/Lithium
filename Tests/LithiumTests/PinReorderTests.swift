import Foundation
import Testing
@testable import Lithium

/// Favorites keep their grid order on disk, so this suite only runs in a throwaway home folder:
/// `CFFIXED_USER_HOME=$(mktemp -d) swift test --filter PinReorderTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct PinReorderTests {
    /// A browser whose grid holds favorites "a" to "e", in that order, and nothing else.
    private func browserWithPins() -> Browser {
        let browser = Browser()
        browser.pins.forEach(browser.unpin)
        for name in ["a", "b", "c", "d", "e"] {
            browser.pin(browser.newTab(url: URL(string: "data:text/html,\(name)")!))
        }
        return browser
    }

    private func order(_ browser: Browser) -> [String] {
        browser.pins.map { String($0.url.absoluteString.dropFirst("data:text/html,".count)) }
    }

    private func move(_ name: String, to index: Int, in browser: Browser) {
        let pin = browser.pins.first { $0.url.absoluteString == "data:text/html,\(name)" }!
        browser.movePin(id: pin.id, to: index)
    }

    @Test func movesForward() {
        let browser = browserWithPins()
        move("b", to: 3, in: browser)
        #expect(order(browser) == ["a", "c", "d", "b", "e"])
    }

    @Test func movesBackward() {
        let browser = browserWithPins()
        move("d", to: 1, in: browser)
        #expect(order(browser) == ["a", "d", "b", "c", "e"])
    }

    @Test func movesToTheEnds() {
        let browser = browserWithPins()
        move("c", to: 0, in: browser)
        #expect(order(browser) == ["c", "a", "b", "d", "e"])
        move("a", to: 4, in: browser)
        #expect(order(browser) == ["c", "b", "d", "e", "a"])
        move("b", to: 99, in: browser)
        #expect(order(browser) == ["c", "d", "e", "a", "b"])
        move("e", to: -3, in: browser)
        #expect(order(browser) == ["e", "c", "d", "a", "b"])
    }

    @Test func movingInPlaceOrAnUnknownFavoriteChangesNothing() {
        let browser = browserWithPins()
        move("c", to: 2, in: browser)
        browser.movePin(id: UUID(), to: 0)
        #expect(order(browser) == ["a", "b", "c", "d", "e"])
    }

    /// The new order is what the next launch reads, and what ⌘1 opens.
    @Test func newOrderIsSavedAndDrivesShortcuts() {
        let browser = browserWithPins()
        move("e", to: 0, in: browser)
        #expect(PinStore.load().map(\.id) == browser.pins.map(\.id))
        browser.selectItem(at: 0)
        #expect(browser.selectedTab?.url?.absoluteString == "data:text/html,e")
    }

    @Test func pinsATabAtASlot() {
        let browser = browserWithPins()
        let tab = browser.newTab(url: URL(string: "data:text/html,new")!)
        browser.pinTab(withID: tab.id.uuidString, at: 1)
        #expect(order(browser) == ["a", "new", "b", "c", "d", "e"])
        #expect(tab.pinID == browser.pins[1].id)

        let last = browser.newTab(url: URL(string: "data:text/html,last")!)
        browser.pinTab(withID: last.id.uuidString)
        #expect(order(browser).last == "last")
    }

    @Test func pinningAnUnknownTabChangesNothing() {
        let browser = browserWithPins()
        browser.pinTab(withID: UUID().uuidString, at: 0)
        browser.pinTab(withID: "pin:\(browser.pins[2].id.uuidString)", at: 0)
        #expect(order(browser) == ["a", "b", "c", "d", "e"])
    }
}
