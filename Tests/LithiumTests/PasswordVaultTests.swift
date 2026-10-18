import CryptoKit
import Foundation
import Security
import Testing
@testable import Lithium

/// Every vault here lives in a folder of the test's own, under a key of its own or a fake
/// Keychain: nothing reaches the user's Keychain or Lithium's folder.
@Suite struct PasswordVaultTests {
    private static let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let contents = VaultContents(
        credentials: [Credential(host: "accounts.example.com", username: "alice", password: "pa,ss\"word\nline",
                                 note: "work", created: date, modified: date)],
        neverSaved: ["example.org"])

    // MARK: Vault file

    @Test func aSealedVaultOpensWithItsKey() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try VaultFile.seal(Self.contents, key: key)
        #expect(sealed.starts(with: Data("LPV1".utf8)))
        #expect(sealed.range(of: Data("alice".utf8)) == nil, "nothing in clear")
        #expect(try VaultFile.open(sealed, key: key) == Self.contents)
    }

    @Test func aChangedFileDoesntOpen() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try VaultFile.seal(Self.contents, key: key)
        for index in [0, 3, 4, sealed.count / 2, sealed.count - 1] {
            var flipped = sealed
            flipped[index] ^= 0x01
            #expect(throws: VaultError.self, "byte \(index)") { try VaultFile.open(flipped, key: key) }
        }
        #expect(throws: VaultError.damaged) { try VaultFile.open(sealed.prefix(40), key: key) }
        #expect(throws: VaultError.damaged) { try VaultFile.open(sealed, key: SymmetricKey(size: .bits256)) }
        #expect(throws: VaultError.damaged) { try VaultFile.open(Data("not a vault".utf8), key: key) }
        #expect(throws: VaultError.unknownVersion) { try VaultFile.open(Data("LPV2".utf8) + sealed.dropFirst(4), key: key) }
    }

    // MARK: Store

    @Test func aSavedVaultLoadsBackFromAPrivateFile() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PasswordStore(fileURL: folder.appending(path: "passwords"), key: Self.fixedKey())
        #expect(try await store.load() == VaultContents(), "no file yet")
        try await store.save(Self.contents)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["passwords"], "no temporary file left")
        #expect(try await PasswordStore(fileURL: store.fileURL, key: Self.fixedKey()).load() == Self.contents)
    }

    /// The Keychain may block on a prompt: a key that only comes off the main thread still works.
    @MainActor @Test func theKeyIsReadOffTheMainThread() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = SymmetricKey(size: .bits256)
        let store = PasswordStore(fileURL: folder.appending(path: "passwords")) { _ in Thread.isMainThread ? nil : secret }
        try await store.save(Self.contents)
        #expect(try await store.load() == Self.contents)
    }

    /// A Keychain item this launch can't read isn't replaced while a file needs it: the file stays
    /// as it was, for a launch that can read the item.
    @Test func aFileWhoseKeyCantBeReadIsNeverWrittenOver() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "passwords")
        try await PasswordStore(fileURL: url, key: Self.fixedKey()).save(Self.contents)
        let before = try Data(contentsOf: url)
        let item = FakeItem(readable: false)
        let store = PasswordStore(fileURL: url, keychain: item.keychain())
        await #expect(throws: VaultError.noKey) { try await store.load() }
        await #expect(throws: VaultError.noKey) { try await store.save(VaultContents()) }
        #expect(try Data(contentsOf: url) == before)
        #expect(item.calls == ["copy"], "no key made in its place")
    }

    /// Nor one the key can't open (another key's, or changed on disk).
    @Test func aFileTheKeyCantOpenIsNeverWrittenOver() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "passwords")
        try await PasswordStore(fileURL: url, key: Self.fixedKey()).save(Self.contents)
        let before = try Data(contentsOf: url)
        let other = SymmetricKey(size: .bits256)
        let store = PasswordStore(fileURL: url) { _ in other }
        await #expect(throws: VaultError.damaged) { try await store.load() }
        await #expect(throws: VaultError.damaged) { try await store.save(VaultContents()) }
        #expect(try Data(contentsOf: url) == before)
    }

    /// Focusing a login field with no vault yet doesn't ask the Keychain; the first save makes the key.
    @Test func theKeyIsMadeWithTheFirstSave() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = FakeItem(readable: true)
        let store = PasswordStore(fileURL: folder.appending(path: "passwords"), keychain: item.keychain())
        #expect(try await store.load() == VaultContents())
        #expect(item.calls == [])
        try await store.save(Self.contents)
        #expect(item.calls == ["copy", "add"])
        #expect(try await store.load() == Self.contents)
    }

    /// A Keychain that refuses (locked, full): nothing is saved, in clear or otherwise.
    @Test func withoutAKeyNothingIsSaved() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PasswordStore(fileURL: folder.appending(path: "passwords")) { _ in nil }
        await #expect(throws: VaultError.noKey) { try await store.save(Self.contents) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    /// Nor the installed app's vault, which a launch key would leave unreadable.
    @Test func testsNeverUseTheKeychainVault() {
        #expect(PasswordStore.app.fileURL.lastPathComponent == "passwords-unkeyed")
    }

    // MARK: Helpers

    private static func fixedKey() -> @Sendable (Bool) -> SymmetricKey? {
        let key = SymmetricKey(data: Data(repeating: 9, count: 32))
        return { _ in key }
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "passwords-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// The vault's Keychain item: none yet, or one there that this build can't read without a prompt.
private final class FakeItem: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var _calls: [String] = []
    private let readable: Bool

    init(readable: Bool) {
        self.readable = readable
        if !readable { stored = Data(repeating: 7, count: 32) }
    }

    var calls: [String] { lock.withLock { _calls } }

    func keychain() -> Keychain {
        Keychain(service: "test", account: "vault-key", label: "Lithium test key", size: 32, store: Keychain.Store(
            copy: { _ in
                self.lock.withLock {
                    self._calls.append("copy")
                    guard let stored = self.stored else { return (errSecItemNotFound, nil) }
                    return self.readable ? (errSecSuccess, stored) : (errSecInteractionNotAllowed, nil)
                }
            },
            add: { attributes in
                self.lock.withLock {
                    self._calls.append("add")
                    guard self.stored == nil else { return errSecDuplicateItem }
                    self.stored = attributes[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            },
            delete: { _ in
                self.lock.withLock {
                    self._calls.append("delete")
                    self.stored = nil
                    return errSecSuccess
                }
            },
            runsCodeOnDisk: { true }))
    }
}
