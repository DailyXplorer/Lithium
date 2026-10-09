import AppKit
import SwiftUI
import WebKit

/// The color picker of Lithium's own pages: the system color panel, beside the swatch.
///
/// WebKit places `<input type=color>`'s popover in window coordinates, which count from the bottom,
/// but Lithium's content view is SwiftUI's, which counts from the top, so the popover came up
/// mirrored about the window's middle.
@MainActor
final class PageColorPicker: NSObject {
    /// Shows the picker at the swatch's rect on screen; the color panel when nil. For tests.
    var present: ((_ swatch: CGRect, _ color: NSColor) -> Void)?
    private(set) var anchor: CGRect?
    private var onChange: ((String) -> Void)?

    static let gap: CGFloat = 6

    /// `css` is the swatch's rect in CSS pixels; `onChange` gets each color picked, as "#RRGGBB".
    func pick(css: CGRect, viewport: PageViewport, hex: String, in webView: WKWebView, onChange: @escaping (String) -> Void) {
        guard let swatch = Self.screenRect(of: css, viewport: viewport, in: webView) else { return }
        self.onChange = onChange
        anchor = swatch
        let color = NSColor(Color(hex: hex))
        if let present { present(swatch, color) } else { showPanel(at: swatch, color: color) }
    }

    func choose(_ color: NSColor) {
        onChange?(Color(nsColor: color).hex)
    }

    static func screenRect(of css: CGRect, viewport: PageViewport, in webView: WKWebView) -> CGRect? {
        guard let window = webView.window else { return nil }
        var rect = AgentScreenshot.viewRect(css, viewport: viewport, zoom: webView.pageZoom)
        if !webView.isFlipped { rect.origin.y = webView.bounds.height - rect.maxY }
        return window.convertToScreen(webView.convert(rect, to: nil))
    }

    /// Centered under the swatch, or over it where the screen ends first, and always on the screen.
    static func panelFrame(size: CGSize, around swatch: CGRect, on screen: CGRect) -> CGRect {
        var y = swatch.minY - gap - size.height
        if y < screen.minY { y = swatch.maxY + gap }
        y = min(max(y, screen.minY), screen.maxY - size.height)
        let x = min(max(swatch.midX - size.width / 2, screen.minX), screen.maxX - size.width)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func showPanel(at swatch: CGRect, color: NSColor) {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        // Set before taking the panel, so the page's own color doesn't come back as a pick.
        panel.setTarget(nil)
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        let screen = NSScreen.screens.first { $0.frame.intersects(swatch) } ?? NSScreen.main
        panel.setFrame(Self.panelFrame(size: panel.frame.size, around: swatch, on: screen?.visibleFrame ?? swatch), display: false)
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        choose(panel.color)
    }
}
