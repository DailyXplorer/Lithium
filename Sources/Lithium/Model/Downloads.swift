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
    /// The name the site gave a file Lithium renamed, until the user goes back to it.
    private(set) var originalFilename: String?
    private(set) var state = State.downloading
    private(set) var completedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = -1

    @ObservationIgnored fileprivate weak var download: WKDownload?
    @ObservationIgnored fileprivate weak var list: Downloads?
    /// Asks where to save before it starts, as a download from the page menu does.
    @ObservationIgnored fileprivate let asksWhere: Bool
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// The renamed file's identity when it finished: "Use original name" moves only that file.
    @ObservationIgnored fileprivate var fileIdentity: [Int]?

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

    init(filename: String, size: Int) {
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

    func setDestination(_ url: URL, renamedFrom original: String? = nil) {
        destination = url
        filename = url.lastPathComponent
        originalFilename = original
    }

    func finish(_ state: State) {
        self.state = state
        observation = nil
        if state == .finished, totalBytes <= 0 { totalBytes = completedBytes }
    }

    func cancel() {
        if let download {
            download.cancel()
            list?.didCancel(download)
        }
        finish(.cancelled)
    }

    /// Only a finished file can go back to its name: WebKit is still writing the other.
    var canUseOriginalName: Bool { originalFilename != nil && state == .finished }

    func useOriginalName() {
        list?.useOriginalName(self)
    }
}

/// Every download of the session, newest first.
@MainActor
@Observable
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    private(set) var items: [DownloadItem] = []
    /// Set when a download finishes while the list is closed; the toolbar button shows a dot.
    var hasUnseen = false
    /// Set by the list while it shows: a download finishing in front of the user is seen.
    @ObservationIgnored var isListShown = false {
        didSet { if isListShown { hasUnseen = false } }
    }

    @ObservationIgnored private(set) var byDownload: [ObjectIdentifier: DownloadItem] = [:]
    /// Names taken by files still being written, which don't exist on disk yet.
    @ObservationIgnored private var reserved: Set<URL> = []
    /// The destination given to each running transfer, until it ends: WebKit only creates the
    /// file later, so another download of the same name would get the same path.
    @ObservationIgnored private var destinations: [ObjectIdentifier: URL] = [:]
    /// Where downloads replacing a file are written until they finish; the item shows the file replaced.
    @ObservationIgnored private var partials: [ObjectIdentifier: URL] = [:]
    /// Asks where to save; nil when the user cancels. Tests replace it, so no panel shows.
    @ObservationIgnored var chooseDestination: @MainActor (URL, NSWindow?) async -> URL? = Downloads.savePanel(suggesting:in:)
    /// Names downloads whose file name says nothing, when turned on in Max.
    @ObservationIgnored let tidy = TidyDownloads()

    var active: [DownloadItem] { items.filter { $0.state == .downloading } }

    var overallFraction: Double? {
        let running = active
        // In Double: two server-given sizes near Int64.max would overflow an Int64 sum.
        let total = running.reduce(0.0) { $0 + Double(max(0, $1.totalBytes)) }
        guard !running.isEmpty, total > 0 else { return nil }
        return running.reduce(0.0) { $0 + Double(max(0, $1.completedBytes)) } / total
    }

    func track(_ download: WKDownload, askingWhere: Bool = false) {
        download.delegate = self
        let item = DownloadItem(download: download, filename: download.originalRequest?.url?.lastPathComponent ?? "Download", asksWhere: askingWhere)
        item.list = self
        byDownload[ObjectIdentifier(download)] = item
        destinations[ObjectIdentifier(download)] = nil
        // One left by a cancelled download reusing this address would be swapped in at the finish.
        partials[ObjectIdentifier(download)] = nil
        items.insert(item, at: 0)
        tidy.prepare()
    }

    func clearFinished() {
        items.removeAll { $0.state != .downloading }
    }

    /// Bytes Lithium already has (a PDF it shows), saved like a download.
    func save(_ data: Data, suggestedFilename: String, from source: URL?, title: String? = nil) {
        let item = DownloadItem(filename: suggestedFilename, size: data.count)
        item.list = self
        items.insert(item, at: 0)
        guard tidy.applies(to: suggestedFilename) else {
            return place(data, item, as: suggestedFilename, from: source)
        }
        Task {
            let tidied = await tidy.name(for: DownloadSource(filename: suggestedFilename, title: title, page: source, file: source))
            place(data, item, as: tidied ?? suggestedFilename, from: source, renamedFrom: tidied.map { _ in suggestedFilename })
        }
    }

    private func place(_ data: Data, _ item: DownloadItem, as filename: String, from source: URL?, renamedFrom original: String? = nil) {
        let destination = destination(for: filename)
        reserved.insert(destination)
        item.setDestination(destination, renamedFrom: original)
        // Off the main thread: a large file on a slow disk would freeze the window.
        Task {
            let written = await Task.detached {
                Result { try Self.write(data, to: destination, from: source) }
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

    /// Into a hidden file moved into place once complete: a full disk or a crash midway never
    /// leaves a truncated file under the real name.
    nonisolated static func write(_ data: Data, to destination: URL, from source: URL?) throws {
        let partial = partialFile(for: destination)
        do {
            try data.write(to: partial, options: .withoutOverwriting)
            quarantine(partial, from: source)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Fixed length: a name built from the file's could pass the 255-byte limit.
    nonisolated private static func partialFile(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).lithium-download")
    }

    /// Quarantines the file as WebKit does its downloads, so macOS asks before it first opens.
    /// Only a web address is kept: a `data:` one would be the whole file again.
    nonisolated static func quarantine(_ file: URL, from source: URL?) {
        var properties: [String: Any] = [kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String]
        if let source, ["http", "https"].contains(source.scheme?.lowercased()) {
            properties[kLSQuarantineDataURLKey as String] = source
        }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var file = file
        try? file.setResourceValues(values)
    }

    /// At most 255 bytes: a longer name is cut before `tail` (number and extension), which stays whole.
    nonisolated static func fileName(_ name: String, _ tail: String = "") -> String {
        var name = name
        while name.utf8.count + tail.utf8.count > 255, !name.isEmpty { name.removeLast() }
        return name + tail
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let id = ObjectIdentifier(download)
        var filename = suggestedFilename
        var original: String?
        if byDownload[id]?.asksWhere == false, tidy.applies(to: suggestedFilename) {
            let webView = download.webView
            // The page shown, not one still loading: a link that turned into this download.
            let source = DownloadSource(filename: suggestedFilename, title: webView?.title, page: webView?.backForwardList.currentItem?.url, file: response.url)
            if let tidied = await tidy.name(for: source) {
                // Cancelled from the list while it was named.
                guard byDownload[id]?.state == .downloading else { return nil }
                filename = tidied
                original = suggestedFilename
            }
        }
        var destination = destination(for: filename)
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
            // Another running download holds that path (not on disk yet, so the panel didn't ask).
            if takenDestinations().contains(chosen) {
                destination = self.destination(for: chosen.lastPathComponent, in: chosen.deletingLastPathComponent())
            }
            // The panel already asked to replace it, but WebKit won't write over a file: download
            // to a hidden file beside it, swapped in when it finishes.
            if FileManager.default.fileExists(atPath: destination.path) {
                let partial = Self.partialFile(for: destination)
                partials[id] = partial
                take(destination, for: id)
                return partial
            }
        }
        take(destination, for: id, renamedFrom: original)
        return destination
    }

    private func take(_ destination: URL, for id: ObjectIdentifier, renamedFrom original: String? = nil) {
        byDownload[id]?.setDestination(destination, renamedFrom: original)
        destinations[id] = destination
    }

    /// Only while the file is where Lithium put it: one the user has moved or renamed is theirs.
    fileprivate func useOriginalName(_ item: DownloadItem) {
        guard item.canUseOriginalName, let original = item.originalFilename, let current = item.destination else { return }
        guard let identity = item.fileIdentity, identity == Self.fileIdentity(of: current) else {
            item.setDestination(current)
            return
        }
        let target = destination(for: original, in: current.deletingLastPathComponent())
        guard (try? FileManager.default.moveItem(at: current, to: target)) != nil else { return }
        item.setDestination(target)
    }

    /// Volume and file number, which a rename or move within the volume keeps.
    nonisolated private static func fileIdentity(of file: URL) -> [Int]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let volume = attributes[.systemNumber] as? Int, let number = attributes[.systemFileNumber] as? Int else { return nil }
        return [volume, number]
    }

    private static func savePanel(suggesting destination: URL, in window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = destination.deletingLastPathComponent()
        panel.nameFieldStringValue = destination.lastPathComponent
        let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        return response == .OK ? panel.url : nil
    }

    private func destination(for suggestedFilename: String, in folder: URL = .downloadsDirectory) -> URL {
        let name = (suggestedFilename as NSString).deletingPathExtension
        let pathExtension = (suggestedFilename as NSString).pathExtension
        let ext = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        var destination = folder.appending(path: suggestedFilename.utf8.count > 255 ? Self.fileName(name, ext) : suggestedFilename)
        var counter = 1
        let taken = takenDestinations()
        while FileManager.default.fileExists(atPath: destination.path) || taken.contains(destination) {
            counter += 1
            destination = folder.appending(path: Self.fileName(name, " \(counter)\(ext)"))
        }
        return destination
    }

    private func takenDestinations() -> Set<URL> {
        // A transfer cancelled from the list may never hear back from WebKit.
        destinations = destinations.filter { byDownload[$0.key]?.state == .downloading }
        return reserved.union(destinations.values)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        destinations[id] = nil
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

    func didFinish(_ item: DownloadItem) {
        if !isListShown { hasUnseen = true }
        if item.originalFilename != nil, let destination = item.destination { item.fileIdentity = Self.fileIdentity(of: destination) }
        if let destination = item.destination {
            // Makes the Downloads stack bounce in the Dock, like Safari.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: destination.path)
        }
    }

    /// WebKit may never report a download cancelled from the list: remove its hidden file now.
    fileprivate func didCancel(_ download: WKDownload) {
        if let partial = partials.removeValue(forKey: ObjectIdentifier(download)) { try? FileManager.default.removeItem(at: partial) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let id = ObjectIdentifier(download)
        destinations[id] = nil
        if let partial = partials.removeValue(forKey: id) { try? FileManager.default.removeItem(at: partial) }
        guard let item = byDownload.removeValue(forKey: id) else { return }
        if item.state == .downloading { item.finish(.failed(error.localizedDescription)) }
    }
}
