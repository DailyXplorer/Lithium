import AppKit
import SwiftUI
import WebKit

/// The color picker of Lithium's own pages, placed by the swatch that opened it.
///
/// WebKit opens `<input type=color>`'s popover from a hidden well it adds to the window's content
/// view, at the element's rect in window coordinates, which count from the bottom. Lithium's
/// content view is SwiftUI's, which counts from the top, so the popover came up mirrored about
/// the window's middle, often hundreds of points from the swatch. The settings page asks for this
/// picker instead: the system color panel, beside the swatch's rect on screen.
/// Nothing is made until a swatch is clicked.
@MainActor
final class PageColorPicker: NSObject {
    /// Shows the picker at the swatch's rect on screen; the color panel when nil. For tests.
    var present: ((_ swatch: CGRect, _ color: NSColor) -> Void)?
    /// The last swatch's rect on screen.
    private(set) var anchor: CGRect?
    private var onChange: ((String) -> Void)?

    /// Space between the swatch and the panel.
    static let gap: CGFloat = 6

    /// `css` is the swatch's rect in the page's viewport, in CSS pixels. `onChange` gets each
    /// color picked, as "#RRGGBB".
    func pick(css: CGRect, hex: String, in webView: WKWebView, onChange: @escaping (String) -> Void) {
        guard let swatch = Self.screenRect(of: css, in: webView) else { return }
        self.onChange = onChange
        anchor = swatch
        let color = NSColor(Color(hex: hex))
        if let present { present(swatch, color) } else { showPanel(at: swatch, color: color) }
    }

    /// A color picked in the panel, sent on to the page that asked.
    func choose(_ color: NSColor) {
        onChange?(Color(nsColor: color).hex)
    }

    /// The viewport's CSS pixels are the page zoom's points from the web view's top left.
    static func screenRect(of css: CGRect, in webView: WKWebView) -> CGRect? {
        guard let window = webView.window else { return nil }
        let zoom = webView.pageZoom
        var rect = CGRect(x: css.minX * zoom, y: css.minY * zoom, width: css.width * zoom, height: css.height * zoom)
        if !webView.isFlipped { rect.origin.y = webView.bounds.height - rect.maxY }
        return window.convertToScreen(webView.convert(rect, to: nil))
    }

    /// Centered under the swatch, as a popover would be, or over it where the screen ends
    /// first, and always on the screen.
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
