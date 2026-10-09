import AppKit
import NaturalLanguage
import Observation
import SwiftUI
@preconcurrency import Translation
import WebKit

/// A page's translation, from its language check to Show Original.
struct TabTranslation: Equatable {
    enum Status: Equatable {
        case offered, downloading, translating, translated
        case failed(String)
    }

    let source: Locale.Language
    let target: Locale.Language
    var status = Status.offered
    /// The address bar's offer was put away for this page.
    var isDismissed = false

    var isActive: Bool { [Status.downloading, .translating, .translated].contains(status) }
}

/// What turns a page's texts into another language: Apple's Translation through `TranslationHost`,
/// or a test's own.
@MainActor
protocol TranslationEngine: AnyObject {
    func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status
    /// Nil for a text that couldn't be translated. `preparing` first asks macOS for the languages.
    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language, preparing: Bool) async throws -> [String?]
}

/// Whole-page translation, on this Mac (Apple's Translation). Nothing runs in a page until it is
/// used, but for a one-shot language check per page while `offers` is on: `page-translate.js` and its
/// handler arrive with the first translation, and its observers live only while the page is translated.
/// WebKit's own page translation (Safari's) is private API, so pages are translated in place here.
@MainActor
@Observable
final class PageTranslator: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "lithiumPageTranslate"

    /// Read by `TranslationHost`: set while texts wait for a session between these two languages.
    private(set) var configuration: TranslationSession.Configuration?
    /// A test's engine instead of Apple's.
    @ObservationIgnored var engine: (any TranslationEngine)?
    /// The Mac's; a test's own, whatever the Mac it runs on reads.
    @ObservationIgnored var preferredLanguages = { Locale.preferredLanguages }
    @ObservationIgnored private weak var browser: Browser?
    @ObservationIgnored private var jobs: [Job] = []
    @ObservationIgnored private var servedPair: Pair?
    @ObservationIgnored private var isServing = false
    /// Never saved: a private session's choices go with it.
    @ObservationIgnored private var privateLanguages: [ObjectIdentifier: [String: Bool]] = [:]
    @ObservationIgnored private var privateSites: [ObjectIdentifier: [String: Bool]] = [:]

    private struct Pair: Equatable {
        let source: Locale.Language
        let target: Locale.Language
    }

    private struct Job {
        let pair: Pair
        let texts: [String]
        let preparing: Bool
        let continuation: CheckedContinuation<[String?], any Error>
    }

    init(browser: Browser) {
        self.browser = browser
    }

    // MARK: Choices

    static let offerKey = "offerPageTranslation"
    static let languagesKey = "alwaysTranslateLanguages"
    static let sitesKey = "neverTranslateSites"

    /// The address bar's button on pages in another language than the user's.
    var offers: Bool {
        get { UserDefaults.standard.object(forKey: Self.offerKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.offerKey) }
    }

    var alwaysLanguages: [String] { UserDefaults.standard.stringArray(forKey: Self.languagesKey) ?? [] }
    var neverSites: [String] { UserDefaults.standard.stringArray(forKey: Self.sitesKey) ?? [] }

    func alwaysTranslates(_ language: Locale.Language, privateSession: ObjectIdentifier?) -> Bool {
        guard let code = language.languageCode?.identifier else { return false }
        if let privateSession, let always = privateLanguages[privateSession]?[code] { return always }
        return alwaysLanguages.contains(code)
    }

    /// A private tab's choice stays in memory, as its site font does (`PageStyle`).
    func setAlwaysTranslates(_ always: Bool, _ language: Locale.Language, privateSession: ObjectIdentifier?) {
        guard let code = language.languageCode?.identifier else { return }
        if let privateSession { return privateLanguages[privateSession, default: [:]][code] = always }
        var codes = alwaysLanguages.filter { $0 != code }
        if always { codes.append(code) }
        UserDefaults.standard.set(codes, forKey: Self.languagesKey)
    }

    func neverTranslates(_ url: URL?, privateSession: ObjectIdentifier?) -> Bool {
        guard let site = Self.site(of: url) else { return false }
        if let privateSession, let never = privateSites[privateSession]?[site] { return never }
        return neverSites.contains(site)
    }

    func setNeverTranslates(_ never: Bool, site: String, privateSession: ObjectIdentifier?) {
        let site = SiteInfo.registrable(site.lowercased())
        if let privateSession { return privateSites[privateSession, default: [:]][site] = never }
        var sites = neverSites.filter { $0 != site }
        if never { sites.append(site) }
        UserDefaults.standard.set(sites.sorted(), forKey: Self.sitesKey)
    }

    func forget(privateSession: ObjectIdentifier) {
        privateLanguages[privateSession] = nil
        privateSites[privateSession] = nil
    }

    static func site(of url: URL?) -> String? {
        url?.host()?.lowercased().nilIfEmpty.map(SiteInfo.registrable)
    }

    /// "French"; the code itself for a language macOS has no name for.
    static func name(of language: Locale.Language) -> String {
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    // MARK: Pages

    /// Once per page, on screen, when the button may be offered or the tab keeps translating
    /// (`translatesLanguage`). The page is read once idle, a bounded sample of its text.
    func check(_ tab: Tab) {
        guard !tab.languageChecked, tab.canTranslate, let webView = tab.loadedWebView,
              offers || tab.translatesLanguage != nil, !neverTranslates(tab.url, privateSession: tab.privateSession) else { return }
        tab.languageChecked = true
        let run = tab.translationRun
        Task {
            guard let source = await Self.language(of: webView), tab.translationRun == run, tab.loadedWebView === webView,
                  let target = Self.offer(from: source, chosen: browser?.summaries.language, preferred: preferredLanguages(),
                                          supported: browser?.translation.supported ?? []) else { return }
            tab.pageTranslation = TabTranslation(source: source, target: target)
            let code = source.languageCode?.identifier
            if alwaysTranslates(source, privateSession: tab.privateSession) || code != nil && code == tab.translatesLanguage {
                await translate(tab)
            } else if !offers {
                tab.pageTranslation = nil
            }
        }
    }

    /// The menus' and the command bar's: a page not offered (in one of the user's languages, or
    /// with offers off) goes into the next language.
    func translatePage(_ tab: Tab) async {
        guard tab.canTranslate, let webView = tab.loadedWebView else { return }
        if tab.pageTranslation == nil {
            let run = tab.translationRun
            guard let source = await Self.language(of: webView), tab.translationRun == run,
                  let target = PageTranslation.target(from: source.languageCode, chosen: browser?.summaries.language,
                                                      preferred: preferredLanguages(), supported: browser?.translation.supported ?? []) else { return NSSound.beep() }
            tab.pageTranslation = TabTranslation(source: source, target: target)
        }
        await translate(tab)
    }

    func translate(_ tab: Tab) async {
        guard let state = tab.pageTranslation, !state.isActive, let webView = tab.loadedWebView else { return }
        let run = tab.translationRun
        tab.translatesLanguage = state.source.languageCode?.identifier
        tab.pageTranslation?.status = .translating
        let availability = await engineStatus(from: state.source, to: state.target)
        guard tab.translationRun == run, tab.loadedWebView === webView else { return }
        if availability == .unsupported {
            tab.pageTranslation?.status = .failed("Translation can’t go from \(Self.name(of: state.source)) to \(Self.name(of: state.target)) yet.")
            return
        }
        if availability == .supported { tab.pageTranslation?.status = .downloading }
        // Added again each time: a popup's web view may share its opener's controller.
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .defaultClient)
        controller.addScriptMessageHandler(self, contentWorld: .defaultClient, name: Self.handlerName)
        let started = try? await webView.callAsyncJavaScript(Self.script, arguments: ["action": "start"], contentWorld: .defaultClient) as? Bool
        guard tab.translationRun == run, tab.pageTranslation?.isActive == true else { return }
        tab.pageTranslation?.status = started == true ? .translated : .failed(Self.failure)
    }

    /// Back to the page's own text; the tab stops translating the pages that follow.
    func showOriginal(_ tab: Tab) {
        tab.translatesLanguage = nil
        guard tab.pageTranslation != nil else { return }
        tab.translationRun += 1
        tab.pageTranslation?.status = .offered
        tab.loadedWebView?.callAsyncJavaScript(Self.script, arguments: ["action": "restore"], in: nil, in: .defaultClient)
    }

    /// Turned off, offers go from pages not translated; turned on, the pages shown are asked.
    func setOffers(_ offers: Bool) {
        self.offers = offers
        guard let browser else { return }
        for tab in browser.tabs where tab.pageTranslation?.isActive != true {
            tab.pageTranslation = nil
            tab.languageChecked = false
        }
        if offers {
            browser.selectedTab.map(check)
            browser.shownPartner.map(check)
        }
    }

    private static let failure = "This page couldn’t be translated."

    static let script = Resources.bundle.url(forResource: "page-translate", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    private static let sampleScript = """
        await new Promise((resolve) => window.requestIdleCallback ? requestIdleCallback(resolve, { timeout: 1000 }) : setTimeout(resolve));
        let text = '';
        if (document.body) {
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          // Bounded, on any page: enough words to tell the language.
          for (let node = walker.nextNode(), seen = 0; node && text.length < 1500 && seen < 3000; node = walker.nextNode(), seen++) {
            const part = node.data.trim();
            if (part.length < 2 || !/\\p{L}/u.test(part)) continue;
            const parent = node.parentElement;
            if (!parent || parent.closest('script, style, noscript, template, code, pre, [translate=no], .notranslate') || !parent.checkVisibility()) continue;
            text += part + '\\n';
          }
        }
        return { lang: document.documentElement.lang || '', text };
        """

    private static func language(of webView: WKWebView) async -> Locale.Language? {
        let sample = try? await webView.callAsyncJavaScript(sampleScript, contentWorld: .defaultClient) as? [String: Any]
        return language(of: sample?["text"] as? String ?? "", declared: sample?["lang"] as? String ?? "")
    }

    /// What NaturalLanguage reads in the text, else what the page says (`<html lang>`).
    nonisolated static func language(of text: String, declared: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if text.count >= 20, let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.6 {
            return Locale.Language(identifier: language.rawValue)
        }
        let declared = declared.trimmingCharacters(in: .whitespaces)
        return declared.isEmpty ? nil : Locale.Language(identifier: declared)
    }

    /// Only a page in none of the user's languages, which Translation reads, is offered.
    nonisolated static func offer(
        from source: Locale.Language, chosen: String?, preferred: [String] = Locale.preferredLanguages, supported: [Locale.Language]
    ) -> Locale.Language? {
        let own = ((chosen.map { [$0] } ?? []) + preferred).map { Locale.Language(identifier: $0).languageCode }
        guard let code = source.languageCode, !own.contains(code),
              supported.isEmpty || supported.contains(where: { $0.languageCode == code }) else { return nil }
        return PageTranslation.target(from: code, chosen: chosen, preferred: preferred, supported: supported)
    }

    // MARK: The page's handler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard message.frameInfo.isMainFrame, let webView = message.webView as? PageWebView, let tab = webView.tab, tab.loadedWebView === webView,
              let state = tab.pageTranslation, state.isActive, let texts = message.body as? [String] else { return (nil, "Not translating") }
        let run = tab.translationRun
        let preparing = state.status == .downloading
        do {
            let results = try await engineTranslate(texts, from: state.source, to: state.target, preparing: preparing)
            if preparing, tab.translationRun == run { tab.pageTranslation?.status = .translating }
            return (results.map { $0 ?? NSNull() as Any }, nil)
        } catch {
            guard tab.translationRun == run, tab.pageTranslation?.isActive == true else { return (nil, "Stopped") }
            tab.translatesLanguage = nil
            tab.pageTranslation?.status = .failed(preparing
                ? "\(Self.name(of: state.source)) isn’t downloaded on this Mac. Translate again to download it."
                : Self.failure)
            return (nil, "Failed")
        }
    }

    // MARK: Apple's Translation

    private func engineStatus(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        if let engine { return await engine.status(from: source, to: target) }
        return await LanguageAvailability().status(from: source, to: target)
    }

    private func engineTranslate(_ texts: [String], from source: Locale.Language, to target: Locale.Language, preparing: Bool) async throws -> [String?] {
        if let engine { return try await engine.translate(texts, from: source, to: target, preparing: preparing) }
        return try await withCheckedThrowingContinuation { continuation in
            jobs.append(Job(pair: Pair(source: source, target: target), texts: texts, preparing: preparing, continuation: continuation))
            serveNext()
        }
    }

    /// A session comes only through SwiftUI (`translationTask`), one pair of languages at a time:
    /// the host is handed the next pair, or asked to run again for the same one.
    private func serveNext() {
        guard !isServing, let next = jobs.first else { return }
        if next.pair == servedPair, configuration != nil {
            configuration?.invalidate()
        } else {
            servedPair = next.pair
            configuration = TranslationSession.Configuration(source: next.pair.source, target: next.pair.target)
        }
    }

    func serve(_ session: TranslationSession) async {
        guard let pair = servedPair, !isServing else { return }
        isServing = true
        while let index = jobs.firstIndex(where: { $0.pair == pair }) {
            let job = jobs.remove(at: index)
            do {
                // macOS's own prompt to download the languages, over the window.
                if job.preparing { try await session.prepareTranslation() }
                job.continuation.resume(returning: try await Self.translate(job.texts, in: session))
            } catch {
                job.continuation.resume(throwing: error)
            }
        }
        isServing = false
        serveNext()
    }

    private static func translate(_ texts: [String], in session: TranslationSession) async throws -> [String?] {
        // Made here and handed over whole: nothing else holds them.
        nonisolated(unsafe) let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        do {
            var results = [String?](repeating: nil, count: texts.count)
            for response in try await session.translations(from: requests) {
                if let index = response.clientIdentifier.flatMap(Int.init), results.indices.contains(index) { results[index] = response.targetText }
            }
            return results
        } catch {
            // One text the model refuses fails its whole batch: the others go one by one.
            guard texts.count > 1 else { throw error }
            var results: [String?] = []
            for text in texts { results.append(try? await session.translate(text).targetText) }
            if results.allSatisfy({ $0 == nil }) { throw error }
            return results
        }
    }
}

/// Where the translator's sessions come from: in the browser's window, so macOS's download prompt
/// has a window to show over. Draws nothing, and does nothing until a page is translated.
struct TranslationHost: View {
    let translator: PageTranslator

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(translator.configuration) { session in
                await translator.serve(session)
            }
    }
}

extension Browser {
    /// Translate Page, or Show Original once translated.
    func toggleTranslation(_ tab: Tab?) {
        guard let tab, tab.canTranslate else { return }
        if tab.pageTranslation?.isActive == true { translator.showOriginal(tab) } else { Task { await translator.translatePage(tab) } }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
