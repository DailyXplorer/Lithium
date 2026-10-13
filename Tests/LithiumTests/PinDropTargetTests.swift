import Foundation
import Testing
@testable import Lithium

/// The favorites grid finds the slot a drop lands on from each tile's frame.
struct PinDropTargetTests {
    private let a = UUID(), b = UUID(), c = UUID()

    /// Two 40×48 tiles side by side with an 8 pt gap, the third on the next row.
    private var frames: [Pin.ID: CGRect] {
        [a: CGRect(x: 0, y: 0, width: 40, height: 48),
         b: CGRect(x: 48, y: 0, width: 40, height: 48),
         c: CGRect(x: 0, y: 56, width: 40, height: 48)]
    }

    private func slot(_ x: CGFloat, _ y: CGFloat, frames: [Pin.ID: CGRect]? = nil) -> Int? {
        favoriteSlot(at: CGPoint(x: x, y: y), order: [a, b, c], frames: frames ?? self.frames)
    }

    @Test func onATileIsItsSlot() {
        #expect(slot(20, 24) == 0)
        #expect(slot(60, 10) == 1)
        #expect(slot(5, 100) == 2)
    }

    @Test func betweenTilesIsTheEnd() {
        #expect(slot(44, 24) == nil)
        #expect(slot(20, 52) == nil)
    }

    @Test func emptySpaceIsTheEnd() {
        #expect(slot(120, 24) == nil)
        #expect(slot(60, 80) == nil)
        #expect(slot(-1, 24) == nil)
    }

    @Test func aTileOwnsItsTopLeftEdgeButNotItsBottomRight() {
        #expect(slot(48, 0) == 1)
        #expect(slot(40, 24) == nil)
        #expect(slot(20, 48) == nil)
    }

    @Test func aTileNotYetMeasuredIsSkipped() {
        var frames = frames
        frames[b] = nil
        #expect(slot(60, 10, frames: frames) == nil)
        #expect(slot(5, 100, frames: frames) == 2)
    }

    /// A drop target on a favorite tile swallows its right-click, so the tile's context menu (with
    /// "Unpin") never opens. The menu needs a window on screen, so this guards the tile's source instead.
    @Test func favoriteTilesHaveNoDropTargetOfTheirOwn() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/Lithium/Views/SidebarView.swift").standardized
        let source = try String(contentsOf: file, encoding: .utf8)
        let tile = try #require(source.components(separatedBy: "private struct PinTile: View {").dropFirst().first?
            .components(separatedBy: "\nprivate struct ").first)
        #expect(tile.contains(".contextMenu"))
        #expect(!tile.contains(".dropDestination"))
        #expect(!tile.contains(".onDrop"))
    }
}
