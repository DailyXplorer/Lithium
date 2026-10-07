import Foundation
import Observation
import WebKit

/// Owns everything that protects a page: compiled filter lists, the farbling script,
/// the hardened WebKit configuration, and the per-site opt-out list.
@MainActor
@Observable
final class Privacy {
    private(set) var disabledHosts: Set<String>
    private(set) var ruleCount = 0
    private(set) var filtersUpdated: Date?
    private(set) var isUpdatingFilters = false
    /// Bumped whenever new rule lists are loaded, so open tabs know to swap theirs.
    private(set) var generation = 0

    /// Set by tests too, for a rule of their own.
    @ObservationIgnored var ruleLists: [WKContentRuleList] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var updateLoop: Task<Void, Never>?
    /// False when the loaded filters predate a change to FilterSources.json, such as a new group:
    /// they are then refreshed at once instead of when they turn a day old.
    @ObservationIgnored private var filtersMatchSources = true
    @ObservationIgnored private let farbling: WKUserScript
    /// Private tabs farble with keys of their own: nothing in them matches the same site in a normal tab.
    @ObservationIgnored private let privateFarbling: WKUserScript
    @ObservationIgnored private let advanced = AdvancedBlocking()
    @ObservationIgnored private let userAgentSuffix: String

    private static let disabledHostsKey = "disabledProtectionHosts"
    /// Part of each compiled list's name: bumped when `prepared(_:)` changes, so lists compiled
    /// the old way are rebuilt once instead of waiting for the next filter update.
    private static let preparation = 4
    private static let updateInterval: TimeInterval = 24 * 60 * 60
    private static let downloadedFilters = URL.applicationSupportDirectory.appending(path: "Lithium/Filters")

    init() {
        disabledHosts = Set(UserDefaults.standard.stringArray(forKey: Self.disabledHostsKey) ?? [])

        let template = Resources.bundle.url(forResource: "farbling", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        farbling = Self.makeFarbling(template)
        privateFarbling = Self.makeFarbling(template)

        let safari = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let safariVersion = safari?["CFBundleShortVersionString"] as? String ?? "26.0"
        userAgentSuffix = "Version/\(safariVersion) Safari/605.1.15"
    }

    /// The script with fresh random keys: one seeds the noise, the other, independent, names the
    /// marker each page window carries, so reading the marker tells a page nothing of the seeds.
    private static func makeFarbling(_ template: String) -> WKUserScript {
        let key = { (bytes: Int) in (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined() }
        let source = template
            .replacingOccurrences(of: "__LITHIUM_SESSION_KEY__", with: key(16))
            .replacingOccurrences(of: "__LITHIUM_MARK_KEY__", with: key(8))
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    func start() {
        guard loadTask == nil else { return }
        loadTask = Task { await loadRuleLists() }
        // scripts/test sets it: each test's Browser would download and convert the lists on its
        // own, and a dozen of them landing at once stalled a later test for two minutes.
        guard ProcessInfo.processInfo.environment["LITHIUM_NO_FILTER_UPDATES"] != "1" else { return }
        updateLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadTask?.value
                await self?.updateFiltersIfStale()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    /// Marks the update as running before returning: the settings page that asked for it reads
    /// the state in the same reply, and shows the update and follows it from there.
    func updateFiltersNow() {
        guard !isUpdatingFilters else { return }
        isUpdatingFilters = true
        Task { await updateFilters() }
    }

    private func updateFiltersIfStale() async {
        guard !isUpdatingFilters,
              !filtersMatchSources || Date().timeIntervalSince(filtersUpdated ?? .distantPast) > Self.updateInterval else { return }
        isUpdatingFilters = true
        await updateFilters()
    }

    /// Runs with `isUpdatingFilters` set by the caller, and clears it when done.
    private func updateFilters() async {
        defer { isUpdatingFilters = false }
        guard let updater = FilterUpdater.bundled() else { return }
        let destination = Self.downloadedFilters
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await Task.detached(priority: .utility) { try await updater.update(into: destination) }.value
            await loadRuleLists()
        } catch {
            NSLog("Lithium: filter update failed: %@", error.localizedDescription)
        }
    }

    /// The newer of the lists shipped in the app and the last downloaded ones.
    private static func currentFilters() -> (folder: URL, manifest: Manifest)? {
        [Resources.bundle.url(forResource: "Filters", withExtension: nil), downloadedFilters]
            .compactMap { folder -> (URL, Manifest)? in
                guard let folder,
                      let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
                      let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                      manifest.format ?? 1 >= Manifest.currentFormat else { return nil }
                return (folder, manifest)
            }
            .max { ($0.1.date ?? .distantPast) < ($1.1.date ?? .distantPast) }
    }

    func waitUntilReady() async {
        await loadTask?.value
    }

    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        harden(configuration)
        return configuration
    }

    /// Popups arrive with WebKit's copy of the opener's configuration; give them their own
    /// content controller so per-tab protection state never leaks between tabs.
    func harden(_ configuration: WKWebViewConfiguration) {
        configuration.userContentController = WKUserContentController()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = userAgentSuffix
        configuration.upgradeKnownHostsToHTTPS = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
    }

    func isEnabled(for url: URL?) -> Bool {
        guard let host = Self.siteHost(url) else { return true }
        return !disabledHosts.contains(host)
    }

    func setEnabled(_ enabled: Bool, for url: URL?) {
        guard let host = Self.siteHost(url) else { return }
        if enabled { disabledHosts.remove(host) } else { disabledHosts.insert(host) }
        UserDefaults.standard.set(disabledHosts.sorted(), forKey: Self.disabledHostsKey)
    }

    func applyRuleLists(_ enabled: Bool, to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        if enabled { ruleLists.forEach(controller.add) }
    }

    /// Adds the protection scripts for `url`; the caller has already reset the controller's scripts.
    func addScripts(_ enabled: Bool, for url: URL, isPrivate: Bool = false, to controller: WKUserContentController) {
        scripts(enabled, for: url, isPrivate: isPrivate).forEach(controller.addUserScript)
    }

    /// The protection scripts for `url`.
    func scripts(_ enabled: Bool, for url: URL, isPrivate: Bool = false) -> [WKUserScript] {
        guard enabled else { return [] }
        let farbling = isPrivate ? privateFarbling : self.farbling
        guard let source = advanced.script(for: url) else { return [farbling] }
        return [farbling, WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)]
    }

    /// WebKit's Advanced Tracking and Fingerprinting Protection (Safari's private-browsing
    /// shield): engine-level canvas noise, window-sized `screen`, and link decoration filtering.
    /// Private API, so it is applied only when this WebKit build has it.
    static func setEngineProtections(_ enabled: Bool, on preferences: WKWebpagePreferences) {
        guard preferences.responds(to: Selector(("_setNetworkConnectionIntegrityEnabled:"))) else { return }
        preferences.setValue(enabled, forKey: "networkConnectionIntegrityEnabled")
    }

    static func siteHost(_ url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The list as WebKit gets it, with two changes to element hiding that keep what it hides:
    /// - WebKit checks every load against each rule whose url-filter matches its URL, and AdGuard's
    ///   converter gives the element hiding rules of particular sites the url-filter ".*". Thousands
    ///   of them went through every image, script and request of every page, which made
    ///   Speedometer's news sites 2.3 times slower. WebKit takes their selectors from the document
    ///   load, so that is the only load they now match.
    /// - "#x ~ *" makes WebKit walk the earlier siblings of every element at each style change:
    ///   one such filter of uBO's badware list cost 44 ms per restyle of a page with 2,000 sibling
    ///   elements, and 8 ms per run of Speedometer's SVG chart. It becomes "#x + *, #x + * + *,
    ///   #x + * + * + *", which hides the three elements that follow #x (what these scam pages put
    ///   after it) with one sibling check each. ":has(> #x) > *" was cheap for the chart but made
    ///   list updates slower.
    nonisolated static func prepared(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              var rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for index in rules.indices {
            guard var trigger = rules[index]["trigger"] as? [String: Any],
                  var action = rules[index]["action"] as? [String: Any],
                  action["type"] as? String == "css-display-none" else { continue }
            if trigger["url-filter"] as? String == ".*", trigger["resource-type"] == nil,
               trigger.keys.contains(where: { $0.hasPrefix("if-") || $0.hasPrefix("unless-") }) {
                trigger["resource-type"] = ["document"]
                rules[index]["trigger"] = trigger
            }
            if let selector = action["selector"] as? String, selector.contains("~") {
                action["selector"] = selector.split(separator: ",").map { part in
                    let selector = part.trimmingCharacters(in: .whitespaces)
                    guard let match = selector.wholeMatch(of: /(#[\w-]+)\s*~\s*\*/) else { return selector }
                    return "\(match.1) + *, \(match.1) + * + *, \(match.1) + * + * + *"
                }.joined(separator: ", ")
                rules[index]["action"] = action
            }
        }
        guard let prepared = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(decoding: prepared, as: UTF8.self)
    }

    private func loadRuleLists() async {
        guard let (folder, manifest) = Self.currentFilters(),
              let store = WKContentRuleListStore.default() else { return }

        let stamp = manifest.updated.filter(\.isNumber)
        var lists: [WKContentRuleList] = []
        var current: Set<String> = []
        for group in manifest.groups.keys.sorted() {
            let identifier = "lithium-\(group)-\(stamp)-p\(Self.preparation)"
            current.insert(identifier)
            if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
                lists.append(cached)
                continue
            }
            // Reading and rewriting ten megabytes of JSON happens off the main thread.
            let file = folder.appending(path: "\(group).json")
            guard let json = await Task.detached(priority: .utility, operation: { Self.prepared(file) }).value else { continue }
            do {
                if let compiled = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) {
                    lists.append(compiled)
                }
            } catch {
                NSLog("Lithium: failed to compile %@ filters: %@", group, error.localizedDescription)
            }
        }

        for identifier in await store.availableIdentifiers() ?? [] where identifier.hasPrefix("lithium-") && !current.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }

        ruleLists = lists
        ruleCount = manifest.groups.values.reduce(0) { $0 + $1.webkitRules } + (manifest.advancedRules ?? 0) + (manifest.scriptletRules ?? 0)
        filtersUpdated = manifest.date
        filtersMatchSources = FilterUpdater.bundled()?.sources.built(manifest) ?? true
        generation += 1

        // Awaited, so pages also wait for the in-page engine (waitUntilReady). Without it, the tab
        // restored at launch loads without uBO's scriptlets while the engine builds, and plays ads.
        // A later rebuild swaps the new engine in without making pages wait.
        await advanced.load(folder: folder, stamp: stamp)
    }
}
