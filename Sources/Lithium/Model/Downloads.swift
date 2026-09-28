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
    @ObservationIgnored private var observation: NSKeyValueObservation?

    fileprivate init(download: WKDownload, filename: String) {
        self.download = download
        self.filename = filename
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
    fileprivate init(filename: String) {
        self.filename = filename
    }

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

/// Every download of the session, newest first. Files land in ~/Downloads.
@MainActor
@Observable
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    private(set) var items: [DownloadItem] = []
    /// Set when a download finishes while the list is closed; the toolbar button shows a dot.
    var hasUnseen = false

    @ObservationIgnored private var byDownload: [ObjectIdentifier: DownloadItem] = [:]
    /// Names taken by files still being written, which don't exist on disk yet.
    @ObservationIgnored private var reserved: Set<URL> = []

    var active: [DownloadItem] { items.filter { $0.state == .downloading } }

    /// Combined progress of running downloads, when their sizes are known.
    var overallFraction: Double? {
        let running = active
        let total = running.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
        guard !running.isEmpty, total > 0 else { return nil }
        return Double(running.reduce(Int64(0)) { $0 + $1.completedBytes }) / Double(total)
    }

    func track(_ download: WKDownload) {
        download.delegate = self
        let item = DownloadItem(download: download, filename: download.originalRequest?.url?.lastPathComponent ?? "Download")
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
        let item = DownloadItem(filename: destination.lastPathComponent)
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
        let destination = destination(for: suggestedFilename)
        byDownload[ObjectIdentifier(download)]?.setDestination(destination)
        return destination
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
        guard let item = byDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
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
        guard let item = byDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if item.state == .downloading { item.finish(.failed(error.localizedDescription)) }
    }
}
