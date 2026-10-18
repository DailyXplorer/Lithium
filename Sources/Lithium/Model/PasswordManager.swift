import AppKit
import LocalAuthentication
import Observation
import WebKit

/// The tab a password message came from, as far as passwords care.
struct AutofillPage {
    let tabID: Tab.ID
    let isPrivate: Bool
    weak var webView: WKWebView?
}

/// Lithium's own passwords: the list under a sign-in field, the "Save password?" bar, and the vault
/// behind both. Made on first use; the vault is read only once a sign-in field is focused or
/// Settings › Passwords opens, and Touch ID asked only when a password is filled or shown.
@MainActor
@Observable
final class PasswordManager {
    static let world = WKContentWorld.world(name: "LithiumPasswords")
    static let name = "lithiumPasswords"

    /// Main frame only: a frame from another site never sees a field filled, nor reports one.
    static let script = WKUserScript(
        source: Resources.bundle.url(forResource: "autofill", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "",
        injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world
    )

    private(set) var dropdown: PasswordDropdown?
    private(set) var pending: [PasswordSaveRequest] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeStore: () -> PasswordStore
    @ObservationIgnored private lazy var store = makeStore()
    @ObservationIgnored private(set) lazy var lock = VaultLock(policy: { [weak self] in self?.unlockPolicy ?? .oncePerLaunch }, authenticate: authenticate)
    @ObservationIgnored private let authenticate: @MainActor (String) async -> Bool
    /// The tab behind a web view that posted; tests give their own.
    @ObservationIgnored var page: @MainActor (WKWebView) -> AutofillPage? = { webView in
        (webView as? PageWebView)?.tab.map { AutofillPage(tabID: $0.id, isPrivate: $0.isEphemeral, webView: webView) }
    }
    /// Where Copy puts a password; tests give their own.
    @ObservationIgnored var pasteboard: () -> NSPasteboard = { .general }

    /// Read once a launch. A vault this launch can't open stays so, and is never written over.
    @ObservationIgnored private var vault: Result<VaultContents, VaultError>?
    @ObservationIgnored private var loading: Task<Result<VaultContents, VaultError>, Never>?
    /// The last write; each waits for the one before, so an older copy never lands last.
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private(set) var saveError: VaultError?
    /// The strong password filled in each tab, saved without asking when its site's form is sent.
    @ObservationIgnored private var generated: [Tab.ID: (site: String, password: String)] = [:]
    @ObservationIgnored private var dropdownPage: AutofillPage?
    @ObservationIgnored private var focusCount = 0
    @ObservationIgnored private lazy var channel = AutofillChannel(manager: self)
    @ObservationIgnored private let channels = NSHashTable<WKUserContentController>.weakObjects()

    init(
        store: @escaping () -> PasswordStore = { .app },
        defaults: UserDefaults = .standard,
        authenticate: @escaping @MainActor (String) async -> Bool = PasswordManager.askDeviceOwner
    ) {
        makeStore = store
        self.defaults = defaults
        self.authenticate = authenticate
    }

    /// Touch ID, or the Mac's password where there is none. A context each time, so one success
    /// never lets a later ask through.
    static func askDeviceOwner(_ reason: String) async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    // MARK: Preferences

    var offersPasswords: Bool {
        get { defaults.object(forKey: Preference.passwordOffers) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Preference.passwordOffers)
            if !newValue {
                hideDropdown()
                pending.removeAll()
                generated.removeAll()
            }
        }
    }

    var unlockPolicy: UnlockPolicy {
        get { defaults.string(forKey: Preference.passwordUnlock).flatMap(UnlockPolicy.init(rawValue:)) ?? .oncePerLaunch }
        set { defaults.set(newValue.rawValue, forKey: Preference.passwordUnlock) }
    }

    // MARK: Vault

    func contents() async -> Result<VaultContents, VaultError> {
        if let vault { return vault }
        if let loading {
            let result = await loading.value
            return vault ?? result
        }
        let store = store
        let task = Task { () -> Result<VaultContents, VaultError> in
            do throws(VaultError) {
                return .success(try await store.load())
            } catch {
                return .failure(error)
            }
        }
        loading = task
        let result = await task.value
        loading = nil
        // A change made by another caller that got the vault first stays.
        if vault == nil { vault = result }
        return vault ?? result
    }

    /// Changes the loaded vault and writes it; nothing when it isn't loaded or couldn't be.
    @discardableResult
    func change<T>(_ body: (inout VaultContents) -> T) -> T? {
        guard case .success(var contents) = vault else { return nil }
        let result = body(&contents)
        vault = .success(contents)
        let previous = saving, store = store
        saving = Task { [weak self] in
            await previous?.value
            do throws(VaultError) {
                try await store.save(contents)
                self?.saveError = nil
            } catch {
                self?.saveError = error
            }
        }
        return result
    }

    /// Once every write asked for is on disk.
    func finishSaving() async {
        await saving?.value
    }

    // MARK: Pages

    /// Only on web pages, while offering is on; turned off, pages loaded next get no script.
    func install(on controller: WKUserContentController, for url: URL) {
        guard offersPasswords, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        if !channels.contains(controller) {
            controller.add(channel, contentWorld: Self.world, name: Self.name)
            channels.add(controller)
        }
        controller.addUserScript(Self.script)
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard offersPasswords, let webView = message.webView, let page = page(webView), let host = webView.url?.host()?.lowercased(),
              let event = AutofillMessage(message.body, isMainFrame: message.frameInfo.isMainFrame, scheme: message.frameInfo.securityOrigin.protocol,
                                          host: message.frameInfo.securityOrigin.host, page: webView.url) else { return }
        Task { await handle(event, host: host, on: page) }
    }

    func handle(_ event: AutofillMessage, host: String, on page: AutofillPage) async {
        switch event {
        case let .focus(field, rect, viewport):
            focusCount += 1
            let count = focusCount
            guard case let .success(vault) = await contents(), count == focusCount else { return }
            let rows = PasswordDropdown.rows(for: field, host: host, isPrivate: page.isPrivate, in: vault)
            guard !rows.isEmpty else { return hideDropdown(in: page.tabID) }
            let zoom = page.webView?.pageZoom ?? 1
            dropdownPage = page
            dropdown = PasswordDropdown(tabID: page.tabID, host: host, field: field,
                                        rect: AgentScreenshot.viewRect(rect, viewport: viewport, zoom: zoom), rows: rows)
        case .blur:
            focusCount += 1
            hideDropdown(in: page.tabID)
        case let .submit(username, password):
            hideDropdown(in: page.tabID)
            await submitted(username: username, password: password, host: host, on: page)
        }
    }

    private func submitted(username: String, password: String, host: String, on page: AutofillPage) async {
        guard case let .success(vault) = await contents(),
              let offer = SaveDecision.offer(host: host, username: username, password: password, isPrivate: page.isPrivate, in: vault) else { return }
        if let strong = generated[page.tabID], strong.password == password, strong.site == SiteInfo.registrable(host) {
            generated[page.tabID] = nil
            change { $0.store(offer, host: host, username: username, password: password, now: .now) }
            return
        }
        // A click and the submit it causes both report the same sign-in.
        guard !pending.contains(where: { $0.tabID == page.tabID && $0.host == host && $0.username == username && $0.password == password }) else { return }
        pending.removeAll { $0.tabID == page.tabID }
        pending.append(PasswordSaveRequest(tabID: page.tabID, host: host, username: username, password: password, offer: offer))
    }

    /// From a click on a row of the list only. False when nothing was filled: the user said no to
    /// Touch ID, the tab left the site, or the field is gone or hidden.
    @discardableResult
    func choose(_ row: PasswordDropdown.Row) async -> Bool {
        guard let dropdown, dropdown.rows.contains(row), let page = dropdownPage else { return false }
        self.dropdown = nil
        let filling: (username: String, password: String, generated: Bool)
        switch row {
        case let .account(id, _, _):
            guard case let .success(contents) = vault, let credential = contents.credentials.first(where: { $0.id == id }),
                  await lock.authorize(.fill, reason: "fill your password for \(dropdown.host)") else { return false }
            filling = (credential.username, credential.password, false)
        case .strongPassword:
            filling = ("", PasswordGenerator.strong(), true)
        }
        guard let webView = page.webView, webView.url?.host()?.lowercased() == dropdown.host else { return false }
        let filled = (try? await webView.callAsyncJavaScript(
            "return lithiumFill(host, username, password, generated)",
            arguments: ["host": dropdown.host, "username": filling.username, "password": filling.password, "generated": filling.generated],
            in: nil, contentWorld: Self.world
        )) as? Bool == true
        if filled, filling.generated { generated[page.tabID] = (SiteInfo.registrable(dropdown.host), filling.password) }
        return filled
    }

    func hideDropdown(in tabID: Tab.ID? = nil) {
        guard let shown = dropdown, tabID == nil || shown.tabID == tabID else { return }
        dropdown = nil
        dropdownPage = nil
    }

    // MARK: Save requests

    func answer(_ request: PasswordSaveRequest, _ answer: PasswordSaveAnswer) {
        guard pending.contains(request) else { return }
        pending.removeAll { $0.id == request.id }
        switch answer {
        case .save: change { $0.store(request.offer, host: request.host, username: request.username, password: request.password, now: .now) }
        case .notNow: break
        case .never: change { $0.neverSave(request.host) }
        }
    }

    /// A closed or sleeping tab's questions go with it.
    func cancel(tabID: Tab.ID) {
        if pending.contains(where: { $0.tabID == tabID }) { pending.removeAll { $0.tabID == tabID } }
        generated[tabID] = nil
        hideDropdown(in: tabID)
    }

    /// A new page in the tab. The bar stays for the page a sign-in leads to on the same site.
    func pageChanged(tabID: Tab.ID, host: String?) {
        hideDropdown(in: tabID)
        let site = SiteInfo.registrable(host ?? "")
        if pending.contains(where: { $0.tabID == tabID && $0.site != site }) { pending.removeAll { $0.tabID == tabID && $0.site != site } }
    }
}

/// The script's line to the manager, in the passwords' world only. Held weakly: the controller
/// keeps its handlers for the web view's life.
@MainActor
private final class AutofillChannel: NSObject, WKScriptMessageHandler {
    weak var manager: PasswordManager?

    init(manager: PasswordManager) {
        self.manager = manager
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        manager?.receive(message)
    }
}
