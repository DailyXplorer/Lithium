import Foundation
import Network
import Testing
import WebKit
@testable import Lithium

/// The page menu's Download Image, Download Linked File and Download Video: WebKit starts the
/// download and hands it to the tab through `_webView:contextMenuDidCreateDownload:`, called
/// here by that selector as WebKit does. A whole Browser keeps its data in the home folder, so
/// this suite only runs in a throwaway one:
/// `CFFIXED_USER_HOME=$(mktemp -d) swift test --filter ContextMenuDownloadTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct ContextMenuDownloadTests {
    private static let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>"#

    @Test func savesWhereTheUserChooses() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", #"<img src="/images/logo.svg">"#),
            "/images/logo.svg": ("Content-Type: image/svg+xml", Self.svg),
            "/photo?id=7": ("Content-Type: image/svg+xml\r\nContent-Disposition: attachment; filename=\"sunset.svg\"", Self.svg),
        ])
        defer { listener.cancel() }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var suggested: [URL] = []
        Downloads.shared.chooseDestination = { proposed, _ in
            suggested.append(proposed)
            return folder.appending(path: "Chosen \(proposed.lastPathComponent)")
        }
        defer { Downloads.shared.chooseDestination = { _, _ in nil } }
        let browser = Browser()
        let tab = browser.newTab(url: base)
        defer { browser.close(tab) }
        #expect(await waitUntil(30) { !tab.webView.isLoading && tab.webView.url == base })

        for path in ["images/logo.svg", "photo?id=7"] {
            let item = try await downloadFromMenu(URL(string: path, relativeTo: base)!, in: tab)
            #expect(await waitUntil(30) { item.state != .downloading })
            #expect(item.state == .finished)
        }

        #expect(suggested.map(\.lastPathComponent) == ["logo.svg", "sunset.svg"])
        #expect(suggested.allSatisfy { $0.deletingLastPathComponent() == URL.downloadsDirectory })
        let saved = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(saved == ["Chosen logo.svg", "Chosen sunset.svg"])
        #expect(try String(contentsOf: folder.appending(path: "Chosen logo.svg"), encoding: .utf8) == Self.svg)
        #expect(Downloads.shared.items.prefix(2).map(\.filename) == ["Chosen sunset.svg", "Chosen logo.svg"])
    }

    @Test func cancellingTheSavePanelDownloadsNothing() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", #"<img src="/logo.svg">"#),
            "/logo.svg": ("Content-Type: image/svg+xml", Self.svg),
        ])
        defer { listener.cancel() }
        var asked = 0
        Downloads.shared.chooseDestination = { _, _ in
            asked += 1
            return nil
        }
        let browser = Browser()
        let tab = browser.newTab(url: base)
        defer { browser.close(tab) }
        #expect(await waitUntil(30) { !tab.webView.isLoading && tab.webView.url == base })
        let before = Downloads.shared.items.count

        let item = try await downloadFromMenu(base.appending(path: "logo.svg"), in: tab)
        #expect(await waitUntil(30) { asked == 1 })
        try await Task.sleep(for: .milliseconds(500))
        #expect(Downloads.shared.items.count == before)
        #expect(!Downloads.shared.items.contains { $0 === item })
        #expect(!FileManager.default.fileExists(atPath: URL.downloadsDirectory.appending(path: "logo.svg").path))
    }

    /// A file the user chose to replace is only replaced once the new one is complete.
    @Test func replacesAFileOnceTheDownloadIsComplete() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", #"<img src="/logo.svg">"#),
            "/logo.svg": ("Content-Type: image/svg+xml", Self.svg),
        ])
        defer { listener.cancel() }
        let (folder, file) = try existingFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        Downloads.shared.chooseDestination = { _, _ in file }
        defer { Downloads.shared.chooseDestination = { _, _ in nil } }
        let browser = Browser()
        let tab = browser.newTab(url: base)
        defer { browser.close(tab) }
        #expect(await waitUntil(30) { !tab.webView.isLoading && tab.webView.url == base })

        let item = try await downloadFromMenu(base.appending(path: "logo.svg"), in: tab)
        #expect(item.filename == "logo.svg")
        #expect(await waitUntil(30) { item.state != .downloading })
        #expect(item.state == .finished)
        #expect(item.filename == "logo.svg")
        #expect(try String(contentsOf: file, encoding: .utf8) == Self.svg)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["logo.svg"])
    }

    @Test func aFailedDownloadLeavesTheFileItWouldReplace() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", "<p>Page</p>")])
        defer { listener.cancel() }
        let truncated = try await serveTruncated()
        defer { truncated.listener.cancel() }
        let (folder, file) = try existingFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        Downloads.shared.chooseDestination = { _, _ in file }
        defer { Downloads.shared.chooseDestination = { _, _ in nil } }
        let browser = Browser()
        let tab = browser.newTab(url: base)
        defer { browser.close(tab) }
        #expect(await waitUntil(30) { !tab.webView.isLoading && tab.webView.url == base })

        let item = try await downloadFromMenu(truncated.url.appending(path: "logo.svg"), in: tab)
        #expect(await waitUntil(30) { item.state != .downloading })
        guard case .failed = item.state else {
            Issue.record("expected a failed download, got \(item.state)")
            return
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["logo.svg"])
    }

    @Test func cancellingWhileThePanelIsOpenKeepsTheFile() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", #"<img src="/logo.svg">"#),
            "/logo.svg": ("Content-Type: image/svg+xml", Self.svg),
        ])
        defer { listener.cancel() }
        let (folder, file) = try existingFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        Downloads.shared.chooseDestination = { _, _ in
            Downloads.shared.items.first?.cancel()
            return file
        }
        defer { Downloads.shared.chooseDestination = { _, _ in nil } }
        let browser = Browser()
        let tab = browser.newTab(url: base)
        defer { browser.close(tab) }
        #expect(await waitUntil(30) { !tab.webView.isLoading && tab.webView.url == base })

        let item = try await downloadFromMenu(base.appending(path: "logo.svg"), in: tab)
        #expect(await waitUntil(30) { item.state != .downloading })
        try await Task.sleep(for: .milliseconds(500))
        #expect(item.state == .cancelled)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["logo.svg"])
    }

    /// A folder holding `logo.svg`, which says "original".
    private func existingFile() throws -> (folder: URL, file: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "logo.svg")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        return (folder, file)
    }

    /// Answers every request with the start of a body far longer, then closes the connection.
    private func serveTruncated() async throws -> (listener: NWListener, url: URL) {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let head = "HTTP/1.1 200 OK\r\nContent-Type: image/svg+xml\r\nContent-Length: 100000\r\nConnection: close\r\n\r\n"
                let response = Data(head.utf8) + Data(repeating: 0x20, count: 1_000)
                connection.send(content: response, completion: .contentProcessed { _ in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { connection.cancel() }
                })
            }
        }
        listener.start(queue: .global())
        for _ in 0..<500 {
            if let port = listener.port, listener.state == .ready {
                return (listener, URL(string: "http://127.0.0.1:\(port.rawValue)/")!)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        listener.cancel()
        throw URLError(.cannotConnectToHost)
    }

    /// Starts the download the way the menu item does, and hands it to the tab as WebKit does.
    private func downloadFromMenu(_ url: URL, in tab: Tab) async throws -> DownloadItem {
        let download = await tab.webView.startDownload(using: URLRequest(url: url))
        let selector = NSSelectorFromString("_webView:contextMenuDidCreateDownload:")
        try #require(tab.responds(to: selector))
        tab.perform(selector, with: tab.webView, with: download)
        return try #require(Downloads.shared.items.first)
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
