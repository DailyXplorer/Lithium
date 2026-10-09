import AppKit
import Observation
@preconcurrency import ScreenCaptureKit
import WebKit

/// Screenshots of Lithium's own window, whole or a dragged area. ScreenCaptureKit's current-process
/// content needs no Screen Recording permission and sees exactly what is on screen.
@MainActor
@Observable
final class ScreenCapture {
    enum Phase {
        case idle
        case selecting
        case capturing
        case previewing(Shot)
    }

    private(set) var phase = Phase.idle
    @ObservationIgnored private unowned let browser: Browser

    init(browser: Browser) {
        self.browser = browser
    }

    var shot: Shot? {
        if case .previewing(let shot) = phase { shot } else { nil }
    }

    var isSelecting: Bool {
        if case .selecting = phase { true } else { false }
    }

    func begin() {
        guard case .idle = phase else { return }
        phase = .selecting
    }

    func finish() {
        phase = .idle
    }

    /// `area` is in the window's points, top-left origin; nil captures the whole window.
    func capture(_ area: CGRect?, of window: NSWindow) async {
        guard case .selecting = phase else { return }
        phase = .capturing
        do {
            let content: Shot.Content
            let scale: CGFloat
            if let area {
                let image = try await Self.snapshot(window)
                scale = CGFloat(image.width) / window.frame.width
                content = .area(try Self.crop(image, to: area, scale: scale))
            } else {
                content = try await windowWithAndWithoutSidebar(window)
                scale = CGFloat(content.anyImage.width) / window.frame.width
            }
            let wallpaper = Self.wallpaper(for: window.screen ?? NSScreen.main, fitting: content.anyImage)
            phase = .previewing(Shot(content: content, scale: scale, wallpaper: wallpaper))
        } catch {
            phase = .idle
            let alert = NSAlert()
            alert.messageText = "Couldn’t capture the window"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window) { _ in }
        }
    }

    /// Both looks, so the preview can switch the sidebar instantly; in Zen mode, the look with the
    /// sidebar is the window out of Zen mode.
    private func windowWithAndWithoutSidebar(_ window: NSWindow) async throws -> Shot.Content {
        let original = (sidebar: browser.isSidebarVisible, zen: browser.isZenMode)
        defer { (browser.isSidebarVisible, browser.isZenMode) = original }
        let shown = browser.showsSidebar
        var images: [Bool: CGImage] = [:]
        for visible in [shown, !shown] {
            if visible != shown {
                browser.isZenMode = false
                browser.isSidebarVisible = visible
                await Self.settle(window)
            }
            images[visible] = try await Self.snapshot(window)
        }
        return .window(sidebarOpen: images[true]!, sidebarClosed: images[false]!)
    }

    /// Toggling the sidebar resizes pages, which may lay out again in script over several frames:
    /// waits until none has changed for a moment, and goes ahead after 1.5 s for a page stuck in a script.
    private static func settle(_ window: NSWindow) async {
        window.contentView?.layoutSubtreeIfNeeded()
        let pages = webViews(in: window.contentView)
        let (settled, finish) = AsyncStream<Void>.makeStream()
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            finish.yield()
        }
        Task {
            for page in pages {
                _ = try? await page.callAsyncJavaScript("""
                    await new Promise(resolve => {
                      const start = performance.now();
                      let changed = start;
                      const observer = new MutationObserver(() => { changed = performance.now(); });
                      observer.observe(document, {subtree: true, childList: true, attributes: true, characterData: true});
                      const check = () => {
                        const now = performance.now();
                        if (now - changed < 200 && now - start < 1000) return setTimeout(check, 50);
                        observer.disconnect();
                        requestAnimationFrame(() => requestAnimationFrame(resolve));
                        setTimeout(resolve, 100);
                      };
                      setTimeout(check, 50);
                    });
                    """, contentWorld: .defaultClient)
            }
            finish.yield()
        }
        for await _ in settled { break }
    }

    private static func webViews(in view: NSView?) -> [WKWebView] {
        guard let view else { return [] }
        if let page = view as? WKWebView { return [page] }
        return view.subviews.flatMap(webViews)
    }

    private static func snapshot(_ window: NSWindow) async throws -> CGImage {
        // The window just changed (overlay removed, sidebar toggled); give the window server a frame to show it.
        try await Task.sleep(for: .milliseconds(80))
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private static func crop(_ image: CGImage, to area: CGRect, scale: CGFloat) throws -> CGImage {
        let pixels = CGRect(x: area.minX * scale, y: area.minY * scale, width: area.width * scale, height: area.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isEmpty, let cropped = image.cropping(to: pixels) else { throw CaptureError.emptyArea }
        return cropped
    }

    /// The screen's desktop picture, decoded no larger than the finished screenshot needs.
    private static func wallpaper(for screen: NSScreen?, fitting content: CGImage) -> CGImage? {
        guard let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(content.width, content.height) * 3 / 2,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    enum CaptureError: LocalizedError {
        case windowNotFound, emptyArea

        var errorDescription: String? {
            switch self {
            case .windowNotFound: "The window isn't on screen."
            case .emptyArea: "The selected area is empty."
            }
        }
    }
}

struct Shot: Identifiable {
    enum Content {
        case area(CGImage)
        case window(sidebarOpen: CGImage, sidebarClosed: CGImage)

        var anyImage: CGImage {
            switch self {
            case .area(let image), .window(_, let image): image
            }
        }
    }

    let id = UUID()
    let content: Content
    let scale: CGFloat
    let wallpaper: CGImage?

    var isWindow: Bool {
        if case .window = content { true } else { false }
    }

    var size: CGSize {
        CGSize(width: CGFloat(content.anyImage.width) / scale, height: CGFloat(content.anyImage.height) / scale)
    }

    func image(showingSidebar: Bool) -> CGImage {
        switch content {
        case .area(let image): image
        case .window(let open, let closed): showingSidebar ? open : closed
        }
    }
}

/// What the screenshot sits on. Persisted as "wallpaper", "none" or a "#RRGGBB" color.
enum CaptureBackdrop: Hashable, RawRepresentable {
    case wallpaper
    case color(String)
    case none

    init(rawValue: String) {
        switch rawValue {
        case "wallpaper": self = .wallpaper
        case "none": self = .none
        default: self = .color(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .wallpaper: "wallpaper"
        case .color(let hex): hex
        case .none: "none"
        }
    }
}

extension Preference {
    static let captureBackdrop = "captureBackdrop"
    static let captureBadge = "captureBadge"
    static let captureSidebar = "captureSidebar"
    static let captureTool = "captureTool"
    static let captureInk = "captureInk"
}
