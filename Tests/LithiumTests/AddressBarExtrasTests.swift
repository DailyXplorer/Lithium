import AppKit
import CoreImage
import SwiftUI
import Testing
@testable import Lithium

/// The address bar's loading line, zoom pill and QR code.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AddressBarExtrasTests {
    @Test func loadingLineHidesOnceTheLoadIsDone() {
        var load = LoadingProgress()
        #expect(!load.isVisible)

        load.update(isLoading: true, progress: 0)
        #expect(load.isVisible)
        #expect(load.value == LoadingProgress.minimumVisible)
        load.update(isLoading: true, progress: 0.6)
        load.update(isLoading: true, progress: 0.3)
        #expect(load.value == 0.6)

        load.update(isLoading: false, progress: 1)
        #expect(load.phase == .finishing)
        #expect(load.value == 1)
        load.finish(generation: load.generation)
        #expect(!load.isVisible)
        #expect(load.value == 0)
    }

    @Test func aLoadStartedDuringTheExitKeepsTheLine() {
        var load = LoadingProgress()
        load.update(isLoading: true, progress: 0.5)
        load.update(isLoading: false, progress: 1)
        let first = load.generation
        load.update(isLoading: true, progress: 0.1)
        load.finish(generation: first)
        #expect(load.phase == .loading)
        #expect(load.value == 0.1)
    }

    @Test func aLoadThatFinishesDuringThePreviousExitRunsItsOwn() {
        var load = LoadingProgress()
        load.update(isLoading: true, progress: 0.5)
        load.update(isLoading: false, progress: 1)
        let first = load.generation
        load.update(isLoading: true, progress: 0.2)
        load.update(isLoading: false, progress: 1)
        let second = load.generation

        load.finish(generation: first)
        #expect(load.phase == .finishing)
        #expect(load.value == 1)
        load.finish(generation: second)
        #expect(!load.isVisible)
    }

    @Test func zoomLabelsAndSteps() {
        #expect(PageZoom.label(1) == nil)
        #expect(PageZoom.label(0.9999999999999999) == nil)
        #expect(PageZoom.label(1.1) == "110%")
        #expect(PageZoom.label(0.5) == "50%")
        #expect(PageZoom.stepped(1, by: 0.1) == 1.1)
        #expect(PageZoom.stepped(PageZoom.stepped(1.1, by: 0.1), by: -0.2) == 1)
        #expect(PageZoom.stepped(0.5, by: -0.1) == 0.5)
        #expect(PageZoom.stepped(3, by: 0.1) == 3)
    }

    @Test func qrCodeReadsBackAsThePageAddress() throws {
        let address = "https://example.com/articles/2026/10/qr?ref=lithium#top"
        let image = try #require(QRCode.image(for: address, scale: 4))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
        #expect(features.map(\.messageString) == [address])
    }

    /// Nearest-neighbour modules: every pixel is pure black or pure white, the quiet zone white.
    @Test func qrCodeIsCrisp() throws {
        let scale = 3
        let image = try #require(QRCode.image(for: "https://example.com", scale: scale))
        #expect(image.width == image.height)
        #expect(image.width % scale == 0)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var grays = Set<Int>()
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                grays.insert(Int(((bitmap.colorAt(x: x, y: y)?.whiteComponent ?? -1) * 255).rounded()))
            }
        }
        #expect(grays == [0, 255])
        let margin = QRCode.quietZone * scale
        #expect((0..<image.width).allSatisfy { bitmap.colorAt(x: $0, y: margin - 1)?.whiteComponent == 1 })
    }

    @Test func qrCodeFileNameNamesTheSite() {
        #expect(QRCode.fileName(for: URL(string: "https://news.example.org/a/b")!) == "news.example.org QR code.png")
    }
}

/// The pill follows the web view's zoom, whoever sets it. A whole Browser keeps its data in the
/// home folder, so this suite only runs in a throwaway one (`scripts/test`).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct ZoomPillTests {
    @Test func pillShowsOnlyAwayFromActualSize() throws {
        let browser = Browser()
        browser.newTab(url: URL(string: "data:text/html,zoom")!)
        let tab = try #require(browser.commandWindow.selectedTab)
        #expect(tab.zoom == 1)
        #expect(!ZoomPill.isShown(for: tab, isPresented: false))

        tab.webView.pageZoom = 1.1
        #expect(tab.zoom == 1.1)
        #expect(ZoomPill.isShown(for: tab, isPresented: false))

        tab.webView.pageZoom = 1
        #expect(!ZoomPill.isShown(for: tab, isPresented: false))
        #expect(ZoomPill.isShown(for: tab, isPresented: true))
    }
}

/// `LITHIUM_SNAPSHOT_DIR=/tmp/shots ./scripts/test --filter AddressBarSnapshotTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] != nil, "Writes PNGs only when LITHIUM_SNAPSHOT_DIR is set"))
struct AddressBarSnapshotTests {
    private let directory = URL(filePath: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] ?? "/tmp")

    @Test func zoomSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        for isDark in [false, true] {
            let scheme: ColorScheme = isDark ? .dark : .light
            let palette = SidebarPalette(style: .solid, colorHex: Theme.defaultSidebarHex, scheme: scheme)
            let bar = HStack(spacing: 4) {
                Icon(.lock, size: 15).opacity(0.6).frame(width: 22, height: 22)
                Text("example.com").frame(maxWidth: .infinity)
                ZoomPillLabel(text: "110%")
            }
            .font(Theme.font(13))
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(width: 420, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.field))
            .padding(12)
            .environment(\.sidebarPalette, palette)
            let name = isDark ? "dark" : "light"
            try render(bar, isDark: isDark).write(to: directory.appending(path: "zoom-pill-\(name).png"))
            try render(ZoomView(zoom: 1.1).environment(\.sidebarPalette, palette), isDark: isDark)
                .write(to: directory.appending(path: "zoom-popover-\(name).png"))
        }
    }

    @Test func qrCodeSnapshots() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        for isDark in [false, true] {
            let view = QRCodeView(url: URL(string: "https://example.com/articles/2026/10/qr")!)
            try render(view, isDark: isDark).write(to: directory.appending(path: "qr-code-\(isDark ? "dark" : "light").png"))
        }
    }

    /// Through an off-screen window that is never shown.
    private func render(_ view: some View, isDark: Bool) throws -> Data {
        let hosting = NSHostingView(rootView: view.background(isDark ? Color(white: 0.17) : Color(white: 0.97)))
        hosting.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: hosting.frame.width, height: hosting.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        bitmap.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
