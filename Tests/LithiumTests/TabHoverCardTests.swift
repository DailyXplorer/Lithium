import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lithium

@MainActor
@Suite(.serialized)
struct TabHoverCardTests {
    private let a = HoverTarget.tab(UUID())
    private let b = HoverTarget.tab(UUID())

    @Test func delaysMatchChrome() {
        #expect(TabHover.openDelay == .milliseconds(500))
        #expect(TabHover.closeDelay == .milliseconds(150))
    }

    /// Waits, up to a generous bound, for the card to settle on `target`: delays only ever run
    /// late, when other suites keep the main actor busy.
    private func settle(_ hover: TabHover, on target: HoverTarget?) async throws -> HoverTarget? {
        for _ in 0..<150 where hover.shown != target {
            try await Task.sleep(for: .milliseconds(20))
        }
        return hover.shown
    }

    private func opened(on target: HoverTarget) async throws -> TabHover {
        let hover = TabHover()
        hover.pointer(target, isInside: true)
        #expect(try await settle(hover, on: target) == target)
        return hover
    }

    @Test func opensOnlyOnceThePointerRests() async throws {
        let hover = TabHover()
        let start = ContinuousClock.now
        hover.pointer(a, isInside: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(hover.shown == nil)
        #expect(try await settle(hover, on: a) == a)
        #expect(ContinuousClock.now - start >= TabHover.openDelay)
    }

    @Test func brushingPastNeverOpens() async throws {
        let hover = TabHover()
        hover.pointer(a, isInside: true)
        try await Task.sleep(for: .milliseconds(100))
        hover.pointer(a, isInside: false)
        hover.pointer(b, isInside: true)
        try await Task.sleep(for: .milliseconds(100))
        hover.pointer(b, isInside: false)
        try await Task.sleep(for: .milliseconds(700))
        #expect(hover.shown == nil)
    }

    /// Whichever comes first, leaving the last row or entering the next, the card moves at once.
    @Test func followsThePointerFromRowToRow() async throws {
        let hover = try await opened(on: a)
        hover.pointer(a, isInside: false)
        hover.pointer(b, isInside: true)
        #expect(hover.shown == b)
        hover.pointer(a, isInside: true)
        hover.pointer(b, isInside: false)
        #expect(hover.shown == a)
        try await Task.sleep(for: .milliseconds(300))
        #expect(hover.shown == a)
    }

    @Test func closesAfterThePointerLeaves() async throws {
        let hover = try await opened(on: a)
        hover.pointer(a, isInside: false)
        #expect(hover.shown == a)
        #expect(try await settle(hover, on: nil) == nil)
    }

    @Test func clickPutsTheCardAway() async throws {
        let hover = try await opened(on: a)
        hover.dismiss()
        #expect(hover.shown == nil)
        try await Task.sleep(for: .milliseconds(650))
        #expect(hover.shown == nil)
    }

    /// The pointer stays on the clicked row: the card waits for it to leave and come back.
    @Test func clickedCardReturnsOnlyWhenThePointerComesBack() async throws {
        let hover = try await opened(on: a)
        hover.dismiss()
        try await Task.sleep(for: TabHover.openDelay + .milliseconds(300))
        #expect(hover.shown == nil)
        hover.pointer(a, isInside: false)
        try await Task.sleep(for: TabHover.closeDelay + .milliseconds(100))
        #expect(hover.shown == nil)
        hover.pointer(a, isInside: true)
        #expect(try await settle(hover, on: a) == a)
    }

    /// Pictures of the card beside a stand-in sidebar, for a look without launching the app:
    /// `LITHIUM_SNAPSHOT_DIR=/tmp/shots swift test --filter TabHoverCard`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"] != nil))
    func snapshots() throws {
        let directory = URL(filePath: ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Theme.registerFonts()
        let title = "YouTube — Lofi hip hop radio"
        let normal = TabUsage.live(footprint: 312 * 1_048_576, cpu: 4.2, sharedWith: 0)
        let shots: [(String, TabUsage, Bool)] = [
            ("tab-hover-normal", normal, false),
            ("tab-hover-shared", .live(footprint: 486 * 1_048_576, cpu: 0.4, sharedWith: 2), false),
            ("tab-hover-asleep", .asleep, false),
            ("tab-hover-dark", normal, true),
        ]
        for (name, usage, isDark) in shots {
            let renderer = ImageRenderer(content: SnapshotScene(title: title, usage: usage, isDark: isDark))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
            try png.write(to: directory.appending(path: "\(name).png"))
        }
    }
}

/// A stand-in for the window: the sidebar's look with a few tabs, the second one hovered, the
/// page beside it, and the real card where the window puts it.
private struct SnapshotScene: View {
    let title: String
    let usage: TabUsage
    let isDark: Bool

    private static let rows = [
        ("GitHub — DailyXplorer/lithium", "github.com"),
        ("YouTube — Lofi hip hop radio", "youtube.com"),
        ("Le Monde — Actualités en direct", "lemonde.fr"),
        ("Apple Developer Documentation", "developer.apple.com"),
    ]

    var body: some View {
        let hex = isDark ? "#25272F" : Theme.defaultSidebarHex
        let palette = SidebarPalette(style: .solid, colorHex: hex, scheme: isDark ? .dark : .light)
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 8) {
                            Favicon(image: nil, fallback: row.1, size: 16)
                            Text(row.0).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(index == 0 ? palette.selection : index == 1 ? palette.hover : .clear)
                        )
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .frame(width: Layout.sidebarWidth)
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isDark ? Color(white: 0.12) : .white)
                    .shadow(color: .black.opacity(0.14), radius: 1.5, y: 0.5)
                    .padding([.top, .trailing, .bottom], Layout.margin)
            }
            TabHoverCard(title: title, host: "youtube.com", usage: usage)
                .offset(x: Layout.sidebarWidth + 6, y: 12 + 36)
        }
        .frame(width: 580, height: 260)
        .background(Color(hex: hex))
        .foregroundStyle(palette.ink)
        .font(Theme.font(13))
        .environment(\.sidebarPalette, palette)
        .environment(\.colorScheme, isDark ? .dark : .light)
    }
}
