import Foundation
import Observation

/// Max feature: short, readable tab titles. Rules first (instant, free); Apple's on-device model
/// only for titles that are still too long, once per site and title.
@MainActor
@Observable
final class TidyTitles {
    static let preferenceKey = "tidyTabTitles"

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.preferenceKey) }
    }

    /// Keyed by host and rule-cleaned title, so a changing counter ("(3) Inbox") reuses the answer.
    @ObservationIgnored private var cache: [String: String] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private let model: AnyObject?

    private static let cacheLimit = 500

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? true
        if #available(macOS 26.0, *) {
            model = ModelTitles()
        } else {
            model = nil
        }
    }

    /// What the settings page shows about Apple Intelligence on this Mac.
    var modelStatus: (available: Bool, message: String) {
        guard #available(macOS 26.0, *), let model = model as? ModelTitles else {
            return (false, "Requires macOS 26 or later. Rule-based tidying still works.")
        }
        switch model.availability {
        case .available:
            return (true, "Apple Intelligence is ready. Everything runs on this Mac.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return (false, "Turn on Apple Intelligence in System Settings to shorten long titles. Rule-based tidying still works.")
        case .unavailable(.modelNotReady):
            return (false, "Apple Intelligence is still downloading its model. Rule-based tidying works meanwhile.")
        case .unavailable(.deviceNotEligible):
            return (false, "This Mac doesn't support Apple Intelligence. Rule-based tidying still works.")
        case .unavailable:
            return (false, "Apple Intelligence isn't available right now. Rule-based tidying still works.")
        }
    }

    /// Called when a page finishes loading or its title settles.
    func update(_ tab: Tab) {
        guard isEnabled, !tab.isHome, let host = tab.url?.host(), tab.url?.scheme?.hasPrefix("http") == true else { return }
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
        guard !pending.contains(key) else { return }

        guard #available(macOS 26.0, *), let model = model as? ModelTitles, model.isAvailable else { return }
        pending.insert(key)
        Task {
            // Wait for the title to settle: pages that animate or rewrite it shouldn't reach the model.
            try? await Task.sleep(for: .milliseconds(800))
            guard tab.title == original else {
                pending.remove(key)
                return
            }
            // The model gets the rule-cleaned title: without the site name it can't fall back on it.
            let outcome = await model.shorten(cleaned, host: host)
            pending.remove(key)
            switch outcome {
            case .title(let candidate):
                let accepted = TitleCleaner.acceptable(candidate, original: original, host: host) ?? cleaned
                remember(accepted, for: key)
                tab.setTidyTitle(accepted, from: original)
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
