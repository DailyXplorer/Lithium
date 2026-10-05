import AppKit
import Observation
import WebKit

@MainActor
@Observable
final class DownloadItem: Identifiable {
    enum State: Equatable {
        case downloading
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let started = Date()
    private(set) var filename: String
    private(set) var destination: URL?
    private(set) var state = State.downloading
    private(set) var completedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = -1

    @ObservationIgnored fileprivate weak var download: WKDownload?
    /// Asks where to save before it starts, as a download from the page menu does.
    @ObservationIgnored fileprivate let asksWhere: Bool
    @ObservationIgnored private var observation: NSKeyValueObservation?

    fileprivate init(download: WKDownload, filename: String, asksWhere: Bool) {
        self.download = download
        self.filename = filename
        self.asksWhere = asksWhere
        observation = download.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor in
                self?.completedBytes = completed
                self?.totalBytes = total
            }
        }
    }

    /// A file Lithium already holds, written at once.
    fileprivate init(filename: String, size: Int) {
        self.filename = filename
        asksWhere = false
        completedBytes = Int64(size)
        totalBytes = Int64(size)
    }

    /// Only a transfer can be cancelled; a file Lithium writes itself takes an instant.
    var canCancel: Bool { download != nil }

    var fraction: Double? {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : nil
    }

    fileprivate func setDestination(_ url: URL) {
        destination = url
        filename = url.lastPathComponent
    }

    fileprivate func finish(_ state: State) {
        self.state = state
        observation = nil
        if state == .finished, totalBytes <= 0 { totalBytes = completedBytes }
    }

    func cancel() {
        download?.cancel()
        finish(.cancelled)
    }
}

/// Every download of the session, newest first. Files land in ~/Downloads, or where the user
/// picks for a download from the page menu.
@MainActor
@Observable
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    private(set) var items: [DownloadItem] = []
    /// Set when a download finishes while the list is closed; the toolbar button shows a dot.
    var hasUnseen = false

    /// Transfers still running. An entry goes when its download ends, and `track` replaces any
    /// left by a download whose address a new one reuses.
    @ObservationIgnored private(set) var byDownload: [ObjectIdentifier: DownloadItem] = [:]
    /// Names taken by files still being written, which don't exist on disk yet.
    @ObservationIgnored private var reserved: Set<URL> = []
    /// Where downloads replacing a file are written until they finish; the item shows the file replaced.
    @ObservationIgnored private var partials: [ObjectIdentifier: URL] = [:]
    /// Asks where to save, starting from the name and folder given; nil when the user cancels.
    /// Tests replace it, so no panel shows.
    @ObservationIgnored var chooseDestination: @MainActor (URL, NSWindow?) async -> URL? = Downloads.savePanel(suggesting:in:)

    var active: [DownloadItem] { items.filter { $0.state == .downloading } }

    /// Combined progress of running downloads, when their sizes are known.
    var overallFraction: Double? {
        let running = active
        let total = running.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
        guard !running.isEmpty, total > 0 else { return nil }
        return Double(running.reduce(Int64(0)) { $0 + $1.completedBytes }) / Double(total)
    }

    func track(_ download: WKDownload, askingWhere: Bool = false) {
        download.delegate = self
        let item = DownloadItem(download: download, filename: download.originalRequest?.url?.lastPathComponent ?? "Download", asksWhere: askingWhere)
        byDownload[ObjectIdentifier(download)] = item
        items.insert(item, at: 0)
    }

    func clearFinished() {
        items.removeAll { $0.state != .downloading }
    }

    /// Bytes Lithium already has (a PDF it shows), saved like a download.
    func save(_ data: Data, suggestedFilename: String) {
        let destination = destination(for: suggestedFilename)
        reserved.insert(destination)
        let item = DownloadItem(filename: destination.lastPathComponent, size: data.count)
        item.setDestination(destination)
        items.insert(item, at: 0)
        // Off the main thread: a large file on a slow disk would freeze the window.
        Task {
            let written = await Task.detached {
                Result { try data.write(to: destination, options: .withoutOverwriting) }
            }.value
            reserved.remove(destination)
            switch written {
            case .success:
                item.finish(.finished)
                didFinish(item)
            case .failure(let error):
                item.finish(.failed(error.localizedDescription))
            }
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let id = ObjectIdentifier(download)
        var destination = destination(for: suggestedFilename)
        if byDownload[id]?.asksWhere == true {
            // Cancelled from the list before WebKit asked.
            guard byDownload[id]?.state == .downloading else { return nil }
            guard let chosen = await chooseDestination(destination, download.webView?.window) else {
                if let item = byDownload.removeValue(forKey: id) { items.removeAll { $0 === item } }
                return nil
            }
            // Cancelled from the list while the panel was open.
            guard byDownload[id]?.state == .downloading else { return nil }
            destination = chosen
            // The panel already asked whether to replace a file of that name. WebKit won't write
            // over it, and the old one must stay until the new one is complete: the download goes
            // to a hidden file beside it, swapped in when it finishes.
            if FileManager.default.fileExists(atPath: chosen.path) {
                let partial = chosen.deletingLastPathComponent().appending(path: ".\(chosen.lastPathComponent).\(UUID().uuidString.prefix(8)).lithium-download")
                partials[id] = partial
                byDownload[id]?.setDestination(chosen)
                return partial
            }
        }
        byDownload[id]?.setDestination(destination)
        return destination
    }

    private static func savePanel(suggesting destination: URL, in window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = destination.deletingLastPathComponent()
        panel.nameFieldStringValue = destination.lastPathComponent
        let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        return response == .OK ? panel.url : nil
    }

    /// In ~/Downloads, numbered when the name is taken.
    private func destination(for suggestedFilename: String) -> URL {
        let folder = URL.downloadsDirectory
        let name = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var destination = folder.appending(path: suggestedFilename)
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) || reserved.contains(destination) {
            counter += 1
            destination = folder.appending(path: ext.isEmpty ? "\(name) \(counter)" : "\(name) \(counter).\(ext)")
        }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        guard let item = byDownload.removeValue(forKey: id) else { return }
        if let partial = partials.removeValue(forKey: id), let destination = item.destination {
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
                } else {
                    try FileManager.default.moveItem(at: partial, to: destination)
                }
            } catch {
                try? FileManager.default.removeItem(at: partial)
                item.finish(.failed(error.localizedDescription))
                return
            }
        }
        item.finish(.finished)
        didFinish(item)
    }

    private func didFinish(_ item: DownloadItem) {
        hasUnseen = true
        if let destination = item.destination {
            // Makes the Downloads stack bounce in the Dock, like Safari.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: destination.path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let id = ObjectIdentifier(download)
        if let partial = partials.removeValue(forKey: id) { try? FileManager.default.removeItem(at: partial) }
        guard let item = byDownload.removeValue(forKey: id) else { return }
        if item.state == .downloading { item.finish(.failed(error.localizedDescription)) }
    }
}
