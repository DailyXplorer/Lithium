import CryptoKit
import Foundation
import Observation
import WebKit

/// Owns everything that protects a page: compiled filter lists, the farbling script,
/// the hardened WebKit configuration, and the per-site opt-out list.
@MainActor
@Observable
final class Privacy {
    private(set) var disabledHosts: Set<String>
    /// Protections turned on or off in private tabs, by private session, then host; never saved.
    private var privateExceptions: [ObjectIdentifier: [String: Bool]] = [:]
    private(set) var ruleCount = 0
    private(set) var filtersUpdated: Date?
    private(set) var isUpdatingFilters = false
    /// Bumped whenever new rule lists are loaded, so open tabs know to swap theirs.
    private(set) var generation = 0

    /// Set by tests too, for a rule of their own.
    @ObservationIgnored var ruleLists: [WKContentRuleList] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The rule-list load queued last. Each load waits for the one before: two at once (Update
    /// now during the launch load) would remove each other's compiled lists and engine build.
    @ObservationIgnored private var lastLoad: Task<Void, Never>?
    @ObservationIgnored private var updateLoop: Task<Void, Never>?
    /// False when the loaded filters predate a change to FilterSources.json, such as a new group:
    /// they are then refreshed at once instead of when they turn a day old.
    @ObservationIgnored private var filtersMatchSources = true
    /// False when a list failed to download or a group failed to compile: the filters are stale
    /// until an update gets them all.
    @ObservationIgnored private var filtersComplete = true
    /// Automatic updates that failed in a row, and when the next may start: a list that stays
    /// down is retried after 1, 2, 4… hours, up to a day, not with every other list each hour.
    /// Kept across launches, or a list that stays down would bring a full download and rebuild
    /// at every launch.
    @ObservationIgnored private var failedUpdates: Int
    @ObservationIgnored private var nextUpdate: Date
    @ObservationIgnored private let farblingTemplate: String
    /// Drawn at launch, so the noise of a site changes from launch to launch.
    @ObservationIgnored private let farblingKey = SymmetricKey(size: .bits256)
    /// Private tabs farble with keys of their own: nothing in them matches the same site in a normal tab.
    @ObservationIgnored private let privateFarblingKey = SymmetricKey(size: .bits256)
    @ObservationIgnored private let advanced = AdvancedBlocking()
    @ObservationIgnored private let userAgentSuffix: String

    private static let disabledHostsKey = "disabledProtectionHosts"
    private static let failedUpdatesKey = "failedFilterUpdates"
    private static let nextUpdateKey = "nextFilterUpdate"
    /// Part of each compiled list's name: bumped when `prepared(_:)` changes, so lists compiled
    /// the old way are rebuilt once instead of waiting for the next filter update.
    private static let preparation = 4
    private static let updateInterval: TimeInterval = 24 * 60 * 60
    private static let downloadedFilters = URL.applicationSupportDirectory.appending(path: "Lithium/Filters")

    init() {
        disabledHosts = Set(UserDefaults.standard.stringArray(forKey: Self.disabledHostsKey) ?? [])
        (failedUpdates, nextUpdate) = Self.savedBackoff(in: .standard)

        farblingTemplate = Resources.bundle.url(forResource: "farbling", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

        let safari = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let safariVersion = safari?["CFBundleShortVersionString"] as? String ?? "26.0"
        userAgentSuffix = "Version/\(safariVersion) Safari/605.1.15"
    }

    /// The script for pages of `site`: its noise seed is an HMAC of the site under the launch's
    /// key, worked out here so a page that recovers it can't run it back to the key or on to
    /// another site's. The marker name is an HMAC of the key alone: the copies of every site must
    /// agree on it (a cross-site frame and the popup it opens), and pages never see it.
    static func farbling(_ template: String, key: SymmetricKey, site: String) -> String {
        template
            .replacingOccurrences(of: "__LITHIUM_SEED__", with: farblingValue("seed:\(site)", key: key))
            .replacingOccurrences(of: "__LITHIUM_MARK__", with: "m" + farblingValue("mark", key: key))
    }

    private static func farblingValue(_ message: String, key: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
            .prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a response's policies require Trusted Types: "enforce" when its enforced one does,
    /// "report" when only its report-only one does. A page can't tell which applies; farbling
    /// needs to, to check a write without filing a report or calling a policy the browser wouldn't.
    nonisolated static func trustedTypes(of response: URLResponse) -> String? {
        guard let response = response as? HTTPURLResponse else { return nil }
        let requires = { (header: String) in
            (response.value(forHTTPHeaderField: header) ?? "").lowercased()
                .split { $0 == "," || $0 == ";" }
                .contains { directive in
                    let words = directive.split(whereSeparator: \.isWhitespace)
                    return words.first == "require-trusted-types-for" && words.contains("'script'")
                }
        }
        if requires("Content-Security-Policy") { return "enforce" }
        return requires("Content-Security-Policy-Report-Only") ? "report" : nil
    }

    /// The script that hands `trustedTypes(of:)` to the farbling of the response's document, and
    /// of no other: it goes to every frame and runs only in documents at the response's address.
    static func trustedTypesScript(for response: URLResponse, key: SymmetricKey) -> String? {
        guard let mode = trustedTypes(of: response), let url = response.url else { return nil }
        return trustedTypesScript(modes: [trustedTypesAddress(url): mode], key: key)
    }

    /// The same for several documents, by address (without the fragment).
    static func trustedTypesScript(modes: [String: String], key: SymmetricKey) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let json = try? String(decoding: encoder.encode(modes), as: UTF8.self) else { return nil }
        return """
            (() => {
              const modes = { __proto__: null, ...\(json) }, href = location.href, at = href.indexOf('#');
              const mode = modes[at < 0 ? href : href.slice(0, at)];
              if (!mode) return;
              dispatchEvent(new CustomEvent('m\(farblingValue("mark", key: key))', { cancelable: true, detail: { __proto__: null, trustedTypes: mode } }));
            })();
            """
    }

    private static func trustedTypesAddress(_ url: URL) -> String {
        String(url.absoluteString.prefix { $0 != "#" })
    }

    /// The Trusted Types script last added to a page's content controller, and every address it was asked for.
    private final class TrustedTypesScript {
        let script: WKUserScript
        let modes: [String: String]
        init(script: WKUserScript, modes: [String: String]) { self.script = script; self.modes = modes }
    }
    @ObservationIgnored private let trustedTypesScripts = NSMapTable<WKUserContentController, TrustedTypesScript>.weakToStrongObjects()
    private static let removeUserScript = Selector(("_removeUserScript:"))

    /// Adds `trustedTypesScript` for a page's document or frame, keyed as that page's farbling is.
    /// One script holds every address of the page and replaces the one before: a script per
    /// address piled up for the page's life as frames of new addresses came. Without WebKit's
    /// private call to remove one, each address still gets a script of its own, once.
    func addTrustedTypesScript(_ enabled: Bool, for response: URLResponse, isPrivate: Bool = false, to controller: WKUserContentController) {
        guard enabled, let mode = Self.trustedTypes(of: response), let url = response.url else { return }
        // Gone with the rest of the scripts at a main-frame navigation: the new page starts afresh.
        let last = trustedTypesScripts.object(forKey: controller).flatMap { last in
            controller.userScripts.contains { $0.source == last.script.source } ? last : nil
        }
        let address = Self.trustedTypesAddress(url)
        var modes = last?.modes ?? [:]
        guard modes[address] != mode else { return }
        modes[address] = mode
        let replaces = controller.responds(to: Self.removeUserScript)
        guard let source = Self.trustedTypesScript(modes: replaces ? modes : [address: mode], key: isPrivate ? privateFarblingKey : farblingKey) else { return }
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        // Added before the old one goes, so no document starts with neither.
        controller.addUserScript(script)
        if replaces, let last { _ = controller.perform(Self.removeUserScript, with: last.script) }
        trustedTypesScripts.setObject(TrustedTypesScript(script: script, modes: modes), forKey: controller)
    }

    /// The site farbling is keyed on: the registrable domain from the public suffix list (so
    /// `alice.github.io` and `bob.github.io` differ), or the address itself for an IP host.
    /// A blob's address has no host but holds its creator's origin, whose site it takes; one of an
    /// opaque origin ("blob:null/…") gets a site of its own, not the "" that every site's would share.
    nonisolated static func farblingSite(_ url: URL) -> String {
        if url.scheme?.lowercased() == "blob" {
            let site = URL(string: String(url.absoluteString.dropFirst(5))).map(farblingSite) ?? ""
            return site.isEmpty ? UUID().uuidString : site
        }
        guard let host = url.host(), !host.isEmpty else { return "" }
        return SiteInfo.registrable(host)
    }

    func start() {
        guard loadTask == nil else { return }
        loadTask = Task { await loadRuleLists() }
        lastLoad = loadTask
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
              Self.needsUpdate(updated: filtersUpdated, matchesSources: filtersMatchSources, complete: filtersComplete, notBefore: nextUpdate) else { return }
        isUpdatingFilters = true
        await updateFilters()
    }

    /// Whether the hourly check updates the filters: they are a day old, built from other
    /// sources, or incomplete, and the wait after the last failed update is over. Filters dated
    /// in the future (built with the clock set ahead) count as stale: they would otherwise stop
    /// updates until the clock caught up.
    static func needsUpdate(updated: Date?, matchesSources: Bool, complete: Bool, notBefore: Date, now: Date = Date()) -> Bool {
        guard now >= notBefore else { return false }
        let age = now.timeIntervalSince(updated ?? .distantPast)
        return !matchesSources || !complete || age > updateInterval || age < 0
    }

    /// The wait before the next automatic update after `failures` failed ones in a row.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        min(60 * 60 * pow(2, Double(min(max(failures - 1, 0), 10))), updateInterval)
    }

    /// Runs with `isUpdatingFilters` set by the caller, and clears it when done.
    private func updateFilters() async {
        defer { isUpdatingFilters = false }
        guard let updater = FilterUpdater.bundled() else { return }
        let destination = Self.downloadedFilters
        var updated = false
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await Task.detached(priority: .utility) { try await updater.update(into: destination) }.value
            await reloadRuleLists()
            updated = filtersComplete
        } catch {
            NSLog("Lithium: filter update failed: %@", error.localizedDescription)
        }
        (failedUpdates, nextUpdate) = Self.saveBackoff(afterFailures: updated ? 0 : failedUpdates + 1, in: .standard)
    }

    /// Stores the backoff after `failures` failed updates in a row and returns it.
    static func saveBackoff(afterFailures failures: Int, in defaults: UserDefaults, now: Date = Date())
        -> (failures: Int, notBefore: Date) {
        let notBefore = failures == 0 ? Date.distantPast : now.addingTimeInterval(retryDelay(afterFailures: failures))
        defaults.set(failures, forKey: failedUpdatesKey)
        defaults.set(notBefore.timeIntervalSinceReferenceDate, forKey: nextUpdateKey)
        return (failures, notBefore)
    }

    /// The backoff the last launch left. A wait more than a day away (the clock was turned back)
    /// is cut to a day, the longest `retryDelay` gives.
    static func savedBackoff(in defaults: UserDefaults, now: Date = Date()) -> (failures: Int, notBefore: Date) {
        guard defaults.object(forKey: nextUpdateKey) != nil else { return (0, .distantPast) }
        let saved = Date(timeIntervalSinceReferenceDate: defaults.double(forKey: nextUpdateKey))
        return (defaults.integer(forKey: failedUpdatesKey), min(saved, now.addingTimeInterval(updateInterval)))
    }

    /// Loads the current filters once every load queued before has finished.
    private func reloadRuleLists() async {
        let previous = lastLoad
        let load = Task {
            await previous?.value
            await loadRuleLists()
        }
        lastLoad = load
        await load.value
    }

    /// The newer of the lists shipped in the app and the last downloaded ones.
    private static func currentFilters() -> (folder: URL, manifest: Manifest)? {
        let now = Date()
        return [Resources.bundle.url(forResource: "Filters", withExtension: nil), downloadedFilters]
            .compactMap { folder -> (URL, Manifest)? in
                guard let folder, let manifest = Manifest.read(in: folder),
                      manifest.format ?? 1 >= Manifest.currentFormat else { return nil }
                return (folder, manifest)
            }
            .max { $0.1.comparableDate(now: now) < $1.1.comparableDate(now: now) }
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

    /// `privateSession` is set for a private tab: its session's own choice wins, then the saved one.
    func isEnabled(for url: URL?, privateSession: ObjectIdentifier? = nil) -> Bool {
        guard let host = Self.siteHost(url) else { return true }
        if let privateSession, let enabled = privateExceptions[privateSession]?[host] { return enabled }
        return !disabledHosts.contains(host)
    }

    /// A private tab's choice stays in memory for its private session only: saved, it would
    /// record the site it visited.
    func setEnabled(_ enabled: Bool, for url: URL?, privateSession: ObjectIdentifier? = nil) {
        guard let host = Self.siteHost(url) else { return }
        if let privateSession {
            privateExceptions[privateSession, default: [:]][host] = enabled
        } else {
            setEnabled(enabled, host: host)
        }
    }

    /// The private session's last tab closed: its choices go with its cookies.
    func forget(privateSession: ObjectIdentifier) {
        privateExceptions[privateSession] = nil
    }

    /// `host` as `disabledHosts` holds it (Settings' list), used as is: rebuilt into an address,
    /// an IPv6 one may not parse back to the same host.
    func setEnabled(_ enabled: Bool, host: String) {
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
        // Every frame gets the top page's site, as in Brave: a frame embedded on many sites farbles differently on each.
        let farbling = WKUserScript(source: Self.farbling(farblingTemplate, key: isPrivate ? privateFarblingKey : farblingKey, site: Self.farblingSite(url)),
                                    injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        guard let source = advanced.script(for: url) else { return [farbling] }
        return [farbling, WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)]
    }

    /// The advanced rules for a frame of `page` showing `frame` (an embed, an ad, a consent
    /// prompt), looked up for the frame's own site. The script goes to every frame and runs only
    /// in frames of that host.
    func frameScript(_ enabled: Bool, for frame: URL, in page: URL) -> WKUserScript? {
        guard enabled, let source = advanced.script(for: frame, inFrameOf: page) else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
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
                // Only those parts change: the rest is kept as written, commas in values included.
                action["selector"] = selectorParts(selector).map { part in
                    guard let match = part.trimmingCharacters(in: .whitespaces).wholeMatch(of: /(#[\w-]+)\s*~\s*\*/) else { return String(part) }
                    return "\(part.prefix(while: \.isWhitespace))\(match.1) + *, \(match.1) + * + *, \(match.1) + * + * + *"
                }.joined(separator: ",")
                rules[index]["action"] = action
            }
        }
        guard let prepared = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(decoding: prepared, as: UTF8.self)
    }

    /// A selector list's parts, split on its own commas only: not those in quotes, brackets or
    /// parentheses, or escaped (`[href*="a,b"]`, `:is(.a, .b)` and `.a\,b` are one part each).
    nonisolated static func selectorParts(_ selector: String) -> [Substring] {
        var parts: [Substring] = [], start = selector.startIndex, depth = 0, quote: Character?, escaped = false
        for index in selector.indices {
            let character = selector[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if let open = quote { if character == open { quote = nil } }
            else if character == "\"" || character == "'" { quote = character }
            else if character == "[" || character == "(" { depth += 1 }
            else if character == "]" || character == ")" { depth = max(0, depth - 1) }
            else if character == ",", depth == 0 {
                parts.append(selector[start..<index])
                start = selector.index(after: index)
            }
        }
        parts.append(selector[start...])
        return parts
    }

    private func loadRuleLists() async {
        guard let (folder, manifest) = Self.currentFilters(),
              let store = WKContentRuleListStore.default() else { return }

        let stamp = manifest.updated.filter(\.isNumber)
        let groups = await Self.loadGroups(from: folder, manifest: manifest, into: store)
        ruleLists = groups.lists
        ruleCount = groups.ruleCount + (manifest.advancedRules ?? 0) + (manifest.scriptletRules ?? 0)
        filtersUpdated = manifest.date
        filtersMatchSources = FilterUpdater.bundled()?.sources.built(manifest) ?? true
        filtersComplete = groups.complete && (manifest.failedLists ?? []).isEmpty
        generation += 1

        // Awaited, so pages also wait for the in-page engine (waitUntilReady). Without it, the tab
        // restored at launch loads without uBO's scriptlets while the engine builds, and plays ads.
        // A later rebuild swaps the new engine in without making pages wait.
        await advanced.load(folder: folder, stamp: stamp)
    }

    /// Each group's compiled list, compiled now if this filter set is new, then removes the lists
    /// no group uses any more. A group that fails to compile keeps the list compiled from an
    /// earlier set, still loaded, but isn't counted, and makes the set incomplete so it is tried again.
    static func loadGroups(from folder: URL, manifest: Manifest, into store: WKContentRuleListStore) async
        -> (lists: [WKContentRuleList], ruleCount: Int, complete: Bool) {
        let stamp = manifest.updated.filter(\.isNumber)
        let available = await store.availableIdentifiers() ?? []
        var lists: [WKContentRuleList] = []
        var kept: Set<String> = []
        var ruleCount = 0
        var complete = true
        for group in manifest.groups.keys.sorted() {
            let identifier = "lithium-\(group)-\(stamp)-p\(Self.preparation)"
            if let list = await compiled(group, identifier: identifier, folder: folder, store: store) {
                lists.append(list)
                kept.insert(identifier)
                ruleCount += manifest.groups[group]?.webkitRules ?? 0
                continue
            }
            complete = false
            let previous = available
                .filter { $0.wholeMatch(of: /lithium-(.+)-\d+-p\d+/).map { String($0.1) } == group }
                .max { $0.filter(\.isNumber) < $1.filter(\.isNumber) }
            if let previous, let list = try? await store.contentRuleList(forIdentifier: previous) {
                lists.append(list)
                kept.insert(previous)
            }
        }

        for identifier in available where identifier.hasPrefix("lithium-") && !kept.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
        return (lists, ruleCount, complete)
    }

    private static func compiled(_ group: String, identifier: String, folder: URL, store: WKContentRuleListStore) async -> WKContentRuleList? {
        if let cached = try? await store.contentRuleList(forIdentifier: identifier) { return cached }
        // Reading and rewriting ten megabytes of JSON happens off the main thread.
        let file = folder.appending(path: "\(group).json")
        guard let json = await Task.detached(priority: .utility, operation: { Self.prepared(file) }).value else {
            NSLog("Lithium: failed to read %@ filters", group)
            return nil
        }
        do {
            return try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
        } catch {
            NSLog("Lithium: failed to compile %@ filters: %@", group, error.localizedDescription)
            return nil
        }
    }
}
