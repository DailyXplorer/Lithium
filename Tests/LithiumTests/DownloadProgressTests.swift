import AppKit
import Foundation
import Observation
import Testing
@testable import Lithium

/// WebKit reports every chunk; the toolbar ring and the list redraw only when the count shows.
@MainActor
struct DownloadProgressTests {
    private func redraws(_ item: DownloadItem, _ change: () -> Void) -> Bool {
        let changed = Flag()
        withObservationTracking {
            _ = item.completedBytes
            _ = item.totalBytes
        } onChange: { changed.value = true }
        change()
        return changed.value
    }

    /// Set synchronously on this actor by the change itself.
    private final class Flag: @unchecked Sendable { var value = false }

    @Test func progressShowsByThePercentOrTheQuarterSecond() {
        let item = DownloadItem(filename: "big.zip", size: 0)
        let start = Date()
        item.receive(completed: 100, total: 100_000, at: start)
        #expect(item.completedBytes == 100)
        #expect(item.totalBytes == 100_000)

        #expect(!redraws(item) { item.receive(completed: 500, total: 100_000, at: start.addingTimeInterval(0.01)) })
        #expect(item.completedBytes == 100, "under 1% and soon after: held back")

        #expect(redraws(item) { item.receive(completed: 1_200, total: 100_000, at: start.addingTimeInterval(0.02)) })
        #expect(item.completedBytes == 1_200, "1% further")

        item.receive(completed: 1_300, total: 100_000, at: start.addingTimeInterval(0.3))
        #expect(item.completedBytes == 1_300, "a quarter second later")
    }

    @Test func anUnknownSizeShowsEveryQuarterSecond() {
        let item = DownloadItem(filename: "stream", size: 0)
        let start = Date()
        item.receive(completed: 10, total: -1, at: start)
        #expect(!redraws(item) { item.receive(completed: 5_000_000, total: -1, at: start.addingTimeInterval(0.1)) })
        item.receive(completed: 6_000_000, total: -1, at: start.addingTimeInterval(0.3))
        #expect(item.completedBytes == 6_000_000)
    }

    /// The last count held back still shows once the download ends, and a late report never lowers it.
    @Test func theEndShowsTheLastCount() {
        let item = DownloadItem(filename: "big.zip", size: 0)
        let start = Date()
        item.receive(completed: 100, total: 100_000, at: start)
        item.receive(completed: 400, total: 100_000, at: start)
        item.finish(.finished)
        #expect(item.completedBytes == 400)
        item.receive(completed: 300, total: 100_000, at: start)
        #expect(item.completedBytes == 400)
    }

    /// The list's row looks the icon up once the file exists, not on each redraw.
    @Test func theRowIconIsLookedUpOncePerFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        let item = DownloadItem(filename: file.lastPathComponent, size: 1)
        item.setDestination(file)
        _ = item.fileIcon
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let icon = item.fileIcon
        #expect(item.fileIcon === icon)
    }
}
