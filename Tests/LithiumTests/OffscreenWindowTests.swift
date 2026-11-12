import AppKit
import Foundation
import Testing

/// The windows tests make stay where no screen shows them: whoever runs the tests keeps using the Mac.
@MainActor
struct OffscreenWindowTests {
    /// AppKit put a titled window made at (-30000, -30000) on the main screen, in front of the
    /// user's own windows, for as long as its test ran.
    @Test(arguments: [[.borderless], [.titled, .fullSizeContentView], [.titled, .closable, .miniaturizable, .resizable]] as [NSWindow.StyleMask])
    func staysOffScreenWhateverItsStyle(style: NSWindow.StyleMask) {
        let place = NSRect(x: -30000, y: -30000, width: 400, height: 300)
        let window = OffscreenWindow(contentRect: place, styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Seen by nobody, even where this fails.
        window.alphaValue = 0
        #expect(window.screen == nil)
        #expect(window.frame.origin == place.origin, "as made: \(window.frame)")

        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 500, height: 200))
        #expect(window.screen == nil)
        #expect(window.frame.minX == place.minX, "in front and resized: \(window.frame)")
    }

    /// Any other window class with a title bar comes back on screen, wherever its test puts it.
    @Test func everyTitledWindowATestMakesIsAnOffscreenWindow() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != URL(fileURLWithPath: #filePath).lastPathComponent }
        let sources = try files.map { (name: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8)) }
        #expect(sources.count > 50, "the test sources weren't found in \(folder.path)")

        var allowed: Set<Substring> = ["OffscreenWindow"]
        for source in sources {
            for match in source.text.matches(of: /class\s+(\w+)\s*:\s*OffscreenWindow\b/) { allowed.insert(match.1) }
        }
        var offenders: [String] = []
        for source in sources {
            // The call that makes the window, up to its style: `super.init` is its class's, checked by name.
            for match in source.text.matches(of: /(\w+)\(contentRect:[^\[]*styleMask:\s*\[([^\]]*)\]/) where match.2.contains(".titled") {
                let made = match.1 == "init" ? Self.enclosingClass(of: match.range.lowerBound, in: source.text) : match.1
                if !allowed.contains(made) { offenders.append("\(source.name): \(made)") }
            }
        }
        #expect(offenders == [], "make these from OffscreenWindow, or AppKit shows them on the main screen")
    }

    private static func enclosingClass(of index: String.Index, in text: String) -> Substring {
        text[..<index].matches(of: /class\s+(\w+)/).last?.1 ?? "?"
    }
}
