import Foundation

/// Names a download whose file name says nothing, before WebKit writes it: rules first, the
/// on-device model when it answers within `budget`. Off by default: an unasked rename surprises.
@MainActor
final class TidyDownloads {
    static let preferenceKey = "tidyDownloads"
    /// The longest a download waits for the model before it starts under the rules' name.
    static let budget = Duration.seconds(1)

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

    func applies(to filename: String) -> Bool {
        isEnabled && DownloadNames.isGeneric(filename)
    }

    /// Loads the model as a download starts: WebKit asks for its name a moment later.
    func prepare() {
        guard isEnabled, namer == nil, #available(macOS 26.0, *), let model = model as? ModelFileNames else { return }
        model.prepare()
    }

    /// The file name to use instead of the site's, with its extension, or nil to keep it.
    func name(for source: DownloadSource) async -> String? {
        guard applies(to: source.filename) else { return nil }
        var name = DownloadNames.ruleName(source)
        if let ask = asker(), source.title?.isEmpty == false,
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
