import Foundation
import Security
import Testing
@testable import Lithium

/// Every Keychain here is a fake: nothing reaches the user's login Keychain.
@Suite struct KeychainTests {
    private static let installed = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    @Test func onlyTheInstalledSignedAppMayUseTheKeychain() {
        #expect(Keychain.allows(isDebug: false, runsTests: false, environment: [:], bundle: Self.installed, signed: true))
        #expect(!Keychain.allows(isDebug: true, runsTests: false, environment: [:], bundle: Self.installed, signed: true))
        #expect(!Keychain.allows(isDebug: false, runsTests: true, environment: [:], bundle: Self.installed, signed: true))
        #expect(!Keychain.allows(isDebug: false, runsTests: false, environment: ["CFFIXED_USER_HOME": "/tmp/home"], bundle: Self.installed, signed: true))
        #expect(!Keychain.allows(isDebug: false, runsTests: false, environment: [:],
                                 bundle: Self.installed.appending(path: "Contents/MacOS/Calculator"), signed: true), "a bare binary")
        #expect(!Keychain.allows(isDebug: false, runsTests: false, environment: [:], bundle: Self.installed, signed: false), "ad-hoc signed")
    }

    @Test func anAppSignedWithACertificateHasAnIdentity() {
        #expect(Keychain.hasSigningIdentity(Self.installed))
        #expect(!Keychain.hasSigningIdentity(URL(fileURLWithPath: "/nonexistent/Lithium.app")))
    }

    /// The same binary, Apple-signed and then re-signed ad hoc, as the linker signs a debug build.
    @Test func anAdHocSignatureHasNoIdentity() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "keychain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: url)
        #expect(Keychain.hasSigningIdentity(url))
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", url.path]
        try codesign.run()
        codesign.waitUntilExit()
        try #require(codesign.terminationStatus == 0)
        #expect(!Keychain.hasSigningIdentity(url))
    }

    /// Nor the installed app's sign-in file, which their own key would replace.
    @MainActor @Test func testsNeverUseTheKeychain() {
        #expect(!Keychain.isAllowed)
        #expect(SessionCookies.fileURL.lastPathComponent == "session-cookies-unkeyed")
    }

    /// WebKit asks for the key only a delegate that responds: the installed app's never does, so
    /// the CryptoKeys sites stored stay under WebKit's own item.
    @Test func onlyBuildsOffTheKeychainAnswerForTheWebCryptoKey() {
        let selector = NSSelectorFromString("_webCryptoMasterKeyForWebView:completionHandler:")
        #expect(!Tab.answers(selector, keychainAllowed: true))
        #expect(Tab.answers(selector, keychainAllowed: false))
        let other = NSSelectorFromString("webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:")
        #expect(Tab.answers(other, keychainAllowed: true))
        #expect(Tab.answers(other, keychainAllowed: false))
    }

    /// Other builds get a key of WebKit's size that stays the same for the launch.
    @Test func otherBuildsHandWebKitALaunchKey() {
        #expect(Keychain.launchWebCryptoKey.count == 16)
        #expect(Keychain.launchWebCryptoKey == Keychain.launchWebCryptoKey)
        #expect(Keychain.launchWebCryptoKey != Data(count: 16))
    }

    /// The app replaced on disk under it (an update): its Keychain items trust the new code.
    @Test func aProcessWhoseAppWasReplacedLeavesTheKeychainAlone() {
        #expect(Keychain.runs(launched: "12 1700000000.0", onDisk: "12 1700000000.0"))
        #expect(!Keychain.runs(launched: "12 1700000000.0", onDisk: "13 1700000500.0"), "replaced by an update")
        #expect(!Keychain.runs(launched: "12 1700000000.0", onDisk: nil), "gone from disk")
        #expect(!Keychain.runs(launched: nil, onDisk: nil), "unknown at launch")
        let fake = FakeKeychain(stored: Data(repeating: 7, count: 32), runsCodeOnDisk: false)
        let keychain = fake.keychain()
        #expect(keychain.secret(creating: true) == nil)
        #expect(keychain.secret(creating: true) == nil)
        #expect(fake.calls == [])
    }

    /// The only test that runs `atLaunch`: before that, the Keychain stays shut. It leaves every
    /// other Keychain user in the process (WebKit, extensions' hosts) as it was.
    @MainActor @Test func theKeychainIsShutUntilTheLaunchedExecutableIsKept() {
        #expect(Keychain.launchedExecutable == nil)
        #expect(!Keychain.Store.login.runsCodeOnDisk(), "nothing kept at launch")
        Keychain.atLaunch()
        #expect(Keychain.launchedExecutable == Keychain.executableOnDisk(Bundle.main.executablePath))
        #expect(Keychain.Store.login.runsCodeOnDisk(), "the test process is the code on disk")
        var interaction: DarwinBoolean = false
        #expect(SecKeychainGetUserInteractionAllowed(&interaction) == errSecSuccess)
        #expect(interaction.boolValue, "prompts stay on process-wide")
    }

    /// An update writes a new executable in the old one's place.
    @Test func anExecutableReplacedOnDiskIsNoLongerTheOneLaunched() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "keychain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("1".utf8).write(to: url)
        let launched = try #require(Keychain.executableOnDisk(url.path))
        #expect(Keychain.runsCodeOnDisk(launched: launched, path: url.path))
        try Data("2".utf8).write(to: url, options: .atomic)
        #expect(!Keychain.runsCodeOnDisk(launched: launched, path: url.path), "replaced by an update")
        try FileManager.default.removeItem(at: url)
        #expect(!Keychain.runsCodeOnDisk(launched: launched, path: url.path), "gone from disk")
    }

    /// An item macOS won't let this build delete without asking: no key this launch, asked once.
    @Test func anItemThatCantBeReplacedIsLeftAloneForTheLaunch() {
        let fake = FakeKeychain(stored: Data(repeating: 7, count: 32), readable: false, refusesDeleting: true)
        let keychain = fake.keychain()
        #expect(keychain.secret(creating: true) == nil)
        #expect(keychain.secret(creating: true) == nil)
        #expect(fake.calls == ["copy", "add", "delete"])
        #expect(fake.stored == Data(repeating: 7, count: 32))
    }

    @Test func anItemFoundIsReadOnceALaunch() {
        let fake = FakeKeychain(stored: Data(repeating: 7, count: 32))
        let keychain = fake.keychain()
        #expect(keychain.secret(creating: false) == Data(repeating: 7, count: 32))
        #expect(keychain.secret(creating: true) == Data(repeating: 7, count: 32))
        #expect(fake.calls == ["copy"])
    }

    /// Made by another build (or refused): read without a prompt, then replaced, once.
    @Test func anItemThisBuildCantReadIsReplacedWithoutAsking() {
        let fake = FakeKeychain(stored: Data(repeating: 7, count: 32), readable: false)
        let keychain = fake.keychain()
        #expect(keychain.secret(creating: false) == nil)
        let made = keychain.secret(creating: true)
        #expect(made?.count == 32)
        #expect(made != Data(repeating: 7, count: 32))
        #expect(keychain.secret(creating: true) == made)
        #expect(fake.calls == ["copy", "add", "delete", "add"])
        #expect(fake.stored == made)
        #expect(fake.labels == ["Lithium test key", "Lithium test key"])
        #expect(fake.withoutUI == ["copy", "delete"], "fails rather than asks")
    }

    @Test func noItemIsMadeOnFirstUse() {
        let fake = FakeKeychain(stored: nil)
        let keychain = fake.keychain()
        let made = keychain.secret(creating: true)
        #expect(made?.count == 32)
        #expect(fake.stored == made)
        #expect(fake.calls == ["copy", "add"])
    }

    /// A Keychain that refuses (locked, full) isn't asked again at every save.
    @Test func aKeychainThatRefusesIsLeftAloneForTheLaunch() {
        let fake = FakeKeychain(stored: nil, refusesAdding: true)
        let keychain = fake.keychain()
        #expect(keychain.secret(creating: true) == nil)
        #expect(keychain.secret(creating: true) == nil)
        #expect(fake.calls == ["copy", "add"])
    }

    @Test func aStoredKeyOfTheWrongSizeIsReplaced() {
        let fake = FakeKeychain(stored: Data(repeating: 7, count: 16))
        let made = fake.keychain().secret(creating: true)
        #expect(made?.count == 32)
        #expect(fake.calls == ["copy", "add", "delete", "add"])
    }
}

/// One generic password, which may be there but unreadable without a prompt (another build's).
private final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var _stored: Data?
    private var _calls: [String] = []
    private var _labels: [String] = []
    private var _withoutUI: [String] = []
    private let readable: Bool
    private let refusesAdding: Bool
    private let refusesDeleting: Bool
    private let runsCodeOnDisk: Bool

    init(stored: Data?, readable: Bool = true, refusesAdding: Bool = false, refusesDeleting: Bool = false, runsCodeOnDisk: Bool = true) {
        _stored = stored
        self.readable = readable
        self.refusesAdding = refusesAdding
        self.refusesDeleting = refusesDeleting
        self.runsCodeOnDisk = runsCodeOnDisk
    }

    var stored: Data? { lock.withLock { _stored } }
    var calls: [String] { lock.withLock { _calls } }
    var labels: [String] { lock.withLock { _labels } }
    /// The calls asked to fail rather than show a prompt.
    var withoutUI: [String] { lock.withLock { _withoutUI } }

    private func noteUI(_ call: String, _ query: [String: Any]) {
        if query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String { _withoutUI.append(call) }
    }

    func keychain() -> Keychain {
        Keychain(service: "test", account: "key", label: "Lithium test key", size: 32, store: Keychain.Store(
            copy: { query in
                self.lock.withLock {
                    self._calls.append("copy")
                    self.noteUI("copy", query)
                    guard let stored = self._stored else { return (errSecItemNotFound, nil) }
                    return self.readable ? (errSecSuccess, stored) : (errSecInteractionNotAllowed, nil)
                }
            },
            add: { attributes in
                self.lock.withLock {
                    self._calls.append("add")
                    self._labels.append(attributes[kSecAttrLabel as String] as? String ?? "")
                    if self.refusesAdding { return errSecInteractionNotAllowed }
                    guard self._stored == nil else { return errSecDuplicateItem }
                    self._stored = attributes[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            },
            delete: { query in
                self.lock.withLock {
                    self._calls.append("delete")
                    self.noteUI("delete", query)
                    if self.refusesDeleting { return errSecInteractionNotAllowed }
                    self._stored = nil
                    return errSecSuccess
                }
            },
            runsCodeOnDisk: { self.runsCodeOnDisk }))
    }
}
