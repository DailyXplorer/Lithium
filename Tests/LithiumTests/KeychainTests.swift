import Foundation
import Security
import Testing
@testable import Lithium

/// Every Keychain here is a fake: nothing reaches the user's login Keychain.
@Suite struct KeychainTests {
    private static let installed = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    @Test func onlyTheInstalledSignedAppMayUseTheKeychain() {
        #expect(Keychain.allows(isDebug: false, runsTests: false, environment: [:], bundle: Self.installed))
        #expect(!Keychain.allows(isDebug: true, runsTests: false, environment: [:], bundle: Self.installed))
        #expect(!Keychain.allows(isDebug: false, runsTests: true, environment: [:], bundle: Self.installed))
        #expect(!Keychain.allows(isDebug: false, runsTests: false, environment: ["CFFIXED_USER_HOME": "/tmp/home"], bundle: Self.installed))
        #expect(!Keychain.allows(isDebug: false, runsTests: false, environment: [:],
                                 bundle: Self.installed.appending(path: "Contents/MacOS/Calculator")), "a bare binary")
    }

    @Test func anAdHocSignedBuildHasNoIdentity() {
        #expect(Keychain.hasSigningIdentity(Self.installed))
        #expect(!Keychain.hasSigningIdentity(Bundle(for: Marker.self).bundleURL), "the linker's ad-hoc signature")
        #expect(!Keychain.hasSigningIdentity(URL(fileURLWithPath: "/nonexistent/Lithium.app")))
    }

    @MainActor @Test func testsNeverUseTheKeychain() {
        #expect(!Keychain.isAllowed)
        #expect(Keychain.webCryptoKey(allowed: Keychain.isAllowed) == Keychain.launchWebCryptoKey)
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

private final class Marker {}

/// One generic password, which may be there but unreadable without a prompt (another build's).
private final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var _stored: Data?
    private var _calls: [String] = []
    private var _labels: [String] = []
    private let readable: Bool
    private let refusesAdding: Bool

    init(stored: Data?, readable: Bool = true, refusesAdding: Bool = false) {
        _stored = stored
        self.readable = readable
        self.refusesAdding = refusesAdding
    }

    var stored: Data? { lock.withLock { _stored } }
    var calls: [String] { lock.withLock { _calls } }
    var labels: [String] { lock.withLock { _labels } }

    func keychain() -> Keychain {
        Keychain(service: "test", account: "key", label: "Lithium test key", size: 32, store: Keychain.Store(
            copy: { _ in
                self.lock.withLock {
                    self._calls.append("copy")
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
            delete: { _ in
                self.lock.withLock {
                    self._calls.append("delete")
                    self._stored = nil
                    return errSecSuccess
                }
            }))
    }
}
