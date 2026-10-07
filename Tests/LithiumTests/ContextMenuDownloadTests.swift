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

    /// A menu download that ends before WebKit asks where to save leaves nothing that would make
    /// a later ordinary download ask.
    @Test func aMenuDownloadFailingBeforeThePanelLeavesNothingBehind() async throws {
        let (listener, base) = try await LocalHTTP.serve([
            "/": ("Content-Type: text/html", #"<img src="/logo.svg">"#),
            "/logo.svg": ("Content-Type: image/svg+xml", Self.svg),
        ])
        defer { listener.cancel() }
        let closing = try await serveClosing()
        defer { closing.listener.cancel() }
        var asked = 0
        Downloads.shared.chooseDestination = { _, _ in
            asked += 1
            return nil
        }
        let browser = Browser()
        let tab = browser.newTab(url: base)
        defer { browser.close(tab) }
        #expect(await waitUntil(30) { !tab.webView.isLoading && tab.webView.url == base })

        let failing = await tab.webView.startDownload(using: URLRequest(url: closing.url.appending(path: "logo.svg")))
        try hand(failing, to: tab)
        let item = try #require(Downloads.shared.items.first)
        #expect(await waitUntil(30) { item.state != .downloading })
        guard case .failed = item.state else {
            Issue.record("expected a failed download, got \(item.state)")
            return
        }
        #expect(asked == 0)
        #expect(Downloads.shared.byDownload[ObjectIdentifier(failing)] == nil)

        try FileManager.default.createDirectory(at: URL.downloadsDirectory, withIntermediateDirectories: true)
        let ordinary = await tab.webView.startDownload(using: URLRequest(url: base.appending(path: "logo.svg")))
        Downloads.shared.track(ordinary)
        let saved = try #require(Downloads.shared.items.first)
        #expect(await waitUntil(30) { saved.state != .downloading })
        #expect(saved.state == .finished)
        #expect(asked == 0)
        let destination = try #require(saved.destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        #expect(destination.deletingLastPathComponent() == URL.downloadsDirectory)
        #expect(try String(contentsOf: destination, encoding: .utf8) == Self.svg)
        #expect(Downloads.shared.byDownload[ObjectIdentifier(ordinary)] == nil)
    }

    /// Two downloads of the same name at once each get a file of their own: WebKit creates the
    /// file only later, so the first one's path is taken as soon as it is given.
    @Test func concurrentDownloadsOfTheSameNameGetTheirOwnFiles() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", "<p>Page</p>")])
        defer { listener.cancel() }
        let name = "report-\(UUID().uuidString.prefix(8))"
        let body = Data(repeating: 0x61, count: 2_000)
        let slow = try await serveSlowly("\(name).bin", body)
        defer { slow.listener.cancel() }
        try FileManager.default.createDirectory(at: URL.downloadsDirectory, withIntermediateDirectories: true)
        let browser = Browser()
        let tab = browser.newTab(url: base)
        defer { browser.close(tab) }
        #expect(await waitUntil(30) { !tab.webView.isLoading && tab.webView.url == base })

        var items: [DownloadItem] = []
        for path in ["one", "two"] {
            let download = await tab.webView.startDownload(using: URLRequest(url: slow.url.appending(path: path)))
            Downloads.shared.track(download)
            items.append(try #require(Downloads.shared.items.first))
        }
        #expect(await waitUntil(30) { items.allSatisfy { $0.state != .downloading } })
        let files = items.compactMap(\.destination)
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(items.allSatisfy { $0.state == .finished })
        #expect(Set(files.map(\.lastPathComponent)) == ["\(name).bin", "\(name) 2.bin"])
        for file in files { #expect(try Data(contentsOf: file) == body) }
    }

    /// A path picked in the save panel that a running download already holds gets a numbered
    /// name: that file isn't on disk yet, so the panel didn't ask about replacing it. Here an
    /// ordinary download takes the suggested name while the panel is open, then the user accepts it.
    @Test func aPathPickedInThePanelThatAnotherDownloadHoldsGetsItsOwnFile() async throws {
        let (listener, base) = try await LocalHTTP.serve(["/": ("Content-Type: text/html", "<p>Page</p>")])
        defer { listener.cancel() }
        let name = "report-\(UUID().uuidString.prefix(8))"
        let body = Data(repeating: 0x62, count: 2_000)
        let slow = try await serveSlowly("\(name).bin", body)
        defer { slow.listener.cancel() }
        try FileManager.default.createDirectory(at: URL.downloadsDirectory, withIntermediateDirectories: true)
        let browser = Browser()
        let tab = browser.newTab(url: base)
        defer { browser.close(tab) }
        #expect(await waitUntil(30) { !tab.webView.isLoading && tab.webView.url == base })

        var ordinary: DownloadItem?
        Downloads.shared.chooseDestination = { proposed, _ in
            let download = await tab.webView.startDownload(using: URLRequest(url: slow.url.appending(path: "ordinary")))
            Downloads.shared.track(download)
            let item = Downloads.shared.items.first
            ordinary = item
            _ = await waitUntil(30) { item?.destination != nil }
            return proposed
        }
        defer { Downloads.shared.chooseDestination = { _, _ in nil } }

        let picked = try await downloadFromMenu(slow.url.appending(path: "picked"), in: tab)
        #expect(await waitUntil(30) { ordinary != nil && picked.state != .downloading && ordinary?.state != .downloading })
        let items = [picked, try #require(ordinary)]
        let files = items.compactMap(\.destination)
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(items.allSatisfy { $0.state == .finished })
        #expect(ordinary?.destination?.lastPathComponent == "\(name).bin")
        #expect(picked.destination?.lastPathComponent == "\(name) 2.bin")
        for file in files { #expect(try Data(contentsOf: file) == body) }
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
        try await serve { connection in
            let head = "HTTP/1.1 200 OK\r\nContent-Type: image/svg+xml\r\nContent-Length: 100000\r\nConnection: close\r\n\r\n"
            let response = Data(head.utf8) + Data(repeating: 0x20, count: 1_000)
            connection.send(content: response, completion: .contentProcessed { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { connection.cancel() }
            })
        }
    }

    /// Closes every connection without a response.
    private func serveClosing() async throws -> (listener: NWListener, url: URL) {
        try await serve { $0.cancel() }
    }

    /// Serves `body` as an attachment named `filename`: half of it, then the rest two seconds
    /// later, so downloads started together run at once.
    private func serveSlowly(_ filename: String, _ body: Data) async throws -> (listener: NWListener, url: URL) {
        try await serve { connection in
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"\(filename)\"\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body.prefix(1_000), completion: .contentProcessed { _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    connection.send(content: body.suffix(1_000), completion: .contentProcessed { _ in connection.cancel() })
                }
            })
        }
    }

    /// Calls `answer` once each connection's request arrives.
    private func serve(_ answer: @escaping @Sendable (NWConnection) -> Void) async throws -> (listener: NWListener, url: URL) {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in answer(connection) }
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
        try hand(download, to: tab)
        return try #require(Downloads.shared.items.first)
    }

    private func hand(_ download: WKDownload, to tab: Tab) throws {
        let selector = NSSelectorFromString("_webView:contextMenuDidCreateDownload:")
        try #require(tab.responds(to: selector))
        tab.perform(selector, with: tab.webView, with: download)
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
