import AppKit
import CryptoKit
import Foundation
import Testing
import WebKit
@testable import Lithium

/// The list under sign-in fields, the save bar and Settings › Passwords. Every manager here keeps
/// its vault in a folder of the test's own, its settings in a suite of its own, and asks a fake
/// Touch ID: nothing reaches the user's Keychain, vault, settings or clipboard. Web views sit in
/// windows far off screen.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PasswordManagerTests {
    private static let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func account(_ username: String, _ password: String = "old-secret", on host: String = "example.com") -> Credential {
        Credential(host: host, username: username, password: password, created: date, modified: date)
    }

    /// Touch ID that says `grants` and notes each reason it was asked with.
    @MainActor private final class Prompts {
        var grants = true
        var asks: [String] = []

        func ask(_ reason: String) -> Bool {
            asks.append(reason)
            return grants
        }
    }

    @MainActor private final class Harness {
        let folder = URL.temporaryDirectory.appending(path: "passwords-\(UUID().uuidString)")
        let key = SymmetricKey(size: .bits256)
        let suite = "PasswordManagerTests.\(UUID().uuidString)"
        let prompts = Prompts()
        private(set) var manager: PasswordManager!
        var fileURL: URL { folder.appending(path: "passwords") }

        /// `saved` is on disk before the manager starts; `opening` is the key it gets, the vault's by default.
        init(saved: VaultContents? = nil, opening: SymmetricKey? = nil) async throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let (url, key, prompts) = (fileURL, key, prompts)
            if let saved { try await PasswordStore(fileURL: url) { _ in key }.save(saved) }
            let managerKey = opening ?? key
            manager = PasswordManager(store: { PasswordStore(fileURL: url) { _ in managerKey } },
                                      defaults: try #require(UserDefaults(suiteName: suite)), authenticate: { prompts.ask($0) })
        }

        func saved() async throws -> VaultContents {
            await manager.finishSaving()
            return try await PasswordStore(fileURL: fileURL) { [key] _ in key }.load()
        }

        func finish() {
            try? FileManager.default.removeItem(at: folder)
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    private func page(_ tabID: Tab.ID = UUID(), isPrivate: Bool = false) -> AutofillPage {
        AutofillPage(tabID: tabID, isPrivate: isPrivate, webView: nil)
    }

    private static let viewport = PageViewport(w: 0, h: 0, sx: 0, sy: 0, pw: 0, ph: 0, dpr: 1, vx: 0, vy: 0, vs: 1)

    private func focus(_ field: PasswordField, on host: String, _ page: AutofillPage, in manager: PasswordManager) async {
        await manager.handle(.focus(field, rect: CGRect(x: 40, y: 100, width: 200, height: 30), viewport: Self.viewport), host: host, on: page)
    }

    // MARK: Save bar

    @Test func aSentSignInAsksToSaveAndSaveWritesTheVault() async throws {
        let harness = try await Harness()
        defer { harness.finish() }
        let manager = harness.manager!
        await manager.handle(.submit(username: "alice", password: "s3cret-pass"), host: "accounts.example.com", on: page())
        let request = try #require(manager.pending.first)
        #expect(request.title == "Save password for example.com?")
        #expect(request.confirmTitle == "Save")
        #expect(!"\(request)".contains("s3cret-pass"), "a log line never shows the password")

        manager.answer(request, .save)
        #expect(manager.pending.isEmpty)
        let saved = try await harness.saved()
        #expect(saved.credentials.map { [$0.host, $0.username, $0.password] } == [["accounts.example.com", "alice", "s3cret-pass"]])

        await manager.handle(.submit(username: "alice", password: "s3cret-pass"), host: "www.example.com", on: page())
        #expect(manager.pending.isEmpty, "saved as it is: nothing to ask")
    }

    @Test func notNowKeepsNothingAndNeverRemembersTheSite() async throws {
        let harness = try await Harness()
        defer { harness.finish() }
        let manager = harness.manager!
        await manager.handle(.submit(username: "alice", password: "one"), host: "example.com", on: page())
        manager.answer(try #require(manager.pending.first), .notNow)
        #expect(manager.pending.isEmpty)
        await manager.finishSaving()
        #expect(!FileManager.default.fileExists(atPath: harness.fileURL.path), "Not now writes nothing")

        await manager.handle(.submit(username: "alice", password: "two"), host: "login.example.com", on: page())
        manager.answer(try #require(manager.pending.first), .never)
        #expect(try await harness.saved() == VaultContents(neverSaved: ["example.com"]))
        await manager.handle(.submit(username: "bob", password: "three"), host: "www.example.com", on: page())
        #expect(manager.pending.isEmpty, "never again on any of the site's hosts")
    }

    @Test func anotherPasswordForASavedAccountOffersAnUpdate() async throws {
        let saved = Self.account("alice")
        let harness = try await Harness(saved: VaultContents(credentials: [saved]))
        defer { harness.finish() }
        let manager = harness.manager!
        await manager.handle(.submit(username: "alice", password: "new-secret"), host: "example.com", on: page())
        let request = try #require(manager.pending.first)
        #expect(request.offer == .update(saved.id))
        #expect(request.title == "Update password for alice?")
        #expect(request.confirmTitle == "Update")
        manager.answer(request, .save)
        let credentials = try await harness.saved().credentials
        #expect(credentials.map { [$0.id.uuidString, $0.username, $0.password] } == [[saved.id.uuidString, "alice", "new-secret"]])
    }

    @Test func privateTabsNeverOfferToSave() async throws {
        let harness = try await Harness()
        defer { harness.finish() }
        await harness.manager.handle(.submit(username: "alice", password: "s3cret"), host: "example.com", on: page(isPrivate: true))
        #expect(harness.manager.pending.isEmpty)
    }

    /// One bar per tab: a later sign-in replaces it, the same one twice (a click, then the submit it
    /// causes) asks once. It stays for the page the sign-in leads to, and goes with another site.
    @Test func theBarFollowsItsTabAndSite() async throws {
        let harness = try await Harness()
        defer { harness.finish() }
        let manager = harness.manager!
        let tab = page()
        await manager.handle(.submit(username: "alice", password: "one"), host: "example.com", on: tab)
        await manager.handle(.submit(username: "bob", password: "two"), host: "example.com", on: tab)
        await manager.handle(.submit(username: "bob", password: "two"), host: "example.com", on: tab)
        await manager.handle(.submit(username: "carol", password: "three"), host: "example.org", on: page())
        #expect(manager.pending.map(\.username) == ["bob", "carol"])

        manager.pageChanged(tabID: tab.tabID, host: "www.example.com")
        #expect(manager.pending.map(\.username) == ["bob", "carol"])
        manager.pageChanged(tabID: tab.tabID, host: "news.example.net")
        #expect(manager.pending.map(\.username) == ["carol"])
        manager.cancel(tabID: manager.pending[0].tabID)
        #expect(manager.pending.isEmpty)
    }

    // MARK: List under a field

    @Test func theListShowsOnlyTheSitesAccountsItsHostFirst() async throws {
        let (bob, alice) = (Self.account("bob", on: "accounts.example.com"), Self.account("alice", on: "www.example.com"))
        let others = [Self.account("carol", on: "example.org"), Self.account("dave", on: "example.com.evil.net")]
        let harness = try await Harness(saved: VaultContents(credentials: [bob] + others + [alice]))
        defer { harness.finish() }
        let manager = harness.manager!
        let tab = page()

        await focus(.username, on: "www.example.com", tab, in: manager)
        let dropdown = try #require(manager.dropdown)
        #expect(dropdown.rows == [.account(alice.id, username: "alice", host: "www.example.com"), .account(bob.id, username: "bob", host: "accounts.example.com")])
        #expect(dropdown.rect == CGRect(x: 40, y: 100, width: 200, height: 30))
        #expect(dropdown.tabID == tab.tabID && dropdown.field == .username)

        await focus(.newPassword, on: "www.example.com", tab, in: manager)
        #expect(manager.dropdown?.rows == [.strongPassword])
        await manager.handle(.blur, host: "www.example.com", on: tab)
        #expect(manager.dropdown == nil)
        await focus(.password, on: "example.net", tab, in: manager)
        #expect(manager.dropdown == nil, "no account for the site: no list")
    }

    /// A strong password nobody would save would leave the new account with a password nobody knows.
    @Test func noStrongPasswordWhereItWouldntBeSaved() async throws {
        let harness = try await Harness(saved: VaultContents(neverSaved: ["example.org"]))
        defer { harness.finish() }
        let manager = harness.manager!

        await focus(.newPassword, on: "www.example.com", page(isPrivate: true), in: manager)
        #expect(manager.dropdown == nil, "a private tab")
        await focus(.newPassword, on: "accounts.example.org", page(), in: manager)
        #expect(manager.dropdown == nil, "a site never saved")
        await focus(.newPassword, on: "www.example.com", page(), in: manager)
        #expect(manager.dropdown?.rows == [.strongPassword])
    }

    /// Under the field, over it near the page's bottom, never past the page's sides.
    @Test func theListStaysInsideThePage() {
        let rows: [PasswordDropdown.Row] = [.strongPassword, .strongPassword]
        let page = CGSize(width: 800, height: 600)
        func frame(_ rect: CGRect) -> CGRect {
            PasswordDropdown(tabID: UUID(), host: "example.com", field: .password, rect: rect, rows: rows).frame(in: page)
        }
        let height = 2 * PasswordDropdown.rowHeight + 2 * PasswordDropdown.padding
        #expect(frame(CGRect(x: 100, y: 100, width: 300, height: 30)) == CGRect(x: 100, y: 134, width: 300, height: height))
        #expect(frame(CGRect(x: 100, y: 560, width: 300, height: 30)) == CGRect(x: 100, y: 556 - height, width: 300, height: height))
        #expect(frame(CGRect(x: 700, y: 100, width: 120, height: 30)).maxX == 792)
    }

    /// Showing the list never asks; filling asks as the setting says. A row not in the list fills nothing.
    @Test(arguments: [(UnlockPolicy.oncePerLaunch, 1), (.everyTime, 2), (.never, 0)])
    func fillingAsksAsTheUnlockPolicySays(policy: UnlockPolicy, asks: Int) async throws {
        let alice = Self.account("alice")
        let harness = try await Harness(saved: VaultContents(credentials: [alice]))
        defer { harness.finish() }
        let manager = harness.manager!
        manager.unlockPolicy = policy
        let tab = page()
        #expect(await !manager.choose(.account(alice.id, username: "alice", host: "example.com")), "no list shown")
        for _ in 0..<2 {
            await focus(.password, on: "example.com", tab, in: manager)
            #expect(await !manager.choose(.account(UUID(), username: "mallory", host: "example.com")))
            await focus(.password, on: "example.com", tab, in: manager)
            _ = await manager.choose(try #require(manager.dropdown?.rows.first))
            #expect(manager.dropdown == nil)
        }
        #expect(harness.prompts.asks.count == asks)
        #expect(harness.prompts.asks.allSatisfy { $0 == "fill your password for example.com" })
    }

    // MARK: Messages

    @Test func onlyThePagesOwnMainFrameIsHeard() {
        let page = URL(string: "https://www.example.com/login")
        let focus: [String: Any] = ["type": "focus", "kind": "password", "rect": ["x": 10, "y": 20.5, "w": 200, "h": 30],
                                    "viewport": ["x": 0, "y": 4, "scale": 1.5]]
        func parse(_ body: Any, main: Bool = true, scheme: String = "https", host: String = "www.example.com", page: URL? = page) -> AutofillMessage? {
            AutofillMessage(body, isMainFrame: main, scheme: scheme, host: host, page: page)
        }
        let viewport = PageViewport(w: 0, h: 0, sx: 0, sy: 0, pw: 0, ph: 0, dpr: 1, vx: 0, vy: 4, vs: 1.5)
        #expect(parse(focus) == .focus(.password, rect: CGRect(x: 10, y: 20.5, width: 200, height: 30), viewport: viewport))
        #expect(parse(["type": "blur"]) == .blur)
        #expect(parse(["type": "submit", "username": "alice", "password": "s3cret"]) == .submit(username: "alice", password: "s3cret"))
        #expect(!"\(parse(["type": "submit", "username": "alice", "password": "s3cret"])!)".contains("s3cret"))

        #expect(parse(focus, main: false) == nil, "a frame")
        #expect(parse(focus, host: "evil.example.net") == nil, "another origin")
        #expect(parse(focus, host: "example.com") == nil, "another host of the site")
        #expect(parse(focus, scheme: "http") == nil, "another scheme than the page's")
        #expect(parse(focus, scheme: "http", page: URL(string: "http://www.example.com/")) == nil, "http off this Mac")
        #expect(parse(focus, scheme: "http", host: "localhost", page: URL(string: "http://localhost:8080/")) != nil)
        #expect(parse(focus, scheme: "http", host: "127.0.0.1", page: URL(string: "http://127.0.0.1/")) != nil)
        #expect(parse(focus, page: nil) == nil)

        var malformed: [Any] = ["focus", ["type": "fill", "password": "x"], ["type": "submit", "username": "alice"],
                                ["type": "submit", "username": "alice", "password": ""], ["type": "submit", "username": 4, "password": "x"],
                                ["type": "submit", "username": "", "password": String(repeating: "x", count: AutofillMessage.maxLength + 1)]]
        for (key, value) in [("kind", "credit-card"), ("kind", "hidden")] as [(String, Any)] { malformed.append(focus.merging([key: value]) { $1 }) }
        for rect in [["x": 10, "y": 20, "w": 0, "h": 30], ["x": "10", "y": 20, "w": 200, "h": 30], ["x": Double.nan, "y": 20, "w": 200, "h": 30],
                     ["x": true, "y": 20, "w": 200, "h": 30], ["x": 10, "y": 20, "w": 200]] as [[String: Any]] {
            malformed.append(focus.merging(["rect": rect]) { $1 })
        }
        malformed.append(focus.merging(["viewport": ["x": 0, "y": 0, "scale": 0]]) { $1 })
        for body in malformed { #expect(parse(body) == nil, "\(type(of: body))") }
    }

    // MARK: Settings

    /// The page's state holds no password; Show and Copy each ask unless the setting says never,
    /// and Copy marks the password concealed for clipboard managers.
    @Test func settingsAskBeforeShowingOrCopying() async throws {
        let alice = Self.account("alice", "pa55-word", on: "accounts.example.com")
        let harness = try await Harness(saved: VaultContents(credentials: [alice], neverSaved: ["example.org"]))
        defer { harness.finish() }
        let manager = harness.manager!
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        manager.pasteboard = { board }

        let state = try #require(await manager.answerSettings("passwords", nil, window: nil).0 as? [String: Any])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        #expect(!text.contains("pa55-word"))
        #expect(state["neverSaved"] as? [String] == ["example.org"])
        #expect((state["accounts"] as? [[String: String]])?.first?["username"] == "alice")
        #expect(harness.prompts.asks.isEmpty)

        harness.prompts.grants = false
        #expect(await manager.answerSettings("revealPassword", alice.id.uuidString, window: nil).1 == "Not allowed")
        #expect(await manager.answerSettings("copyPassword", alice.id.uuidString, window: nil).1 == "Not allowed")
        #expect(board.string(forType: .string) == nil)

        harness.prompts.grants = true
        let shown = await manager.answerSettings("revealPassword", alice.id.uuidString, window: nil).0 as? [String: String]
        #expect(shown == ["password": "pa55-word"])
        _ = await manager.answerSettings("copyPassword", alice.id.uuidString, window: nil)
        #expect(board.string(forType: .string) == "pa55-word")
        #expect(board.types?.contains(PasswordManager.concealedType) == true)
        #expect(harness.prompts.asks == ["show a password", "copy a password", "show a password", "copy a password"])

        _ = await manager.answerSettings("setPasswordUnlock", "never", window: nil)
        #expect(await manager.answerSettings("revealPassword", alice.id.uuidString, window: nil).0 as? [String: String] == ["password": "pa55-word"])
        #expect(harness.prompts.asks.count == 5, "never asks, once it is set")
    }

    /// Asking less often asks first, so nobody at the Mac can turn Touch ID off and show every password.
    @Test func askingLessOftenAsksFirst() async throws {
        let harness = try await Harness()
        defer { harness.finish() }
        let manager = harness.manager!
        manager.unlockPolicy = .everyTime

        harness.prompts.grants = false
        #expect(await manager.answerSettings("setPasswordUnlock", "never", window: nil).1 == "Not allowed")
        #expect(await manager.answerSettings("setPasswordUnlock", "oncePerLaunch", window: nil).1 == "Not allowed")
        #expect(manager.unlockPolicy == .everyTime)
        #expect(harness.prompts.asks == ["ask less often for your passwords", "ask less often for your passwords"])

        harness.prompts.grants = true
        _ = await manager.answerSettings("setPasswordUnlock", "never", window: nil)
        #expect(manager.unlockPolicy == .never)
        harness.prompts.grants = false
        let state = await manager.answerSettings("setPasswordUnlock", "everyTime", window: nil).0 as? [String: Any]
        #expect(state?["unlock"] as? String == "everyTime", "asking more often asks nothing")
        #expect(harness.prompts.asks.count == 3)
    }

    @Test func settingsEditDeleteAndTurnOff() async throws {
        let (alice, bob) = (Self.account("alice"), Self.account("bob"))
        let harness = try await Harness(saved: VaultContents(credentials: [alice, bob], neverSaved: ["example.org"]))
        defer { harness.finish() }
        let manager = harness.manager!

        _ = await manager.answerSettings("savePasswordEdit", ["id": alice.id.uuidString, "username": "alice@example.com", "password": ""], window: nil)
        #expect(harness.prompts.asks.isEmpty, "a new username alone asks nothing")
        _ = await manager.answerSettings("savePasswordEdit", ["id": bob.id.uuidString, "username": "bob", "password": "new-secret"], window: nil)
        #expect(harness.prompts.asks == ["change a password"])
        _ = await manager.answerSettings("removeNeverSaved", "example.org", window: nil)
        var saved = try await harness.saved()
        #expect(saved.credentials.map { [$0.username, $0.password] } == [["alice@example.com", "old-secret"], ["bob", "new-secret"]])
        #expect(saved.neverSaved.isEmpty)

        _ = await manager.answerSettings("deletePassword", alice.id.uuidString, window: nil)
        saved = try await harness.saved()
        #expect(saved.credentials.map(\.username) == ["bob"])

        let state = await manager.answerSettings("setPasswordOffers", false, window: nil).0 as? [String: Any]
        #expect(state?["offers"] as? Bool == false)
        let controller = WKUserContentController()
        manager.install(on: controller, for: URL(string: "https://example.com/")!)
        #expect(controller.userScripts.isEmpty, "off: no script in pages")
        _ = await manager.answerSettings("setPasswordOffers", true, window: nil)
        manager.install(on: controller, for: URL(string: "https://example.com/")!)
        #expect(controller.userScripts.count == 1)
        let settings = WKUserContentController()
        manager.install(on: settings, for: URL(string: "lithium://settings")!)
        #expect(settings.userScripts.isEmpty, "Lithium's own pages get none")
    }

    /// A vault this launch can't open says so on the page, offers nothing and is never written over.
    @Test func aVaultThatWontOpenIsLeftAsItIs() async throws {
        let harness = try await Harness(saved: VaultContents(credentials: [Self.account("alice")]), opening: SymmetricKey(size: .bits256))
        defer { harness.finish() }
        let manager = harness.manager!
        let before = try Data(contentsOf: harness.fileURL)
        await manager.handle(.submit(username: "bob", password: "s3cret"), host: "example.com", on: page())
        #expect(manager.pending.isEmpty)
        let state = await manager.answerSettings("deletePassword", UUID().uuidString, window: nil).0 as? [String: Any]
        #expect(state?["error"] as? String == PasswordManager.message(for: .damaged))
        #expect((state?["accounts"] as? [Any])?.isEmpty == true)
        await manager.finishSaving()
        #expect(try Data(contentsOf: harness.fileURL) == before)
    }

    /// A long vault shows its first five accounts until Show all, every match while searching, and
    /// is collapsed again, with Never saved, whenever the section is opened.
    @Test func theSavedListShowsFiveUntilShowAll() async throws {
        let configuration = WKWebViewConfiguration()
        InternalSchemeHandler.shared.install(on: configuration)
        configuration.userContentController.addScriptMessageHandler(SampleBridge(), contentWorld: .page, name: InternalBridge.name)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 700), configuration: configuration)
        let load = PageLoad()
        webView.navigationDelegate = load
        webView.load(URLRequest(url: URL(string: "lithium://settings#passwords")!))
        try await load.wait()
        let seen = try await webView.callAsyncJavaScript("""
            const until = async (test) => { for (let i = 0; i < 100 && !test(); i++) await new Promise((r) => setTimeout(r, 50)); return test(); };
            const rows = () => document.querySelectorAll('#password-list .account').length;
            const seen = [];
            const look = () => seen.push([rows(), $('#password-more').hidden ? '-' : $('#password-more').textContent,
              $('#never-saved-section summary').textContent, $('#never-saved-section').open ? 'open' : 'closed'].join(' | '));
            const search = (text) => { $('#password-search').value = text; $('#password-search').dispatchEvent(new Event('input')); };
            await until(() => rows() > 0);
            look();
            $('#password-more').click();
            look();
            search('example');
            look();
            search('');
            look();
            $('#never-saved-section').open = true;
            location.hash = 'max';
            await until(() => $('#max').classList.contains('active'));
            location.hash = 'passwords';
            await until(() => $('#passwords').classList.contains('active') && rows() === 5);
            look();
            return seen;
            """, contentWorld: .page) as? [String]
        #expect(seen == [
            "5 | Show all (8) | Never saved (2) | closed",
            "8 | Show less | Never saved (2) | closed",
            "7 | - | Never saved (2) | closed",
            "8 | Show less | Never saved (2) | closed",
            "5 | Show all (8) | Never saved (2) | closed",
        ])
    }

    // MARK: In a page

    private static let login = """
        <!doctype html><title>Sign in</title>
        <form id="login" onsubmit="event.preventDefault()">
          <input id="user" autocomplete="username"><input id="pass" type="password">
          <input id="trap" type="password" style="display: none"><button>Sign in</button>
        </form>
        """

    private static let signUp = """
        <!doctype html><title>Sign up</title>
        <form id="signup" onsubmit="event.preventDefault()">
          <input id="user" type="email"><input id="new" type="password" autocomplete="new-password"><input id="again" type="password">
          <button>Create account</button>
        </form>
        """

    @MainActor private struct LoadedPage {
        let webView: WKWebView
        let window: NSWindow
        let load: PageLoad

        func run(_ script: String) async throws -> Any? {
            try await webView.callAsyncJavaScript(script, contentWorld: .page)
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    /// `html` at https://example.com/login, with the manager's script as a tab would get it.
    private func open(_ html: String, in harness: Harness, isPrivate: Bool = false) async throws -> LoadedPage {
        let url = URL(string: "https://example.com/login")!
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        harness.manager.install(on: configuration.userContentController, for: url)
        let tabID = UUID()
        harness.manager.page = { AutofillPage(tabID: tabID, isPrivate: isPrivate, webView: $0) }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        window.makeFirstResponder(webView)
        let load = PageLoad()
        webView.navigationDelegate = load
        webView.loadHTMLString(html, baseURL: url)
        try await load.wait()
        return LoadedPage(webView: webView, window: window, load: load)
    }

    private func waitUntil(_ seconds: Double = 10, _ condition: () async throws -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Focus lists the site's account under the field; a click on it fills the visible fields only,
    /// once Touch ID agrees; a changed password sent offers an update.
    @Test func aRealPageListsFillsAndOffersAnUpdate() async throws {
        let alice = Self.account("alice", "s3cret")
        let harness = try await Harness(saved: VaultContents(credentials: [alice]))
        defer { harness.finish() }
        let manager = harness.manager!
        manager.unlockPolicy = .everyTime
        let page = try await open(Self.login, in: harness)
        defer { page.close() }
        #expect(try await page.run("return typeof lithiumFill") as? String == "undefined", "the page can't reach the fill")

        _ = try await page.run("document.getElementById('user').focus()")
        #expect(await waitUntil { manager.dropdown != nil })
        let dropdown = try #require(manager.dropdown)
        #expect(dropdown.field == .username && dropdown.host == "example.com")
        #expect(dropdown.rows == [.account(alice.id, username: "alice", host: "example.com")])
        let field = try #require(try await page.run("const r = document.getElementById('user').getBoundingClientRect(); return [r.x, r.y, r.width, r.height]") as? [Double])
        #expect(dropdown.rect == CGRect(x: field[0], y: field[1], width: field[2], height: field[3]))

        harness.prompts.grants = false
        #expect(await !manager.choose(dropdown.rows[0]))
        #expect(try await page.run("return document.getElementById('pass').value") as? String == "", "no Touch ID, no fill")

        harness.prompts.grants = true
        _ = try await page.run("document.getElementById('pass').focus()")
        #expect(await waitUntil { manager.dropdown?.field == .password })
        #expect(await manager.choose(try #require(manager.dropdown?.rows.first)))
        let values = try await page.run("return ['user', 'pass', 'trap'].map((id) => document.getElementById(id).value)") as? [String]
        #expect(values == ["alice", "s3cret", ""], "the hidden field stays empty")
        #expect(manager.dropdown == nil)

        _ = try await page.run("document.getElementById('pass').value = 'n3w-secret'; document.getElementById('login').requestSubmit()")
        #expect(await waitUntil { !manager.pending.isEmpty })
        let request = try #require(manager.pending.first)
        #expect(request.offer == .update(alice.id) && request.username == "alice" && request.password == "n3w-secret")
    }

    /// A sign-in sent by script reports on its button's click, but a show-password eye beside the
    /// field isn't one: the bar would ask with a half-typed password.
    @Test func aShowPasswordButtonIsntASignIn() async throws {
        let harness = try await Harness()
        defer { harness.finish() }
        let manager = harness.manager!
        let page = try await open("""
            <!doctype html><title>Sign in</title>
            <div><input id="user" autocomplete="username">
              <span><input id="pass" type="password"><button id="eye" type="button">Show</button></span>
              <button id="go" type="button">Sign in</button></div>
            """, in: harness)
        defer { page.close() }
        let input = try NativeInput(webView: page.webView, sends: [.pointer, .buttons], check: {}, onPointer: { _ in })
        func click(_ id: String) async throws {
            let r = try #require(try await page.run("const r = document.getElementById('\(id)').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]") as? [Double])
            try input.click(at: CGPoint(x: r[0], y: r[1]), button: .left, count: 1, modifiers: [])
        }

        try await click("pass")
        _ = try await page.run("document.getElementById('user').value = 'alice'; document.getElementById('pass').value = 's3c'")
        try await click("eye")
        try await Task.sleep(for: .milliseconds(300))
        #expect(manager.pending.isEmpty)

        _ = try await page.run("document.getElementById('pass').value = 's3cret'")
        try await click("go")
        #expect(await waitUntil { !manager.pending.isEmpty })
        #expect(manager.pending.first?.password == "s3cret")
    }

    /// "Use a strong password" fills both new password fields; sent, it is saved without asking.
    /// A private tab saves nothing, so it isn't offered there.
    @Test(arguments: [false, true])
    func aStrongPasswordIsFilledAndSavedOnSubmit(isPrivate: Bool) async throws {
        let harness = try await Harness()
        defer { harness.finish() }
        let manager = harness.manager!
        let page = try await open(Self.signUp, in: harness, isPrivate: isPrivate)
        defer { page.close() }

        _ = try await page.run("document.getElementById('new').focus()")
        if isPrivate {
            try await Task.sleep(for: .milliseconds(300))
            #expect(manager.dropdown == nil)
            #expect(await !manager.choose(.strongPassword))
            #expect(try await page.run("return document.getElementById('new').value") as? String == "")
            return
        }
        #expect(await waitUntil { manager.dropdown != nil })
        #expect(manager.dropdown?.rows == [.strongPassword])
        #expect(await manager.choose(.strongPassword))
        #expect(harness.prompts.asks.isEmpty)
        let values = try #require(try await page.run("return ['new', 'again'].map((id) => document.getElementById(id).value)") as? [String])
        #expect(values[0].count == 20 && values[0] == values[1])

        _ = try await page.run("document.getElementById('user').value = 'alice@example.com'; document.getElementById('signup').requestSubmit()")
        #expect(await waitUntil { (try? await harness.saved().credentials.isEmpty) == false })
        #expect(try await harness.saved().credentials.map { [$0.host, $0.username, $0.password] } == [["example.com", "alice@example.com", values[0]]])
        #expect(manager.pending.isEmpty, "saved without asking")
    }
}
