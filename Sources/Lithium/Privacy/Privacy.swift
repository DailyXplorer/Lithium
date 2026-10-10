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
    /// The same for spaces that keep their data apart: another store is another identity.
    private var spaceExceptions: [Space.ID: [String: Bool]]
    private(set) var ruleCount = 0
    private(set) var filtersUpdated: Date?
    private(set) var isUpdatingFilters = false
    /// Bumped whenever new rule lists are loaded, so open tabs know to swap theirs.
    private(set) var generation = 0

    /// Set by tests too, for a rule of their own.
    @ObservationIgnored var ruleLists: [WKContentRuleList] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Each load waits for the one before: two at once would remove each other's compiled lists.
    @ObservationIgnored private var lastLoad: Task<Void, Never>?
    @ObservationIgnored private var updateLoop: Task<Void, Never>?
    /// False when the loaded filters predate a change to FilterSources.json: refreshed at once.
    @ObservationIgnored private var filtersMatchSources = true
    @ObservationIgnored private(set) var filtersComplete = true
    /// Backoff for failed automatic updates (1, 2, 4… hours, up to a day). Kept across launches,
    /// or a list that stays down would bring a full download and rebuild at every launch.
    @ObservationIgnored private var failedUpdates: Int
    @ObservationIgnored private var nextUpdate: Date
    @ObservationIgnored private let farblingTemplate: String
    /// Drawn at launch, so the noise of a site changes from launch to launch.
    @ObservationIgnored private let farblingKey = SymmetricKey(size: .bits256)
    /// Per private session, so nothing in it matches the same site in another session or a normal tab.
    @ObservationIgnored private var privateFarblingKeys: [ObjectIdentifier: SymmetricKey] = [:]
    /// Farbling as built for a site (and private session): each main-frame navigation needs it,
    /// and building it means three passes over a 46 KB template and three HMACs.
    @ObservationIgnored private var farblingSources: [FarblingSite: String] = [:]
    private struct FarblingSite: Hashable {
        let privateSession: ObjectIdentifier?
        let site: String
    }
    private static let farblingSourcesLimit = 8
    @ObservationIgnored private let advanced = AdvancedBlocking()
    @ObservationIgnored private let userAgentSuffix: String
    private(set) var filterChoices: FilterChoices
    /// Set by tests, for a folder, a filter set, a rule list store and downloads of their own.
    @ObservationIgnored var filterStorage = FilterLists.Storage.standard
    @ObservationIgnored var filterSet: (folder: URL, manifest: Manifest)?
    @ObservationIgnored var ruleListStore: WKContentRuleListStore?
    @ObservationIgnored var filterSession = URLSession.shared
    /// Why the user's choice of lists or filters isn't fully applied, for the Filter lists page.
    @ObservationIgnored private(set) var filterError: String?
    /// The loaded set's folder and its lists' rule counts, counted when Settings first shows them.
    @ObservationIgnored private var loadedFilters: (folder: URL, manifest: Manifest)?
    @ObservationIgnored private var shippedListRules: (folder: URL, updated: String, counts: [String: Int])?

    private static let disabledHostsKey = "disabledProtectionHosts"
    private static let spaceExceptionsKey = "spaceProtectionExceptions"
    private static let failedUpdatesKey = "failedFilterUpdates"
    private static let nextUpdateKey = "nextFilterUpdate"
    private static let filterChoicesKey = "filterChoices"
    private static let updateInterval: TimeInterval = 24 * 60 * 60
    nonisolated static let firstUpdateDelay = Duration.seconds(5 * 60)
    private static let downloadedFilters = URL.applicationSupportDirectory.appending(path: "Lithium/Filters")

    init() {
        disabledHosts = Set(UserDefaults.standard.stringArray(forKey: Self.disabledHostsKey) ?? [])
        spaceExceptions = Space.siteChoices(UserDefaults.standard.dictionary(forKey: Self.spaceExceptionsKey))
        (failedUpdates, nextUpdate) = Self.savedBackoff(in: .standard)
        filterChoices = UserDefaults.standard.data(forKey: Self.filterChoicesKey)
            .flatMap { try? JSONDecoder().decode(FilterChoices.self, from: $0) } ?? FilterChoices()

        farblingTemplate = Resources.bundle.url(forResource: "farbling", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

        let safari = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let safariVersion = safari?["CFBundleShortVersionString"] as? String ?? "26.0"
        userAgentSuffix = "Version/\(safariVersion) Safari/605.1.15"
    }

    /// The seed is an HMAC of the site, so a page that recovers it can't reach the key or another
    /// site's. The marker is an HMAC of the key alone: every site's copy must agree on it.
    static func farbling(_ template: String, key: SymmetricKey, site: String) -> String {
        template
            .replacingOccurrences(of: "__LITHIUM_SEED__", with: farblingValue("seed:\(site)", key: key))
            .replacingOccurrences(of: "__LITHIUM_MARK__", with: "m" + farblingValue("mark", key: key))
            .replacingOccurrences(of: "__LITHIUM_ADOPT__", with: adopterName(key: key))
    }

    /// Keyed like the marker, as a fixed name would tell every page it runs in Lithium.
    private static func adopterName(key: SymmetricKey) -> String {
        "a" + farblingValue("adopt", key: key)
    }

    private static func farblingValue(_ message: String, key: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
            .prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a response's policies require Trusted Types: "enforce" when its enforced one does,
    /// "report" when only its report-only one does. A page can't tell which applies; farbling needs to.
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

    /// Goes to every frame and runs only in documents at the response's address.
    static func trustedTypesScript(for response: URLResponse, key: SymmetricKey) -> String? {
        guard let mode = trustedTypes(of: response), let url = response.url else { return nil }
        return trustedTypesScript(modes: [trustedTypesAddress(url): mode], key: key)
    }

    static func trustedTypesScript(modes: [String: String], key: SymmetricKey) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let json = try? String(decoding: encoder.encode(modes), as: UTF8.self) else { return nil }
        return """
            (() => {
              const modes = { __proto__: null, ...\(json) }, href = location.href, at = href.indexOf('#');
              const mode = modes[at < 0 ? href : href.slice(0, at)];
              if (!mode) return;
              // A window its page kept goes through the copy that protected it (see farbling.js):
              // a `CustomEvent` the page left there would read the marker.
              const adopter = window['\(adopterName(key: key))'];
              if (typeof adopter === 'function') return adopter(document, mode);
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

    /// One script holds every address of the page and replaces the one before, so they don't pile up.
    /// Without WebKit's private call to remove one, each address gets a script of its own, once.
    func addTrustedTypesScript(_ enabled: Bool, for response: URLResponse, privateSession: ObjectIdentifier? = nil, to controller: WKUserContentController) {
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
        guard let source = Self.trustedTypesScript(modes: replaces ? modes : [address: mode], key: farblingKey(for: privateSession)) else { return }
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        // Added before the old one goes, so no document starts with neither.
        controller.addUserScript(script)
        if replaces, let last { _ = controller.perform(Self.removeUserScript, with: last.script) }
        trustedTypesScripts.setObject(TrustedTypesScript(script: script, modes: modes), forKey: controller)
    }

    /// The registrable domain (so `alice.github.io` and `bob.github.io` differ). A blob takes its
    /// creator's site; an opaque one gets a unique site, not the "" every site's would share.
    /// Nested `blob:` is treated as opaque: a page could nest thousands deep to stall the app.
    nonisolated static func farblingSite(_ url: URL) -> String {
        if url.scheme?.lowercased() == "blob" {
            let creator = URL(string: String(url.absoluteString.dropFirst(5)))
            let host = creator.flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0.host() : nil } ?? ""
            return host.isEmpty ? UUID().uuidString : SiteInfo.registrable(host)
        }
        guard let host = url.host(), !host.isEmpty else { return "" }
        return SiteInfo.registrable(host)
    }

    func start() {
        guard loadTask == nil else { return }
        loadTask = Task { await loadRuleLists() }
        lastLoad = loadTask
        // Set by scripts/test: each test's Browser would otherwise download and convert the lists.
        guard ProcessInfo.processInfo.environment["LITHIUM_NO_FILTER_UPDATES"] != "1" else { return }
        updateLoop = Task { [weak self] in
            await self?.loadTask?.value
            // Not while the app launches: a full update (downloads, conversion, engine build and
            // recompiling every group) would compete with the first pages for seconds of CPU.
            try? await Task.sleep(for: Self.firstUpdateDelay)
            while !Task.isCancelled {
                await self?.updateFiltersIfStale()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    /// Marks the update as running before returning: the settings page reads the state in the same reply.
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

    /// Filters dated in the future (clock set ahead) count as stale, or updates would stop until
    /// the clock caught up.
    static func needsUpdate(updated: Date?, matchesSources: Bool, complete: Bool, notBefore: Date, now: Date = Date()) -> Bool {
        guard now >= notBefore else { return false }
        let age = now.timeIntervalSince(updated ?? .distantPast)
        return !matchesSources || !complete || age > updateInterval || age < 0
    }

    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        min(60 * 60 * pow(2, Double(min(max(failures - 1, 0), 10))), updateInterval)
    }

    /// Runs with `isUpdatingFilters` set by the caller, and clears it when done.
    private func updateFilters() async {
        defer { isUpdatingFilters = false }
        guard var updater = FilterUpdater.bundled() else { return }
        updater.session = filterSession
        let destination = Self.downloadedFilters
        var updated = false
        await updateChosenLists()
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await Task.detached(priority: .utility) { try await updater.update(into: destination) }.value
            updated = true
        } catch {
            NSLog("Lithium: filter update failed: %@", error.localizedDescription)
        }
        // Also when only the chosen lists changed.
        if updated || !filterChoices.extraLists.isEmpty { await reloadRuleLists() }
        updated = updated && filtersComplete
        (failedUpdates, nextUpdate) = Self.saveBackoff(afterFailures: updated ? 0 : failedUpdates + 1, in: .standard)
    }

    static func saveBackoff(afterFailures failures: Int, in defaults: UserDefaults, now: Date = Date())
        -> (failures: Int, notBefore: Date) {
        let notBefore = failures == 0 ? Date.distantPast : now.addingTimeInterval(retryDelay(afterFailures: failures))
        defaults.set(failures, forKey: failedUpdatesKey)
        defaults.set(notBefore.timeIntervalSinceReferenceDate, forKey: nextUpdateKey)
        return (failures, notBefore)
    }

    /// A wait more than a day away (the clock was turned back) is cut to a day.
    static func savedBackoff(in defaults: UserDefaults, now: Date = Date()) -> (failures: Int, notBefore: Date) {
        guard defaults.object(forKey: nextUpdateKey) != nil else { return (0, .distantPast) }
        let saved = Date(timeIntervalSinceReferenceDate: defaults.double(forKey: nextUpdateKey))
        return (defaults.integer(forKey: failedUpdatesKey), min(saved, now.addingTimeInterval(updateInterval)))
    }

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

    func isEnabled(for url: URL?, privateSession: ObjectIdentifier? = nil, space: Space.ID? = nil) -> Bool {
        guard let host = Self.siteHost(url) else { return true }
        if let privateSession, let enabled = privateExceptions[privateSession]?[host] { return enabled }
        if let space, let enabled = spaceExceptions[space]?[host] { return enabled }
        return !disabledHosts.contains(host)
    }

    /// A private tab's choice stays in memory only: saved, it would record the site it visited.
    func setEnabled(_ enabled: Bool, for url: URL?, privateSession: ObjectIdentifier? = nil, space: Space.ID? = nil) {
        guard let host = Self.siteHost(url) else { return }
        if let privateSession {
            privateExceptions[privateSession, default: [:]][host] = enabled
        } else if let space {
            spaceExceptions[space, default: [:]][host] = enabled
            UserDefaults.standard.set(Space.stored(spaceExceptions), forKey: Self.spaceExceptionsKey)
        } else {
            setEnabled(enabled, host: host)
        }
    }

    func forget(privateSession: ObjectIdentifier) {
        privateExceptions[privateSession] = nil
        privateFarblingKeys[privateSession] = nil
        // A later session may reuse the identifier: it mustn't get this one's seeds.
        farblingSources = farblingSources.filter { $0.key.privateSession != privateSession }
    }

    private func farblingKey(for privateSession: ObjectIdentifier?) -> SymmetricKey {
        guard let privateSession else { return farblingKey }
        if let key = privateFarblingKeys[privateSession] { return key }
        let key = SymmetricKey(size: .bits256)
        privateFarblingKeys[privateSession] = key
        return key
    }

    func forget(space: Space.ID) {
        guard spaceExceptions.removeValue(forKey: space) != nil else { return }
        UserDefaults.standard.set(Space.stored(spaceExceptions), forKey: Self.spaceExceptionsKey)
    }

    /// Takes the host as is: rebuilt into an address, an IPv6 one may not parse back to the same host.
    func setEnabled(_ enabled: Bool, host: String) {
        if enabled { disabledHosts.remove(host) } else { disabledHosts.insert(host) }
        UserDefaults.standard.set(disabledHosts.sorted(), forKey: Self.disabledHostsKey)
    }

    func applyRuleLists(_ enabled: Bool, to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        if enabled { ruleLists.forEach(controller.add) }
    }

    /// The caller has already reset the controller's scripts.
    func addScripts(_ enabled: Bool, for url: URL, privateSession: ObjectIdentifier? = nil, to controller: WKUserContentController) {
        scripts(enabled, for: url, privateSession: privateSession).forEach(controller.addUserScript)
    }

    func scripts(_ enabled: Bool, for url: URL, privateSession: ObjectIdentifier? = nil) -> [WKUserScript] {
        guard enabled else { return [] }
        // Every frame gets the top page's site, as in Brave: a frame embedded on many sites
        // farbles differently on each.
        let farbling = WKUserScript(source: farblingSource(for: url, privateSession: privateSession),
                                    injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        guard let source = advanced.script(for: url) else { return [farbling] }
        return [farbling, WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)]
    }

    func farblingSource(for url: URL, privateSession: ObjectIdentifier? = nil) -> String {
        let site = FarblingSite(privateSession: privateSession, site: Self.farblingSite(url))
        if let source = farblingSources[site] { return source }
        let source = Self.farbling(farblingTemplate, key: farblingKey(for: privateSession), site: site.site)
        if farblingSources.count >= Self.farblingSourcesLimit { farblingSources.removeAll(keepingCapacity: true) }
        farblingSources[site] = source
        return source
    }

    /// Advanced rules looked up for the frame's own site; the script runs only in frames of that host.
    func frameScript(_ enabled: Bool, for frame: URL, in page: URL) -> WKUserScript? {
        guard enabled, let source = advanced.script(for: frame, inFrameOf: page) else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    /// WebKit's Advanced Tracking and Fingerprinting Protection. Private API, so it is applied
    /// only when this WebKit build has it.
    static func setEngineProtections(_ enabled: Bool, on preferences: WKWebpagePreferences) {
        guard preferences.responds(to: Selector(("_setNetworkConnectionIntegrityEnabled:"))) else { return }
        preferences.setValue(enabled, forKey: "networkConnectionIntegrityEnabled")
    }

    static func siteHost(_ url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The list as WebKit gets it, with two performance changes to element hiding:
    /// - Site-specific hiding rules with url-filter ".*" are limited to the document load: WebKit
    ///   checked every subresource against them (2.3 times slower on Speedometer's news sites).
    /// - "#x ~ *" makes WebKit walk earlier siblings at each style change (44 ms per restyle on a
    ///   big page); it becomes "#x + *, #x + * + *, #x + * + * + *", one sibling check each.
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
        guard let (folder, manifest) = filterSet ?? Self.currentFilters(),
              let store = ruleListStore ?? WKContentRuleListStore.default() else { return }

        let stamp = manifest.updated.filter(\.isNumber)
        loadedFilters = (folder, manifest)
        // Only once the user changed a list or wrote a filter: the shipped set loads as it always did.
        let choices = filterChoices, storage = filterStorage
        let customized = !choices.isDefault || storage.hasMyFilters
        let chosen = !customized ? nil : await Task.detached(priority: .userInitiated) {
            ChosenFilters.build(base: folder, manifest: manifest, choices: choices, storage: storage)
        }.value
        let failed = customized && chosen == nil
        if failed {
            filterError = "Lithium couldn’t apply your filter lists. It will try again with the next change or update."
        }
        // Instead, the shipped groups that hold no list the user turned off, and the shipped engine
        // only if none is off: it is built from every shipped list. Keeping what was loaded would
        // keep a list just turned off blocking.
        let shippedEngine = choices.off.isEmpty
        let shipped = FilterGroup.shipped(in: folder, manifest: manifest).filter { group in
            manifest.groups[group.name]?.lists.map { choices.off.isDisjoint(with: $0) } ?? shippedEngine
        }
        let groups = await Self.loadGroups(chosen?.groups ?? shipped, into: store)
        if let chosen {
            let discarded = chosen.discarded.values.reduce(0, +)
            filterError = !groups.complete ? "Some of your filter lists or filters couldn’t be applied."
                : discarded > 0 ? "Over WebKit’s limit: \(discarded.formatted()) rules of the lists you chose or your filters are left out."
                : nil
        } else if !customized {
            filterError = nil
        }
        ruleLists = groups.lists
        let engineRules = chosen.map { $0.advancedRules + $0.scriptletRules }
            ?? (shippedEngine ? (manifest.advancedRules ?? 0) + (manifest.scriptletRules ?? 0) : 0)
        ruleCount = groups.ruleCount + engineRules
        filtersUpdated = manifest.date
        filtersMatchSources = FilterUpdater.bundled()?.sources.built(manifest) ?? true
        // Incomplete after a failed build, so the update backs off instead of downloading every hour.
        filtersComplete = !failed && groups.complete && (manifest.failedLists ?? []).isEmpty
        generation += 1

        // Awaited, so the tab restored at launch waits for uBO's scriptlets instead of playing ads.
        if let chosen {
            await advanced.load(folder: chosen.engineFolder, stamp: chosen.engineStamp)
        } else if shippedEngine {
            await advanced.load(folder: folder, stamp: stamp)
        } else {
            advanced.unload()
        }
    }

    static func loadGroups(from folder: URL, manifest: Manifest, into store: WKContentRuleListStore) async
        -> (lists: [WKContentRuleList], ruleCount: Int, complete: Bool) {
        await loadGroups(FilterGroup.shipped(in: folder, manifest: manifest), into: store)
    }

    /// A group that fails to compile keeps its list from an earlier set, uncounted, and marks the
    /// set incomplete so it is tried again. A group compiled before is only looked up.
    static func loadGroups(_ groups: [FilterGroup], into store: WKContentRuleListStore) async
        -> (lists: [WKContentRuleList], ruleCount: Int, complete: Bool) {
        let available = await store.availableIdentifiers() ?? []
        var lists: [WKContentRuleList] = []
        var kept: Set<String> = []
        var ruleCount = 0
        var complete = true
        // Started together, as WebKit compiles on a concurrent queue: the first page waits for the
        // slowest group rather than for all of them in turn. Kept in the groups' order.
        let compiles = groups.map { group in
            (group, Task { await compiled(group, store: store) })
        }
        for (entry, compile) in compiles {
            let (group, identifier) = (entry.name, entry.identifier)
            if let list = await compile.value {
                lists.append(list)
                kept.insert(identifier)
                ruleCount += entry.webkitRules
                continue
            }
            complete = false
            // Only a shipped group falls back, and the user's filters to their last version: an
            // earlier set's other groups may hold a list the user has since turned off.
            let previous: String?
            if identifier.wholeMatch(of: /lithium-(.+)-\d+-p\d+/) != nil {
                previous = available
                    .filter { $0.wholeMatch(of: /lithium-(.+)-\d+-p\d+/).map { String($0.1) } == group }
                    .max { $0.filter(\.isNumber) < $1.filter(\.isNumber) }
            } else if group == FilterLists.myFiltersID {
                previous = available.first { $0.wholeMatch(of: /lithium-my-filters-h[0-9a-f]+-p\d+/) != nil }
            } else {
                previous = nil
            }
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

    private static func compiled(_ group: FilterGroup, store: WKContentRuleListStore) async -> WKContentRuleList? {
        if let cached = try? await store.contentRuleList(forIdentifier: group.identifier) { return cached }
        let file = group.file
        guard let json = await Task.detached(priority: .utility, operation: { Self.prepared(file) }).value else {
            NSLog("Lithium: failed to read %@ filters", group.name)
            return nil
        }
        do {
            return try await store.compileContentRuleList(forIdentifier: group.identifier, encodedContentRuleList: json)
        } catch {
            NSLog("Lithium: failed to compile %@ filters: %@", group.name, error.localizedDescription)
            return nil
        }
    }

    // MARK: Choosing filter lists

    /// Turns a shipped or catalog list on or off. A catalog list is downloaded when first turned on;
    /// returns a message for the user when it can't be. Whether the set applies is `filterError`.
    func setFilterList(_ id: String, enabled: Bool) async -> String? {
        var choices = filterChoices
        if FilterLists.shipped.contains(where: { $0.id == id }) {
            if enabled { choices.off.remove(id) } else { choices.off.insert(id) }
        } else if let info = FilterLists.catalog.first(where: { $0.id == id }), let url = info.url {
            if enabled {
                guard let copy = await download(id: id, url: url) else { return "Couldn’t download \(info.name). Try again later." }
                choices = filterChoices
                choices.copies[id] = copy
                choices.on.insert(id)
            } else {
                choices = filterChoices
                choices.on.remove(id)
                forgetCopy(of: id, in: &choices)
            }
        } else if !enabled, let url = filterChoices.added.first(where: { FilterLists.id(of: $0) == id }) {
            choices.added.removeAll { $0 == url }
            forgetCopy(of: id, in: &choices)
        } else {
            return nil
        }
        await apply(choices)
        return nil
    }

    /// Adds a list by its address once it downloads as a filter list; returns why it wasn't added.
    func addFilterList(_ text: String) async -> String? {
        guard let url = FilterLists.validatedURL(text) else { return "Enter an address starting with https:// or http://." }
        let id = FilterLists.id(of: url)
        guard !filterChoices.added.contains(url) else { return "This list is already added." }
        if FilterLists.catalog.contains(where: { $0.url == url }) { return "This list is in the catalog: turn it on there." }
        guard let copy = await download(id: id, url: url) else { return "That address doesn’t lead to a filter list." }
        var choices = filterChoices
        choices.added.append(url)
        choices.copies[id] = copy
        await apply(choices)
        return nil
    }

    var myFilters: String { filterStorage.readMyFilters() }

    /// Saved and compiled at once: pages get them from their next load. Returns why they weren't
    /// saved; why they aren't applied is `filterError`, which may be about another list.
    func setMyFilters(_ text: String) async -> String? {
        do {
            try filterStorage.writeMyFilters(text)
        } catch {
            NSLog("Lithium: failed to save your filters: %@", error.localizedDescription)
            return "Couldn’t save your filters: \(error.localizedDescription)"
        }
        await reloadRuleLists()
        return nil
    }

    /// Each list's rule count, as Settings shows it. Counted once per filter set, off the main thread.
    func filterListRules() async -> [String: Int] {
        guard let (folder, manifest) = loadedFilters else { return [:] }
        if let counted = shippedListRules, counted.folder == folder, counted.updated == manifest.updated { return counted.counts }
        let names = Set(manifest.groups.values.compactMap(\.lists).joined())
        let counts = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: names.map { name in
                let text = (try? String(contentsOf: folder.appending(path: "lists/\(name).txt"), encoding: .utf8)) ?? ""
                return (name, text.isEmpty ? 0 : text.split(whereSeparator: \.isNewline).count)
            })
        }.value
        shippedListRules = (folder, manifest.updated, counts)
        return counts
    }

    var failedFilterLists: [String] { loadedFilters?.manifest.failedLists ?? [] }

    /// Saved even when it can't be applied, so it is tried again.
    private func apply(_ choices: FilterChoices) async {
        filterChoices = choices
        UserDefaults.standard.set(try? JSONEncoder().encode(choices), forKey: Self.filterChoicesKey)
        await reloadRuleLists()
    }

    private func download(id: String, url: URL) async -> FilterChoices.Copy? {
        do {
            let lines = try await FilterLists.download(url, session: filterSession)
            try filterStorage.save(lines, for: id)
            return FilterChoices.Copy(rules: lines.count, updated: Date())
        } catch {
            NSLog("Lithium: filter list %@ failed to download: %@", id, error.localizedDescription)
            return nil
        }
    }

    private func forgetCopy(of id: String, in choices: inout FilterChoices) {
        choices.copies[id] = nil
        try? FileManager.default.removeItem(at: filterStorage.copy(of: id))
    }

    /// With the shipped lists' daily update: a list that fails keeps its last copy.
    func updateChosenLists() async {
        let lists = filterChoices.extraLists
        guard !lists.isEmpty else { return }
        var copies: [String: FilterChoices.Copy] = [:]
        for list in lists {
            copies[list.id] = await download(id: list.id, url: list.url)
        }
        var choices = filterChoices
        for list in lists where choices.extraLists.contains(where: { $0.id == list.id }) {
            if let copy = copies[list.id] { choices.copies[list.id] = copy } else { choices.copies[list.id]?.failed = true }
        }
        // Removed while it downloaded: its copy was saved after `forgetCopy` deleted it.
        for list in lists where !choices.extraLists.contains(where: { $0.id == list.id }) {
            try? FileManager.default.removeItem(at: filterStorage.copy(of: list.id))
        }
        filterChoices = choices
        UserDefaults.standard.set(try? JSONEncoder().encode(choices), forKey: Self.filterChoicesKey)
    }
}
