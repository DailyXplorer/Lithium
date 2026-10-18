import SwiftUI

/// A browser window: `BrowserView` for one `BrowserWindow`, hosted as `QuickLinkWindow` hosts a
/// link's page. Lithium opens every browser window itself, so the first and the fifth are made,
/// shown, keyed, closed and restored the same way.
final class BrowserNSWindow: NSWindow, NSWindowDelegate {
    private let model: BrowserWindow
    private weak var browser: Browser?

    /// Where it was saved; a new window cascades from the one in front, or opens centered.
    static func open(_ window: BrowserWindow, browser: Browser) -> NSWindow? {
        let nsWindow = BrowserNSWindow(window, browser: browser)
        if let frame = window.frame {
            nsWindow.setFrame(from: frame)
        } else if let front = browser.keyWindow?.nsWindow {
            nsWindow.setFrameTopLeftPoint(nsWindow.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        } else {
            nsWindow.center()
        }
        show(nsWindow)
        return nsWindow
    }

    /// AppKit hands the keyboard to a window's first field as it orders front; a hosting view not
    /// yet laid out has no fields, so without the layout the keys went to the window itself.
    static func show(_ nsWindow: NSWindow) {
        nsWindow.contentView?.layoutSubtreeIfNeeded()
        nsWindow.makeKeyAndOrderFront(nil)
    }

    /// Not shown: `open` shows it. Tests build one to drive its delegate.
    init(_ window: BrowserWindow, browser: Browser) {
        model = window
        self.browser = browser
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Lithium"
        isReleasedWhenClosed = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        tabbingMode = .disallowed
        minSize = NSSize(width: 760, height: 480)
        collectionBehavior.insert(.fullScreenPrimary)
        delegate = self
        contentView = NSHostingView(rootView: BrowserView().environment(browser).environment(window))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        browser?.windowBecameKey(model)
    }

    func windowWillMiniaturize(_ notification: Notification) {
        browser?.windowMinimizing(true)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        browser?.windowMinimizing(false)
    }

    func windowDidMove(_ notification: Notification) {
        model.noteFrame(frameDescriptor)
    }

    func windowDidResize(_ notification: Notification) {
        model.noteFrame(frameDescriptor)
    }

    func windowWillClose(_ notification: Notification) {
        browser?.windowWillClose(model)
        // A late update of the closed view would take a web view back from another window.
        contentView = nil
    }
}
