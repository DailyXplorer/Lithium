import Foundation

/// Gives every download a clear name before WebKit writes it: the on-device model when it answers
/// within `budget`, else the rules for a name that says nothing, else the site's name. Off by
/// default: an unasked rename surprises.
@MainActor
final class TidyDownloads {
    static let preferenceKey = "tidyDownloads"
    /// The longest a download waits for the model before it starts under the rules' or site's
    /// name. The model answers in well under a second once `prepare` has loaded it.
    static let budget = Duration.seconds(2)
    /// Unfinished files from another browser or a resumable transfer: renaming one breaks the resume.
    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial"]

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.preferenceKey) }
    }

    /// Stands in for Apple's model in tests.
    var namer: (@MainActor (DownloadSource) async -> String?)?

    /// Made on first use, so nothing loads while the feature is off.
    private lazy var model: AnyObject? = {
        if #available(macOS 26.0, *) { ModelFileNames() } else { nil }
    }()

    init(isEnabled: Bool = UserDefaults.standard.bool(forKey: TidyDownloads.preferenceKey)) {
        self.isEnabled = isEnabled
    }

    /// Never for a name the user typed in a save panel.
    func applies(to filename: String, asksWhere: Bool = false) -> Bool {
        isEnabled && !asksWhere && !Self.partialExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    /// Loads the model as a download starts: WebKit asks for its name a moment later.
    func prepare() {
        guard isEnabled, namer == nil, #available(macOS 26.0, *), let model = model as? ModelFileNames else { return }
        model.prepare()
    }

    /// The file name to use instead of the site's, with its extension, or nil to keep it.
    func name(for source: DownloadSource) async -> String? {
        guard applies(to: source.filename) else { return nil }
        // Only a web address reaches the model, from a save or a WebKit download: a `data:` one's
        // path is the file itself.
        var source = source
        let web: (URL?) -> URL? = { $0.flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil } }
        source.page = web(source.page)
        source.file = web(source.file)
        var name = DownloadNames.isGeneric(source.filename) ? DownloadNames.ruleName(source) : nil
        if let ask = asker(),
           let answer = await Self.first(within: Self.budget, { await ask(source) }),
           let accepted = DownloadNames.acceptable(answer, for: source) {
            name = accepted
        }
        guard let name else { return nil }
        let renamed = DownloadNames.fileName(name, keepingExtensionOf: source.filename)
        return renamed == source.filename ? nil : renamed
    }

    private func asker() -> (@MainActor (DownloadSource) async -> String?)? {
        if let namer { return namer }
        if #available(macOS 26.0, *), let model = model as? ModelFileNames, model.isAvailable {
            return { await model.name(for: $0) }
        }
        return nil
    }

    /// `work`'s answer, or nil once `budget` has passed: WebKit holds the download until it has
    /// a name. A late answer is dropped.
    private static func first(within budget: Duration, _ work: @escaping @MainActor () async -> String?) async -> String? {
        let race = Race()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            let task = Task { race.finish(await work()) }
            race.timer = Task {
                try? await Task.sleep(for: budget)
                task.cancel()
                race.finish(nil)
            }
        }
    }

    @MainActor
    private final class Race {
        var continuation: CheckedContinuation<String?, Never>?
        var timer: Task<Void, Never>?

        func finish(_ answer: String?) {
            timer?.cancel()
            continuation?.resume(returning: answer)
            continuation = nil
        }
    }
}
