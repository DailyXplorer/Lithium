import Foundation
import Observation

/// Max feature: a summary of the page, or of the selected text, by Apple's on-device model.
/// Made only when asked (the toolbar button), then kept for the tab until it leaves the page.
/// A summary keeps going when its popover closes.
@MainActor
@Observable
final class PageSummaries {
    static let preferenceKey = "summarizePages"
    static let languageKey = "summaryLanguage"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.preferenceKey)
            if !isEnabled {
                isPanelPresented = false
                Array(entries.keys).forEach(discard)
            }
        }
    }

    /// A language code ("fr") the reader picked for summaries; nil follows the system's languages.
    var language: String? {
        didSet {
            UserDefaults.standard.set(language, forKey: Self.languageKey)
            // Summaries already made are in the previous language.
            if language != oldValue { Array(entries.keys).forEach(discard) }
        }
    }

    struct Summary: Equatable {
        let source: SummarySource
        let content: SummaryContent
        /// Made from the beginning of a page longer than `SummaryText.maximumLength`.
        let isPartial: Bool
    }

    enum State: Equatable {
        case working(SummarySource, isLong: Bool)
        case ready(Summary)
        case failed(String)
    }

    /// One tab's summaries, for one page. The page's is kept alongside the latest selection's,
    /// so selecting a passage doesn't throw away the page summary.
    private struct Entry {
        let url: URL
        /// What the tab's popover shows; nil while the page is being read.
        var shown: SummarySource?
        var page: State?
        var selection: (text: String, state: State)?

        init(url: URL) { self.url = url }

        var shownState: State? {
            switch shown {
            case .page: page
            case .selection: selection?.state
            case nil: nil
            }
        }
    }

    /// The toolbar popover. Opening it, from the sparkle button or ⇧⌘S, starts the summary.
    var isPanelPresented = false

    private var entries: [Tab.ID: Entry] = [:]
    @ObservationIgnored private var tasks: [Tab.ID: [SummarySource: Task<Void, Never>]] = [:]
    @ObservationIgnored private let model: AnyObject?

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? true
        language = UserDefaults.standard.string(forKey: Self.languageKey)
        if #available(macOS 26.0, *) {
            model = ModelSummaries()
        } else {
            model = nil
        }
    }

    /// The page a summary belongs to: web pages and local files, without the fragment, so
    /// jumping to a heading keeps the summary.
    nonisolated static func page(of url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    func togglePanel(for tab: Tab) {
        isPanelPresented.toggle()
        if isPanelPresented { Task { await summarize(tab) } }
    }

    /// Why summaries can't be made on this Mac; nil when Apple Intelligence is ready.
    var unavailableReason: String? {
        guard #available(macOS 26.0, *), let model = model as? ModelSummaries else {
            return "Summaries need macOS 26 or later with Apple Intelligence."
        }
        switch model.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to summarize pages."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model. Try again in a few minutes."
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable:
            return "Apple Intelligence isn't available right now."
        }
    }

    /// For the settings page: the languages summaries can be written in, and the one the
    /// system's languages lead to.
    var languageChoices: (system: String, languages: [(code: String, name: String)]) {
        guard #available(macOS 26.0, *), let model = model as? ModelSummaries, model.isAvailable else { return ("English", []) }
        return (model.outputLanguage(nil), model.languages)
    }

    /// What the tab's popover shows. Nil while the page is read, which takes a few milliseconds.
    func state(for tab: Tab) -> State? {
        guard let entry = entries[tab.id], entry.url == Self.page(of: tab.url) else { return nil }
        return entry.shownState
    }

    /// The toolbar button: summarizes the selection when it's long enough, the page otherwise.
    /// Shows a finished or running summary again rather than starting over; a failed one is retried.
    func summarize(_ tab: Tab) async {
        guard isEnabled, unavailableReason == nil, let page = Self.page(of: tab.url) else { return }
        if entries[tab.id]?.url != page {
            discard(tab)
            entries[tab.id] = Entry(url: page)
        }
        entries[tab.id]?.shown = nil

        guard let content = await PageReader.read(tab.webView) else {
            show(.page, .failed("Lithium couldn’t read this page."), in: tab, for: page)
            return
        }
        guard entries[tab.id]?.url == page else { return }

        let selection = content.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = selection.isEmpty ? 0 : await SummaryText.wordCountInBackground(selection)
        guard entries[tab.id]?.url == page else { return }
        if words >= SummaryText.minimumSelectionWords {
            entries[tab.id]?.shown = .selection
            if let current = entries[tab.id]?.selection, current.text == selection, !current.state.isFailure { return }
            start(.selection, text: selection, isPartial: false, title: content.title, in: tab, for: page)
        } else {
            entries[tab.id]?.shown = .page
            if let current = entries[tab.id]?.page, !current.isFailure { return }
            let text = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                show(.page, .failed("This page has no text to summarize."), in: tab, for: page)
                return
            }
            start(.page, text: text, isPartial: content.isTruncated, title: content.title, in: tab, for: page)
        }
    }

    /// The tab left its page or closed: its summaries no longer apply.
    func discard(_ tab: Tab) {
        discard(tab.id)
    }

    private func discard(_ id: Tab.ID) {
        tasks[id]?.values.forEach { $0.cancel() }
        tasks[id] = nil
        entries[id] = nil
    }

    private func start(_ source: SummarySource, text: String, isPartial: Bool, title: String, in tab: Tab, for page: URL) {
        guard #available(macOS 26.0, *), let model = model as? ModelSummaries else { return }
        tasks[tab.id]?[source]?.cancel()
        show(source, .working(source, isLong: text.count > model.pieceLength), text: text, in: tab, for: page)
        let host = page.host() ?? page.lastPathComponent
        let id = tab.id
        let language = language
        let task = Task { [weak self] in
            let outcome = await model.summarize(text, source: source, title: title, host: host, language: language)
            guard let self, !Task.isCancelled else { return }
            let state: State = switch outcome {
            case .summary(let content): .ready(Summary(source: source, content: content, isPartial: isPartial))
            case .declined: .failed("Apple Intelligence can’t summarize this \(source == .page ? "page" : "text").")
            case .failed: .failed("The summary didn’t work this time. Open it again to retry.")
            }
            self.finish(source, state, text: text, tabID: id, for: page)
        }
        tasks[tab.id, default: [:]][source] = task
    }

    private func show(_ source: SummarySource, _ state: State, text: String = "", in tab: Tab, for page: URL) {
        guard entries[tab.id]?.url == page else { return }
        entries[tab.id]?.shown = source
        switch source {
        case .page: entries[tab.id]?.page = state
        case .selection: entries[tab.id]?.selection = (text, state)
        }
    }

    private func finish(_ source: SummarySource, _ state: State, text: String, tabID: Tab.ID, for page: URL) {
        guard entries[tabID]?.url == page else { return }
        tasks[tabID]?[source] = nil
        switch source {
        case .page:
            entries[tabID]?.page = state
        case .selection:
            // A newer selection took its place meanwhile.
            guard entries[tabID]?.selection?.text == text else { return }
            entries[tabID]?.selection = (text, state)
        }
    }
}

private extension PageSummaries.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
