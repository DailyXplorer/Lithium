import AppKit
import SwiftUI
import Testing
@testable import Lithium

/// Drives the screenshot preview with mouse and key events, in a window far off screen. One test at
/// a time: they pick the tool through the preferences they share.
@MainActor
@Suite(.serialized)
struct CapturePreviewTests {
    @Test func shapesMoveResizeBendAndDelete() async throws {
        let defaults = UserDefaults.standard
        defaults.set("none", forKey: Preference.captureBackdrop)
        defaults.set("rectangle", forKey: Preference.captureTool)
        defaults.set("#0A84FF", forKey: Preference.captureInk)
        let preview = try await Preview()
        defer { preview.window.orderOut(nil) }

        try await preview.drag(CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 120))
        #expect(preview.color(at: CGPoint(x: 100, y: 50)) == .ink)
        #expect(preview.color(at: CGPoint(x: 150, y: 120)) == .handle)

        try await preview.drag(CGPoint(x: 150, y: 120), to: CGPoint(x: 200, y: 160))
        #expect(preview.color(at: CGPoint(x: 120, y: 160)) == .ink)
        #expect(preview.color(at: CGPoint(x: 100, y: 120)) == .screenshot)

        try await preview.drag(CGPoint(x: 100, y: 50), to: CGPoint(x: 120, y: 60))
        #expect(preview.color(at: CGPoint(x: 130, y: 60)) == .ink)
        #expect(preview.color(at: CGPoint(x: 130, y: 50)) == .screenshot)

        defaults.set("arrow", forKey: Preference.captureTool)
        try await Task.sleep(for: .milliseconds(100))
        try await preview.drag(CGPoint(x: 20, y: 30), to: CGPoint(x: 180, y: 30))
        #expect(preview.color(at: CGPoint(x: 100, y: 30)) == .handle)
        try await preview.drag(CGPoint(x: 100, y: 30), to: CGPoint(x: 100, y: 10))
        #expect(preview.color(at: CGPoint(x: 100, y: 10)) == .handle)
        #expect(preview.color(at: CGPoint(x: 70, y: 30)) == .screenshot)

        #expect(preview.press("\u{7F}", keyCode: 51))
        try await Task.sleep(for: .milliseconds(150))
        #expect(preview.color(at: CGPoint(x: 100, y: 10)) == .screenshot)
        #expect(preview.color(at: CGPoint(x: 130, y: 60)) == .ink)

        #expect(preview.press("z", keyCode: 6, modifiers: .command))
        try await Task.sleep(for: .milliseconds(150))
        #expect(preview.color(at: CGPoint(x: 100, y: 12)) == .ink)
    }

    @Test func shortArrowsKeepTheirEndsWithinReach() async throws {
        let defaults = UserDefaults.standard
        defaults.set("none", forKey: Preference.captureBackdrop)
        defaults.set("arrow", forKey: Preference.captureTool)
        defaults.set("#0A84FF", forKey: Preference.captureInk)
        let preview = try await Preview()
        defer { preview.window.orderOut(nil) }

        // 8 points long, under 18 in the preview: the middle handle's reach covers both ends.
        try await preview.drag(CGPoint(x: 20, y: 150), to: CGPoint(x: 28, y: 150))
        try await preview.drag(CGPoint(x: 28, y: 150), to: CGPoint(x: 80, y: 150))
        #expect(preview.color(at: CGPoint(x: 60, y: 150)) == .ink)
    }

    /// A 300 × 200 point red screenshot on no backdrop. It shows 2.2 times as large, 130 points from
    /// the left and 24 from the top of the preview.
    @MainActor
    private final class Preview {
        enum Seen { case screenshot, ink, handle, other }

        let window: NSWindow
        let host: NSHostingView<AnyView>

        init() async throws {
            _ = NSApplication.shared
            let context = CGContext(
                data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            let shot = Shot(content: .area(context.makeImage()!), scale: 2, wallpaper: nil)
            host = NSHostingView(rootView: AnyView(CapturePreview(shot: shot).environment(Browser())))
            window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 920, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(300))
            window.setContentSize(host.fittingSize)
            try await Task.sleep(for: .milliseconds(300))
        }

        private func inView(_ point: CGPoint) -> CGPoint {
            CGPoint(x: 130 + 2.2 * point.x, y: 24 + 2.2 * point.y)
        }

        private func send(_ type: NSEvent.EventType, _ point: CGPoint) async throws {
            let location = inView(point)
            window.sendEvent(NSEvent.mouseEvent(
                with: type, location: CGPoint(x: location.x, y: host.bounds.height - location.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )!)
            try await Task.sleep(for: .milliseconds(30))
        }

        /// From `start` to `end` in the screenshot's points.
        func drag(_ start: CGPoint, to end: CGPoint) async throws {
            try await send(.leftMouseDown, start)
            for step in 1...6 {
                let t = CGFloat(step) / 6
                try await send(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
            try await send(.leftMouseUp, end)
            try await Task.sleep(for: .milliseconds(150))
        }

        /// The window can't be key off screen, so the key goes straight to the shortcuts.
        func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> Bool {
            host.performKeyEquivalent(with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            )!)
        }

        func color(at point: CGPoint) -> Seen {
            let snapshot = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: snapshot)
            let scale = CGFloat(snapshot.pixelsWide) / host.bounds.width
            let location = inView(point)
            let color = snapshot.colorAt(x: Int(location.x * scale), y: Int(location.y * scale))!.usingColorSpace(.sRGB)!
            switch (color.redComponent, color.greenComponent, color.blueComponent) {
            case let (red, green, blue) where red > 0.9 && green > 0.9 && blue > 0.9: return .handle
            case let (red, _, blue) where red > 0.8 && blue < 0.3: return .screenshot
            case let (red, _, blue) where blue > 0.8 && red < 0.4: return .ink
            default: return .other
            }
        }
    }
}
