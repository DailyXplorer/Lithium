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

    @Test func withNoneOnScreenTheFirstMinimizedComesBackAsBefore() {
        #expect(Browser.dockClick(on: [(a, .minimized), (b, .minimized)], lastActive: nil) == .restore(a))
        #expect(Browser.dockClick(on: [(a, .minimized), (b, .minimized), (c, .closed)], lastActive: c) == .restore(a), "the last active one closed")
    }

    @Test func aLinksWindowOnScreenOnlyBringsLithiumForward() {
        #expect(Browser.dockClick(on: [(a, .closed)], lastActive: a, linkOnScreen: true) == .comeForward)
        #expect(Browser.dockClick(on: [(a, .minimized)], lastActive: nil, linkOnScreen: true) == .comeForward)
        #expect(Browser.dockClick(on: [(a, .minimized)], lastActive: a, linkOnScreen: true) == .restore(a), "the last active one still comes back")
    }

    @Test func withNoWindowShowingOneOpens() {
        #expect(Browser.dockClick(on: [(a, .closed)], lastActive: a) == .openWindow)
    }
}
