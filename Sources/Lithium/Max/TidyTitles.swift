import Foundation
import Observation

/// Short tab titles: rules first; the on-device model only for titles still too long, once per site and title.
@MainActor
@Observable
final class TidyTitles {
    static let preferenceKey = "tidyTabTitles"

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.preferenceKey) }
    }

    /// Keyed by host and rule-cleaned title, so a changing counter ("(3) Inbox") reuses the answer.
    @ObservationIgnored private var cache: [String: String] = [:]
    /// Every tab that showed the title while it was asked gets the answer, not only the one that asked.
    @ObservationIgnored private var pending: [String: [WaitingTab]] = [:]
    /// The last model request: each waits for the one before.
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private let model: AnyObject?
    /// Stands in for Apple's model in tests.
    @ObservationIgnored var shortener: (@MainActor (_ title: String, _ host: String) async -> TitleOutcome)?

    private struct WaitingTab {
        weak var tab: Tab?
        /// The title it had: the answer is only for a tab still showing it.
        let original: String

        @MainActor var isCurrent: Bool { tab?.title == original }
    }

    private static let cacheLimit = 500

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? true
        if #available(macOS 26.0, *) {
            model = ModelTitles()
        } else {
            model = nil
        }
    }

    var modelStatus: (available: Bool, message: String) {
        guard #available(macOS 26.0, *), let model = model as? ModelTitles else {
            return (false, "Requires macOS 26 or later. Basic tidying still works.")
        }
        switch model.availability {
        case .available:
            return (true, "")
        case .unavailable(.appleIntelligenceNotEnabled):
            return (false, "Turn on Apple Intelligence in System Settings. Basic tidying still works.")
        case .unavailable(.modelNotReady):
            return (false, "Still downloading. Basic tidying works meanwhile.")
        case .unavailable(.deviceNotEligible):
            return (false, "Not supported on this Mac. Basic tidying still works.")
        case .unavailable:
            return (false, "Not available right now. Basic tidying still works.")
        }
    }

    /// `askingModel` false (a tab restored asleep) applies the rules only, so launch doesn't queue
    /// a request per tab.
    func update(_ tab: Tab, askingModel: Bool = true) {
        guard isEnabled, let host = tab.url?.host(), tab.url?.scheme?.hasPrefix("http") == true else { return }
        let original = tab.title
        guard !original.isEmpty else { return }

        let cleaned = TitleCleaner.clean(original, host: host)
        let key = host + "\n" + cleaned
        if let cached = cache[key] {
            tab.setTidyTitle(cached, from: original)
            return
        }
        tab.setTidyTitle(cleaned, from: original)
        guard cleaned.count > TitleCleaner.shortEnough else {
            remember(cleaned, for: key)
            return
        }
        guard askingModel else { return }
        let waiting = WaitingTab(tab: tab, original: original)
        guard pending[key] == nil else {
            pending[key]?.append(waiting)
            return
        }

        let shorten: @MainActor (String, String) async -> TitleOutcome
        if let shortener {
            shorten = shortener
        } else if #available(macOS 26.0, *), let model = model as? ModelTitles, model.isAvailable {
            shorten = { await model.shorten($0, host: $1) }
        } else {
            return
        }
        pending[key] = [waiting]
        let previous = queue
        queue = Task {
            // Wait for the title to settle: pages that animate or rewrite it shouldn't reach the model.
            try? await Task.sleep(for: .milliseconds(800))
            // Then for the requests before it, and look again: a title that changed meanwhile (a
            // live count, a clock) never reaches the model.
            await previous?.value
            guard isEnabled, pending[key]?.contains(where: { $0.isCurrent }) == true else {
                pending[key] = nil
                return
            }
            // The model gets the rule-cleaned title: without the site name it can't fall back on it.
            let outcome = await shorten(cleaned, host)
            let tabs = pending.removeValue(forKey: key) ?? []
            switch outcome {
            case .title(let candidate):
                let accepted = TitleCleaner.acceptable(candidate, original: original, host: host) ?? cleaned
                remember(accepted, for: key)
                for waiting in tabs { waiting.tab?.setTidyTitle(accepted, from: waiting.original) }
            case .declined:
                remember(cleaned, for: key)
            case .failed:
                break
            }
        }
    }

    /// Loads the model early, when the feature is on, so the first long title is quick.
    func prepare() {
        guard isEnabled, #available(macOS 26.0, *), let model = model as? ModelTitles else { return }
        model.prepare()
    }

    private func remember(_ title: String, for key: String) {
        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = title
    }
}
