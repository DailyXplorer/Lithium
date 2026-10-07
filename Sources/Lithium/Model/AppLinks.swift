import AppKit
import Observation

/// A link to another app's address (`zoommtg:`, `slack:`), clicked in a page or a PDF. Like
/// Chrome, Lithium asks first, once per site and scheme: "Open Zoom?", which the user can let the
/// site skip from then on. `mailto:` opens Mail as it always has.
struct AppLinkRequest: Identifiable, Equatable {
    let id = UUID()
    let tabID: Tab.ID
    let url: URL
    let host: String
    let app: URL
    /// Not in a private tab, nor for a page with no host: nothing to remember it by.
    let canRemember: Bool
    /// A click landing sooner was meant for the page: the prompt appeared under it.
    let shown = Date()

    var appName: String { AppLinks.name(ofApp: app) }
    var scheme: String { url.scheme?.lowercased() ?? "" }
}

@MainActor
@Observable
final class AppLinks {
    /// The schemes each site may open without asking, until the user changes it in Settings.
    private(set) var allowed: [String: Set<String>]
    private(set) var pending: [AppLinkRequest] = []
    @ObservationIgnored private var waiting: [AppLinkRequest.ID: CheckedContinuation<Bool, Never>] = [:]
    /// The app that opens an address, nil when none does; replaced in tests.
    @ObservationIgnored var appOpening: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }

    /// "Zoom", from zoom.us.app, as Finder shows it.
    nonisolated static func name(ofApp app: URL) -> String {
        (FileManager.default.displayName(atPath: app.path) as NSString).deletingPathExtension
    }

    private static let storageKey = "siteAppLinks"
    static let unasked: Set<String> = ["mailto"]

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: [String]] ?? [:]
        allowed = stored.mapValues(Set.init)
    }

    /// Opens `url` in its app once the user agrees, or straight away for a site allowed to.
    /// `host` is the site whose page has the link; private tabs never remember an answer.
    func open(_ url: URL, from host: String, tabID: Tab.ID, isPrivate: Bool) async {
        guard let scheme = url.scheme?.lowercased() else { return }
        if Self.unasked.contains(scheme) || allowed[host]?.contains(scheme) == true {
            return ExternalApps.open(url)
        }
        // Nothing would open it: no question to ask.
        guard let app = appOpening(url) else { return }
        // One prompt per tab: a later click asks about its own link instead.
        pending.filter { $0.tabID == tabID }.forEach { resolve($0.id, false) }
        let request = AppLinkRequest(tabID: tabID, url: url, host: host, app: app, canRemember: !isPrivate && !host.isEmpty)
        let accepted = await withCheckedContinuation { continuation in
            waiting[request.id] = continuation
            pending.append(request)
        }
        if accepted { ExternalApps.open(url) }
    }

    /// Open or Cancel. Only Open with "Always allow" checked is remembered.
    func answer(_ request: AppLinkRequest, open: Bool, always: Bool = false) {
        if open, always, request.canRemember { set(true, scheme: request.scheme, host: request.host) }
        resolve(request.id, open)
    }

    /// Unanswered prompts of a closed tab, or of the page it left, open nothing.
    func cancel(tabID: Tab.ID) {
        pending.filter { $0.tabID == tabID }.forEach { resolve($0.id, false) }
    }

    func set(_ allow: Bool, scheme: String, host: String) {
        var schemes = allowed[host] ?? []
        if allow { schemes.insert(scheme) } else { schemes.remove(scheme) }
        allowed[host] = schemes.isEmpty ? nil : schemes
        UserDefaults.standard.set(allowed.mapValues { $0.sorted() }, forKey: Self.storageKey)
    }

    private func resolve(_ id: AppLinkRequest.ID, _ open: Bool) {
        pending.removeAll { $0.id == id }
        waiting.removeValue(forKey: id)?.resume(returning: open)
    }
}
