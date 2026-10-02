import AppKit
import Testing
@testable import Lithium

@MainActor
struct PopupAnchorTests {
    /// Counts as shown without being ordered in, so the tests put nothing on screen.
    private final class ShownWindow: NSWindow {
        override var isVisible: Bool { true }
    }

    private let window = ShownWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
    private let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    private let anchor = NSView(frame: NSRect(x: 300, y: 260, width: 28, height: 28))

    init() {
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.addSubview(anchor)
    }

    @Test func aViewInTheWindowIsOnScreen() {
        #expect(Extensions.isOnScreen(anchor))
    }

    @Test func aHiddenViewIsNot() {
        anchor.isHidden = true
        #expect(!Extensions.isOnScreen(anchor))
    }

    @Test func aViewInAHiddenParentIsNot() {
        container.isHidden = true
        #expect(!Extensions.isOnScreen(anchor))
    }

    @Test func aViewInATransparentParentIsNot() {
        container.alphaValue = 0
        #expect(!Extensions.isOnScreen(anchor))
    }

    @Test func aViewOutsideTheWindowIsNot() {
        anchor.frame.origin.x = -200
        #expect(!Extensions.isOnScreen(anchor))
    }

    @Test func aViewInAWindowOffEveryScreenIsNot() {
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        #expect(!Extensions.isOnScreen(anchor))
    }

    @Test func aViewOutOfAnyWindowIsNot() {
        anchor.removeFromSuperview()
        #expect(!Extensions.isOnScreen(anchor))
    }

    @Test func thePopupGoesToTheFirstViewOnScreen() {
        let offScreen = NSView(frame: container.frame)
        #expect(Extensions.firstOnScreen([nil, offScreen, container, anchor]) === container)
        #expect(Extensions.firstOnScreen([nil, offScreen]) == nil)
    }
}
