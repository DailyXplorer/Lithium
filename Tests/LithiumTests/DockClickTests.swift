import Foundation
import Testing
@testable import Lithium

/// What a click on the Dock icon does, from the browser windows as they show (`Browser.dockClick`).
struct DockClickTests {
    private let a = UUID(), b = UUID(), c = UUID()

    @Test func theLastActiveWindowComesBackThoughAnotherIsOnScreen() {
        #expect(Browser.dockClick(on: [(a, .onScreen), (b, .minimized)], lastActive: b) == .restore(b))
    }

    @Test func withSeveralMinimizedTheLastActiveComesBackNotTheFirst() {
        #expect(Browser.dockClick(on: [(a, .minimized), (b, .minimized), (c, .minimized)], lastActive: b) == .restore(b))
    }

    @Test func withEveryWindowOnScreenLithiumOnlyComesForward() {
        #expect(Browser.dockClick(on: [(a, .onScreen), (b, .onScreen)], lastActive: a) == .comeForward)
    }

    @Test func aMinimizedWindowStaysWhileTheLastActiveIsOnScreen() {
        #expect(Browser.dockClick(on: [(a, .onScreen), (b, .minimized)], lastActive: a) == .comeForward)
    }

    @Test func withNoneOnScreenTheMostRecentMinimizedComesBack() {
        #expect(Browser.dockClick(on: [(a, .minimized), (b, .minimized)], lastActive: nil) == .restore(b))
        #expect(Browser.dockClick(on: [(a, .minimized), (b, .closed)], lastActive: b) == .restore(a), "the last active one closed")
    }

    @Test func withNoWindowShowingOneOpens() {
        #expect(Browser.dockClick(on: [(a, .closed)], lastActive: a) == .openWindow)
    }
}
