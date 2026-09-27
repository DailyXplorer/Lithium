import AppKit
import Observation
import WebKit

/// An extension added from the Chrome Web Store, as saved in `Extensions/installed.json`.
struct InstalledExtension: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var version: String
    var isEnabled: Bool
}

/// Web extensions, run by WebKit's own extension support (`WKWebExtensionController`). Each one is
/// kept as the ZIP archive of its Chrome Web Store package and loaded at launch. Lithium shows
/// WebKit its window and tabs (`ExtensionWindow`, `Tab`), and one toolbar button lists them.
@MainActor
@Observable
final class Extensions: NSObject {
    private(set) var installed: [InstalledExtension] {
        didSet { save() }
    }
    /// Loaded extensions by id; one that is turned off or failed to load has none.
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    /// Bumped when an extension's button changes (icon, badge, title), so the list redraws it.
    private(set) var actionsRevision = 0

    @ObservationIgnored let controller: WKWebExtensionController
    @ObservationIgnored weak var browser: Browser?
    @ObservationIgnored private(set) lazy var window = ExtensionWindow(extensions: self)
    @ObservationIgnored private(set) lazy var webstoreBridge = WebstoreBridge(extensions: self)
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The toolbar's extensions button, where their popups open.
    @ObservationIgnored weak var popupAnchor: NSView?

    static let scheme = "webkit-extension"

    init(
        folder: URL = .applicationSupportDirectory.appending(path: "Lithium/Extensions"),
        configuration: WKWebExtensionController.Configuration = .default()
    ) {
        self.folder = folder
        controller = WKWebExtensionController(configuration: configuration)
        installed = (try? JSONDecoder().decode([InstalledExtension].self, from: Data(contentsOf: folder.appending(path: "installed.json")))) ?? []
        super.init()
        controller.delegate = self
    }

    func start() {
        guard loadTask == nil else { return }
        controller.didOpenWindow(window)
        controller.didFocusWindow(window)
        loadTask = Task {
            for entry in installed where entry.isEnabled { await load(entry) }
        }
    }

    /// Pages wait for this before loading, so the tab restored at launch gets its content scripts.
    func waitUntilLoaded() async {
        await loadTask?.value
    }

    private func archive(_ id: String) -> URL {
        folder.appending(path: "\(id).zip")
    }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(installed).write(to: folder.appending(path: "installed.json"), options: .atomic)
    }

    private func load(_ entry: InstalledExtension) async {
        guard contexts[entry.id] == nil else { return }
        do {
            try activate(try await WKWebExtension(resourceBaseURL: archive(entry.id)), id: entry.id)
        } catch {
            NSLog("Lithium: couldn’t load extension %@: %@", entry.id, error.localizedDescription)
        }
    }

    private func activate(_ webExtension: WKWebExtension, id: String) throws {
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = id
        // A fixed address keeps the extension's own storage (localStorage, IndexedDB) across launches.
        context.baseURL = URL(string: "\(Self.scheme)://\(id)/")!
        // The user agreed to these when adding it.
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in webExtension.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        try controller.load(context)
        contexts[id] = context
    }

    /// Downloads extension `id` from the Chrome Web Store and runs it, replacing an older version.
    func install(id: String) async throws {
        let archive = try ChromeWebStore.archive(fromPackage: try await ChromeWebStore.download(id), id: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appending(path: ".\(id)-\(UUID().uuidString).zip")
        try archive.write(to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        // WebKit unpacks the archive here, so a broken one is refused before anything changes.
        let webExtension = try await WKWebExtension(resourceBaseURL: staging)

        if let old = contexts.removeValue(forKey: id) { try? controller.unload(old) }
        try? FileManager.default.removeItem(at: self.archive(id))
        try FileManager.default.moveItem(at: staging, to: self.archive(id))
        try activate(webExtension, id: id)

        let entry = InstalledExtension(id: id, name: webExtension.displayName ?? id, version: webExtension.version ?? "", isEnabled: true)
        if let index = installed.firstIndex(where: { $0.id == id }) { installed[index] = entry } else { installed.append(entry) }
    }

    /// Removes the extension and, as Chrome does, the data it stored.
    func remove(id: String) async {
        if let context = contexts.removeValue(forKey: id) { try? controller.unload(context) }
        installed.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: archive(id))
        let types: Set<WKWebExtension.DataType> = [.local, .session, .synchronized]
        let records = await controller.dataRecords(ofTypes: types).filter { $0.uniqueIdentifier == id }
        if !records.isEmpty { await controller.removeData(ofTypes: types, from: records) }
    }

    func setEnabled(_ enabled: Bool, id: String) async {
        guard let index = installed.firstIndex(where: { $0.id == id }), installed[index].isEnabled != enabled else { return }
        installed[index].isEnabled = enabled
        if enabled {
            await load(installed[index])
        } else if let context = contexts.removeValue(forKey: id) {
            try? controller.unload(context)
        }
    }

    // MARK: Pages

    /// Extension pages (options, a tab an extension opens) load in their extension's own configuration.
    func configuration(for url: URL?) -> WKWebViewConfiguration? {
        guard url?.scheme == Self.scheme, let id = url?.host() else { return nil }
        return contexts[id]?.webViewConfiguration
    }

    func openOptions(id: String) {
        guard let url = contexts[id]?.optionsPageURL else { return }
        browser?.newTab(url: url, configuration: configuration(for: url))
    }

    // MARK: Toolbar

    func performAction(id: String, in tab: Tab?) {
        contexts[id]?.performAction(for: tab)
    }

    // MARK: Tabs

    func didOpen(_ tab: Tab) {
        controller.didOpenTab(tab)
    }

    func didClose(_ tab: Tab) {
        controller.didCloseTab(tab, windowIsClosing: false)
    }

    func didActivate(_ tab: Tab, previous: Tab?) {
        controller.didActivateTab(tab, previousActiveTab: previous)
    }

    func didChange(_ properties: WKWebExtension.TabChangedProperties, of tab: Tab) {
        controller.didChangeTabProperties(properties, for: tab)
    }
}

extension Extensions: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext
    ) async throws -> (any WKWebExtensionTab)? {
        guard let browser else { return nil }
        let url = configuration.url
        return browser.newTab(url: url, selecting: configuration.shouldBeActive, configuration: self.configuration(for: url))
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        openOptions(id: extensionContext.uniqueIdentifier)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext
    ) async throws {
        guard let popover = action.popupPopover else { return }
        if let anchor = popupAnchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let content = NSApp.keyWindow?.contentView {
            popover.show(relativeTo: NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 44, width: 1, height: 1), of: content, preferredEdge: .minY)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        actionsRevision &+= 1
    }

    /// Permissions an extension asks for while it runs (its optional ones).
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext
    ) async -> (Set<WKWebExtension.Permission>, Date?) {
        let allowed = await confirm(extensionContext, wants: permissions.map(\.rawValue).sorted())
        return (allowed ? permissions : [], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext
    ) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let allowed = await confirm(extensionContext, wants: matchPatterns.map(\.description).sorted())
        return (allowed ? matchPatterns : [], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext
    ) async -> (Set<URL>, Date?) {
        let allowed = await confirm(extensionContext, wants: urls.compactMap { $0.host() }.sorted())
        return (allowed ? urls : [], nil)
    }

    private func confirm(_ context: WKWebExtensionContext, wants access: [String]) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "“\(context.webExtension.displayName ?? "An extension")” wants more access"
        alert.informativeText = access.map { "• \($0)" }.joined(separator: "\n")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        guard let window = NSApp.keyWindow else { return alert.runModal() == .alertFirstButtonReturn }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
}

/// Lithium's window, as extensions see it (`chrome.windows`).
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    private unowned let extensions: Extensions

    init(extensions: Extensions) {
        self.extensions = extensions
    }

    private var nsWindow: NSWindow? {
        extensions.browser?.selectedTab?.webView.window ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        extensions.browser?.navigationOrder ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        extensions.browser?.selectedTab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let nsWindow else { return .normal }
        if nsWindow.isMiniaturized { return .minimized }
        return nsWindow.styleMask.contains(.fullScreen) ? .fullscreen : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        nsWindow?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        nsWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null
    }

    func focus(for context: WKWebExtensionContext) async throws {
        NSApp.activate()
        nsWindow?.makeKeyAndOrderFront(nil)
    }
}
