import AppKit
import Testing
import WebKit
@testable import Lithium

@MainActor
struct PageColorPickerTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 230, height: 300)

    @Test func thePanelSitsCenteredUnderTheSwatch() {
        let swatch = CGRect(x: 700, y: 600, width: 28, height: 28)
        let frame = PageColorPicker.panelFrame(size: size, around: swatch, on: screen)
        #expect(frame.midX == swatch.midX)
        #expect(frame.maxY == swatch.minY - PageColorPicker.gap)
        #expect(frame.size == size)
    }

    @Test func itGoesOverTheSwatchNearTheScreensBottom() {
        let swatch = CGRect(x: 700, y: 120, width: 28, height: 28)
        let frame = PageColorPicker.panelFrame(size: size, around: swatch, on: screen)
        #expect(frame.minY == swatch.maxY + PageColorPicker.gap)
    }

    @Test func itStaysOnTheScreen() {
        let swatch = CGRect(x: 1430, y: 600, width: 28, height: 28)
        #expect(PageColorPicker.panelFrame(size: size, around: swatch, on: screen).maxX == screen.maxX)
        let left = CGRect(x: -10, y: 600, width: 28, height: 28)
        #expect(PageColorPicker.panelFrame(size: size, around: left, on: screen).minX == screen.minX)
    }

    private func near(_ rect: CGRect?, _ other: CGRect) -> Bool {
        guard let rect else { return false }
        return [rect.minX - other.minX, rect.minY - other.minY, rect.width - other.width, rect.height - other.height].allSatisfy { abs($0) < 0.5 }
    }

    /// Puts the sidebar settings the tests change back as they were.
    private func keepingSidebarSettings() -> () -> Void {
        let defaults = UserDefaults.standard
        let style = defaults.object(forKey: Preference.sidebarStyle), color = defaults.object(forKey: Preference.sidebarColor)
        return {
            defaults.set(style, forKey: Preference.sidebarStyle)
            defaults.set(color, forKey: Preference.sidebarColor)
        }
    }

    /// The settings page in a window that is never ordered in, at a known place on screen.
    private func settingsInWindow(_ browser: Browser) async throws -> (WKWebView, NSWindow) {
        let tab = browser.newTab(url: Internal.settingsURL)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 500), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        window.contentView = container
        tab.webView.frame = container.bounds
        container.addSubview(tab.webView)
        var ready = false
        for _ in 0..<100 where !ready {
            try await Task.sleep(for: .milliseconds(50))
            ready = (try? await tab.webView.evaluateJavaScript("!!document.querySelector('#style button.on')")) as? Bool == true
        }
        #expect(ready)
        // The sidebar color row shows with the solid background only.
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('#style button[data-value=solid]').click()")
        try await Task.sleep(for: .milliseconds(100))
        return (tab.webView, window)
    }

    /// Clicks the custom color swatch and returns its rect in the viewport and where the picker
    /// was anchored.
    private func clickSwatch(_ webView: WKWebView, _ picker: PageColorPicker) async throws -> (css: CGRect, anchor: CGRect?) {
        let previous = picker.anchor
        let rect = try await webView.evaluateJavaScript("""
            (() => { const input = document.querySelector('#custom-color'); input.click()
              const r = input.getBoundingClientRect(); return [r.x, r.y, r.width, r.height] })()
            """) as? [Double] ?? []
        for _ in 0..<50 where picker.anchor == previous { try await Task.sleep(for: .milliseconds(20)) }
        guard rect.count == 4 else { return (.zero, nil) }
        return (CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]), picker.anchor)
    }

    @Test func thePickerIsAnchoredToTheSwatchAtAnyScrollAndZoom() async throws {
        let browser = Browser()
        var shown: [CGRect] = []
        browser.colorPicker.present = { swatch, _ in shown.append(swatch) }
        let restore = keepingSidebarSettings()
        let (webView, window) = try await settingsInWindow(browser)
        defer { window.close(); restore() }

        // The window's frame on screen counts from the bottom: the swatch's top is 500 - y up.
        func expected(_ css: CGRect, zoom: Double = 1) -> CGRect {
            CGRect(x: 100 + css.minX * zoom, y: 100 + 500 - css.maxY * zoom, width: css.width * zoom, height: css.height * zoom)
        }

        let top = try await clickSwatch(webView, browser.colorPicker)
        #expect(top.css.width > 0)
        #expect(near(top.anchor, expected(top.css)))

        _ = try await webView.evaluateJavaScript("document.querySelector('main').scrollTop = 120")
        let scrolled = try await clickSwatch(webView, browser.colorPicker)
        #expect(scrolled.css.minY < top.css.minY)
        #expect(near(scrolled.anchor, expected(scrolled.css)))

        webView.pageZoom = 1.5
        try await Task.sleep(for: .milliseconds(100))
        let zoomed = try await clickSwatch(webView, browser.colorPicker)
        #expect(near(zoomed.anchor, expected(zoomed.css, zoom: 1.5)))
        #expect(shown.count == 3)
    }

    @Test func aPickedColorReachesTheSetting() async throws {
        let browser = Browser()
        browser.colorPicker.present = { _, _ in }
        let restore = keepingSidebarSettings()
        let (webView, window) = try await settingsInWindow(browser)
        defer { window.close(); restore() }
        _ = try await clickSwatch(webView, browser.colorPicker)

        browser.colorPicker.choose(NSColor(srgbRed: 0x12 / 255, green: 0x34 / 255, blue: 0x56 / 255, alpha: 1))
        var shown = ""
        for _ in 0..<50 where shown != "#123456" {
            try await Task.sleep(for: .milliseconds(20))
            shown = (try? await webView.evaluateJavaScript("document.querySelector('#color-hex').textContent")) as? String ?? ""
        }
        #expect(shown == "#123456")
        #expect(UserDefaults.standard.string(forKey: Preference.sidebarColor) == "#123456")
    }
}
