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

    @ObservationIgnored private var ruleLists: [WKContentRuleList] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var updateLoop: Task<Void, Never>?
    @ObservationIgnored private let farbling: WKUserScript
    @ObservationIgnored private let advanced = AdvancedBlocking()
    @ObservationIgnored private let userAgentSuffix: String

    private static let disabledHostsKey = "disabledProtectionHosts"
    private static let updateInterval: TimeInterval = 24 * 60 * 60
    private static let downloadedFilters = URL.applicationSupportDirectory.appending(path: "Lithium/Filters")

    init() {
        disabledHosts = Set(UserDefaults.standard.stringArray(forKey: Self.disabledHostsKey) ?? [])

        let key = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let template = Resources.bundle.url(forResource: "farbling", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        farbling = WKUserScript(
            source: template.replacingOccurrences(of: "__LITHIUM_SESSION_KEY__", with: key),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )

        let safari = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let safariVersion = safari?["CFBundleShortVersionString"] as? String ?? "26.0"
        userAgentSuffix = "Version/\(safariVersion) Safari/605.1.15"
    }

    func start() {
        guard loadTask == nil else { return }
        loadTask = Task { await loadRuleLists() }
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
        guard !isUpdatingFilters, Date().timeIntervalSince(filtersUpdated ?? .distantPast) > Self.updateInterval else { return }
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
    func addScripts(_ enabled: Bool, for url: URL, to controller: WKUserContentController) {
        guard enabled else { return }
        controller.addUserScript(farbling)
        if let source = advanced.script(for: url) {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
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

    private func loadRuleLists() async {
        guard let (folder, manifest) = Self.currentFilters(),
              let store = WKContentRuleListStore.default() else { return }

        let stamp = manifest.updated.filter(\.isNumber)
        var lists: [WKContentRuleList] = []
        var current: Set<String> = []
        for group in manifest.groups.keys.sorted() {
            let identifier = "lithium-\(group)-\(stamp)"
            current.insert(identifier)
            if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
                lists.append(cached)
                continue
            }
            guard let json = try? String(contentsOf: folder.appending(path: "\(group).json"), encoding: .utf8) else { continue }
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
        generation += 1

        // Awaited, so pages also wait for the in-page engine (waitUntilReady). Without it, the tab
        // restored at launch loads without uBO's scriptlets while the engine builds, and plays ads.
        // A later rebuild swaps the new engine in without making pages wait.
        await advanced.load(folder: folder, stamp: stamp)
    }
}
