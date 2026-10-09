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

/// Web extensions, run by `WKWebExtensionController`. Each is kept as the ZIP archive of its Chrome
/// Web Store package, with an unpacked copy loaded at launch.
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
    /// The last install or removal of each extension, which the next one waits for: both swap
    /// its files and context across awaits, and overlapping could leave it running twice.
    @ObservationIgnored private var changes: [String: Task<Void, Never>] = [:]
    /// Why the list couldn't be written last time: an install doesn't report success for an
    /// extension that would be gone after a relaunch.
    @ObservationIgnored private var saveError: Error?
    @ObservationIgnored weak var popupAnchor: NSView?
    /// The tab WebKit was last told is active: told one tab and answered another, WebKit fails
    /// extensions' tab calls.
    @ObservationIgnored private(set) weak var activeTab: Tab?
    @ObservationIgnored private(set) var isFocused = true
    @ObservationIgnored nonisolated(unsafe) private var activeObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private(set) var nativeHosts: [String: [NativeMessaging.Host]] = [:]
    /// Where hosts are looked up; tests use their own folder.
    @ObservationIgnored var nativeHostFolders = NativeMessaging.folders
    /// The ports `chrome.idle` listens on, per extension: password managers lock when the screen
    /// does, which only this tells them.
    @ObservationIgnored private(set) var idlePorts: [String: [WKWebExtension.MessagePort]] = [:]
    @ObservationIgnored nonisolated(unsafe) private var lockObservers: [any NSObjectProtocol] = []
    /// Whether the screen is locked now; tests answer for the Mac.
    @ObservationIgnored var isScreenLocked: () -> Bool = {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// The name `extension-compat.js` connects to for `chrome.idle`, answered by Lithium itself.
    static let idleHost = "lithium.idle"

    static let scheme = "webkit-extension"

    /// A file would load with read access to its whole folder, and Lithium's own pages can turn
    /// protections off: an extension opens neither, as agents can't.
    static func mayOpen(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return true }
        return scheme != "file" && scheme != Internal.scheme
    }

    struct RefusedAddress: LocalizedError {
        var errorDescription: String? { "Extensions can’t open files or Lithium’s own pages." }
    }

    init(
        folder: URL = .applicationSupportDirectory.appending(path: "Lithium/Extensions"),
        configuration: WKWebExtensionController.Configuration = .default()
    ) {
        self.folder = folder
        controller = WKWebExtensionController(configuration: configuration)
        installed = StoredFile.readList(InstalledExtension.self, at: folder.appending(path: "installed.json"))
        super.init()
        controller.delegate = self
    }

    deinit {
        activeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lockObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }

    func start() {
        guard loadTask == nil else { return }
        controller.didOpenWindow(window)
        controller.didFocusWindow(window)
        activeObservers = [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)].map { name, isActive in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidChangeActive(isActive) }
            }
        }
        loadTask = Task {
            for entry in installed where entry.isEnabled { await load(entry) }
        }
    }

    /// Pages wait for this before loading, so the tab restored at launch gets its content scripts.
    func waitUntilLoaded() async {
        await loadTask?.value
    }

    /// WebKit unpacks a ZIP archive at every launch (190 ms for 1Password's, freezing the window);
    /// unpacked files open in 2 ms.
    private func files(_ id: String) -> URL {
        folder.appending(path: id, directoryHint: .isDirectory)
    }

    /// Kept next to the files, so a build of Lithium from before they were unpacked still finds it.
    private func archive(_ id: String) -> URL {
        folder.appending(path: "\(id).zip")
    }

    /// Also when a build that only writes the archive replaced it since.
    private func unpackIfNeeded(_ id: String) async throws {
        let modified = { (url: URL) in try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        guard let archived = modified(archive(id)) else { return }
        if let unpacked = modified(files(id)), unpacked >= archived { return }
        try await Self.unpack(archive(id), into: files(id))
    }

    nonisolated private static func unpack(_ archive: URL, into destination: URL) async throws {
        let staging = destination.deletingLastPathComponent().appending(path: ".unpacking-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, staging.path]
        let status = try await withCheckedThrowingContinuation { continuation in
            ditto.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try ditto.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else { throw CocoaError(.fileReadCorruptFile) }
        // WebKit serves an extension's files from its folder: a link in the package could lead
        // it to any file the user can read.
        let items = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey])
        if items?.contains(where: { (try? ($0 as? URL)?.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }) == true {
            throw ChromeWebStore.PackageError.notAPackage
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(installed).write(to: folder.appending(path: "installed.json"), options: .atomic)
            saveError = nil
        } catch {
            saveError = error
            NSLog("Lithium: failed to save the extension list: %@", error.localizedDescription)
        }
    }

    private func load(_ entry: InstalledExtension) async {
        guard contexts[entry.id] == nil else { return }
        do {
            try await unpackIfNeeded(entry.id)
            let webExtension = try await open(entry.id)
            // Turned off, removed or loaded by another call while it was opening.
            guard installed.first(where: { $0.id == entry.id })?.isEnabled == true, contexts[entry.id] == nil else { return }
            try activate(webExtension, id: entry.id)
        } catch {
            NSLog("Lithium: couldn’t load extension %@: %@", entry.id, error.localizedDescription)
        }
    }

    /// Prepares the files (`ExtensionCompatibility`) before WebKit opens them.
    private func open(_ id: String) async throws -> WKWebExtension {
        do {
            try ExtensionCompatibility.apply(to: files(id))
        } catch {
            NSLog("Lithium: couldn’t prepare extension %@: %@", id, error.localizedDescription)
        }
        return try await WKWebExtension(resourceBaseURL: files(id))
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
        // A load that ended first (at launch, from the settings switch) is replaced, not left running.
        unload(id)
        try controller.load(context)
        contexts[id] = context
    }

    /// The package must ask for no more than the access the user `approved`.
    func install(id: String, approved: ChromeWebStore.Access) async throws {
        let package = try await ChromeWebStore.download(id)
        try await install(archive: try ChromeWebStore.archive(fromPackage: package, id: id), id: id, approved: approved)
    }

    /// Every permission requested is granted, so with `approved` set, one asking for more is refused.
    func install(archive: Data, id: String, approved: ChromeWebStore.Access? = nil) async throws {
        try await serially(id) { try await self.replace(id, with: archive, approved: approved) }
    }

    private func replace(_ id: String, with archive: Data, approved: ChromeWebStore.Access?) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appending(path: ".\(id)-\(UUID().uuidString).zip")
        try archive.write(to: package)
        defer { try? FileManager.default.removeItem(at: package) }
        let staging = folder.appending(path: ".\(id)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try await Self.unpack(package, into: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        // A broken package, or one asking for more than the user saw, is refused here, before anything changes.
        let staged = try await WKWebExtension(resourceBaseURL: staging)
        if let approved {
            guard let data = try? Data(contentsOf: staging.appending(path: "manifest.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any] else {
                throw ChromeWebStore.PackageError.notAPackage
            }
            // `activate` grants what WebKit reads from the package, so that is checked too.
            let granted = ChromeWebStore.Access(
                permissions: staged.requestedPermissions.map(\.rawValue),
                patterns: staged.allRequestedMatchPatterns.map(\.string)
            )
            guard ChromeWebStore.Access(manifest: manifest).isCovered(by: approved), granted.isCovered(by: approved) else {
                throw ChromeWebStore.PackageError.moreAccess
            }
        }

        unload(id)
        try? FileManager.default.removeItem(at: files(id))
        try? FileManager.default.removeItem(at: self.archive(id))
        try FileManager.default.moveItem(at: package, to: self.archive(id))
        try FileManager.default.moveItem(at: staging, to: files(id))
        // WebKit reads an extension's files from where it opened them, so it opens the final folder.
        let webExtension = try await open(id)
        try activate(webExtension, id: id)

        let entry = InstalledExtension(id: id, name: webExtension.displayName ?? id, version: webExtension.version ?? "", isEnabled: true)
        if let index = installed.firstIndex(where: { $0.id == id }) { installed[index] = entry } else { installed.append(entry) }
        if let saveError { throw saveError }
    }

    /// Removes the extension and, as Chrome does, the data it stored.
    func remove(id: String) async {
        try? await serially(id) { await self.delete(id) }
    }

    private func delete(_ id: String) async {
        unload(id)
        installed.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: files(id))
        try? FileManager.default.removeItem(at: archive(id))
        let types: Set<WKWebExtension.DataType> = [.local, .session, .synchronized]
        let records = await controller.dataRecords(ofTypes: types).filter { $0.uniqueIdentifier == id }
        if !records.isEmpty { await controller.removeData(ofTypes: types, from: records) }
    }

    private func serially(_ id: String, _ change: @escaping @MainActor () async throws -> Void) async throws {
        let previous = changes[id]
        let task = Task { @MainActor in
            await previous?.value
            try await change()
        }
        let done = Task { _ = try? await task.value }
        changes[id] = done
        defer { if changes[id] == done { changes[id] = nil } }
        try await task.value
    }

    func setEnabled(_ enabled: Bool, id: String) async {
        guard let index = installed.firstIndex(where: { $0.id == id }), installed[index].isEnabled != enabled else { return }
        installed[index].isEnabled = enabled
        if enabled {
            await load(installed[index])
        } else {
            unload(id)
        }
    }

    private func unload(_ id: String) {
        if let context = contexts.removeValue(forKey: id) { try? controller.unload(context) }
        nativeHosts.removeValue(forKey: id)?.forEach { $0.stop() }
        idlePorts.removeValue(forKey: id)?.forEach { $0.disconnect() }
        watchScreenLock()
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
        contexts[id]?.performAction(for: tab?.isEphemeral == true ? nil : tab)
    }

    // MARK: Tabs

    /// Private tabs are kept from extensions, as Chrome does incognito windows: in no tab list,
    /// sending no event, running no extension.
    var tabs: [Tab] {
        browser?.navigationOrder.filter { !$0.isEphemeral } ?? []
    }

    func didOpen(_ tab: Tab) {
        guard !tab.isEphemeral else { return }
        controller.didOpenTab(tab)
    }

    func didClose(_ tab: Tab) {
        guard !tab.isEphemeral else { return }
        if activeTab === tab { activeTab = nil }
        controller.didCloseTab(tab, windowIsClosing: false)
    }

    /// WebKit can't be told there is no active tab: the start page and a private tab leave the
    /// last normal tab active.
    func didSelect(_ tab: Tab?) {
        guard let tab, !tab.isEphemeral, tab !== activeTab else { return }
        let previous = activeTab
        activeTab = tab
        controller.didActivateTab(tab, previousActiveTab: previous)
    }

    /// Reports a tab whose place in `tabs` the change moved: WebKit sends no `onMoved` by itself.
    func moving(_ tab: Tab?, _ change: () -> Void) {
        let from = tab.flatMap { tabs.firstIndex(of: $0) }
        change()
        guard let tab, let from, let to = tabs.firstIndex(of: tab), to != from else { return }
        controller.didMoveTab(tab, from: from, in: window)
    }

    func appDidChangeActive(_ isActive: Bool) {
        guard isActive != isFocused else { return }
        isFocused = isActive
        controller.didFocusWindow(isActive ? window : nil)
    }

    func didChange(_ properties: WKWebExtension.TabChangedProperties, of tab: Tab) {
        guard !tab.isEphemeral else { return }
        controller.didChangeTabProperties(properties, for: tab)
    }
}

extension Extensions: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        isFocused ? window : nil
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext
    ) async throws -> (any WKWebExtensionTab)? {
        guard let browser else { return nil }
        let url = configuration.url
        guard Self.mayOpen(url) else { throw RefusedAddress() }
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
        if let anchor = popupAnchor, Self.isOnScreen(anchor) {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let content = Self.firstOnScreen([NSApp.keyWindow?.contentView, NSApp.mainWindow?.contentView, browser?.selectedTab?.webView.window?.contentView]) {
            popover.show(relativeTo: NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 44, width: 1, height: 1), of: content, preferredEdge: .minY)
        } else {
            // WebKit counts a popup it asked for as open until closed, refusing `action.openPopup()`
            // meanwhile. Throwing wouldn't help: WebKit resolves that call whatever this returns.
            action.closePopup()
        }
    }

    static func firstOnScreen(_ views: [NSView?]) -> NSView? {
        views.lazy.compactMap { $0 }.first(where: isOnScreen)
    }

    /// A popover shown from a view nobody can see still counts as open, so it must be on screen.
    static func isOnScreen(_ view: NSView) -> Bool {
        guard let window = view.window, window.isVisible, !window.isMiniaturized, window.screen != nil, let content = window.contentView,
              !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return false }
        var ancestor: NSView? = view
        while let current = ancestor {
            if current.alphaValue <= 0 { return false }
            ancestor = current.superview
        }
        return view.convert(view.bounds, to: nil).intersects(content.frame)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        actionsRevision &+= 1
    }

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

    /// `runtime.sendNativeMessage`: as in Chrome, a host runs for one message and its reply.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext
    ) async throws -> Any? {
        /// Made and read on the main actor.
        struct Reply: @unchecked Sendable { let value: Any? }
        return try await withCheckedThrowingContinuation { continuation in
            var waiting: CheckedContinuation<Reply, any Error>? = continuation
            let finish = { (result: Result<Reply, any Error>) in
                waiting?.resume(with: result)
                waiting = nil
            }
            var host: NativeMessaging.Host?
            do {
                host = try startHost(applicationIdentifier, for: extensionContext.uniqueIdentifier, onMessage: { reply in
                    finish(.success(Reply(value: reply)))
                    host?.stop()
                }, onExit: { finish(.failure($0)) })
                try host?.send(message)
            } catch {
                finish(.failure(error))
                host?.stop()
            }
        }.value
    }

    /// `runtime.connectNative`: the host runs as long as the port is open.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext
    ) async throws {
        if port.applicationIdentifier == Self.idleHost { return listenForIdle(on: port, for: extensionContext.uniqueIdentifier) }
        let host = try startHost(port.applicationIdentifier, for: extensionContext.uniqueIdentifier, onMessage: { message in
            port.sendMessage(message) { _ in }
        }, onExit: { error in
            if !port.isDisconnected { port.disconnect(throwing: error) }
        })
        port.messageHandler = { [weak host] message, error in
            guard error == nil, let message else { return }
            do { try host?.send(message) } catch { host?.stop() }
        }
        port.disconnectHandler = { [weak host] _ in host?.stop() }
    }

    /// `chrome.idle`: the port gets the state once connected, then each lock and unlock.
    private func listenForIdle(on port: WKWebExtension.MessagePort, for id: String) {
        idlePorts[id, default: []].append(port)
        port.disconnectHandler = { [weak self, weak port] _ in
            self?.idlePorts[id]?.removeAll { $0 === port }
            if self?.idlePorts[id]?.isEmpty == true { self?.idlePorts[id] = nil }
            self?.watchScreenLock()
        }
        // Once WebKit has connected the port, after this call: sent before, the state was lost.
        DispatchQueue.main.async { [weak self, weak port] in
            MainActor.assumeIsolated {
                guard let self, let port else { return }
                port.sendMessage(["state": self.isScreenLocked() ? "locked" : "active"]) { _ in }
            }
        }
        watchScreenLock()
    }

    private func watchScreenLock() {
        let center = DistributedNotificationCenter.default()
        if idlePorts.isEmpty {
            lockObservers.forEach { center.removeObserver($0) }
            lockObservers = []
            return
        }
        guard lockObservers.isEmpty else { return }
        lockObservers = [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)].map { name, locked in
            center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenLockChanged(locked: locked) }
            }
        }
    }

    func screenLockChanged(locked: Bool) {
        for port in idlePorts.values.joined() {
            port.sendMessage(["state": locked ? "locked" : "active"]) { _ in }
        }
    }

    /// The host holds the port its messages go to until it ends; the port only points back at it.
    private func startHost(
        _ name: String?,
        for id: String,
        onMessage: @escaping (Any) -> Void,
        onExit: @escaping (NativeMessaging.HostError) -> Void
    ) throws -> NativeMessaging.Host {
        let host = NativeMessaging.Host(executable: try NativeMessaging.executable(of: name ?? "", for: id, in: nativeHostFolders), extensionID: id)
        host.onMessage = onMessage
        host.onExit = { [weak self, unowned host] error in
            self?.nativeHosts[id]?.removeAll { $0 === host }
            onExit(error)
        }
        try host.start()
        nativeHosts[id, default: []].append(host)
        return host
    }

    private func confirm(_ context: WKWebExtensionContext, wants access: [String]) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow “\(context.webExtension.displayName ?? "this extension")” more access?"
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
        extensions.tabs
    }

    /// Only while it is in `tabs(for:)`: WebKit refuses the window's tabs otherwise.
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let tab = extensions.activeTab, extensions.tabs.contains(where: { $0 === tab }) else { return nil }
        return tab
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
