import AppKit

/// A window no screen shows, for tests that need a real one. AppKit puts a titled window made off
/// screen back on the main screen, over whatever the person running the tests is doing: as it is
/// made, and again whenever it would constrain its frame. This class keeps the frame it is given.
class OffscreenWindow: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        setFrame(frameRect(forContentRect: contentRect), display: false)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
