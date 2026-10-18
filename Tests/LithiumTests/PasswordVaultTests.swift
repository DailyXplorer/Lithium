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

    // MARK: Matching

    @Test func aPageIsOfferedItsOwnSitesAccountsOnly() {
        let accounts = [
            account("zoe", on: "accounts.example.com"),
            account("bob", on: "www.example.com"),
            account("amy", on: "example.com"),
            account("eve", on: "example.org"),
            account("mal", on: "example.com.evil.net"),
        ]
        #expect(SiteMatch.credentials(for: "WWW.example.com", in: accounts).map(\.username) == ["bob", "amy", "zoe"], "its host first")
        #expect(SiteMatch.credentials(for: "login.example.com", in: accounts).map(\.username) == ["amy", "bob", "zoe"], "a sibling host")
        #expect(SiteMatch.credentials(for: "example.org", in: accounts).map(\.username) == ["eve"])
        #expect(SiteMatch.credentials(for: "example.com.evil.net", in: accounts).map(\.username) == ["mal"], "a lookalike")
        #expect(SiteMatch.credentials(for: "example.net", in: accounts).isEmpty)
        #expect(SiteMatch.credentials(for: "", in: accounts).isEmpty)
    }

    // MARK: Lock

    @MainActor @Test func theLockAsksAsItsPolicySays() async {
        // Whether it asks at a fill, a reveal, then another fill and another reveal.
        let expected: [UnlockPolicy: [Bool]] = [
            .oncePerLaunch: [true, true, false, true],
            .everyTime: [true, true, true, true],
            .never: [false, false, false, false],
        ]
        for policy in UnlockPolicy.allCases {
            let prompts = Prompts(granting: true)
            let lock = VaultLock(policy: { policy }, authenticate: prompts.ask)
            var asked: [Bool] = []
            for purpose in [UnlockPurpose.fill, .reveal, .fill, .reveal] {
                #expect(lock.needsAuthentication(for: purpose) == (expected[policy]?[asked.count] ?? false), "\(policy) \(purpose)")
                let before = prompts.reasons.count
                #expect(await lock.authorize(purpose, reason: "fill"))
                asked.append(prompts.reasons.count > before)
            }
            #expect(asked == expected[policy], "\(policy)")
        }
    }

    @MainActor @Test func aFailedAuthenticationKeepsTheVaultLocked() async {
        let prompts = Prompts(granting: false)
        let lock = VaultLock(policy: { .oncePerLaunch }, authenticate: prompts.ask)
        let granted = await lock.authorize(.fill, reason: "Fill your password")
        #expect(!granted)
        #expect(!lock.isUnlocked)
        #expect(lock.needsAuthentication(for: .fill))
        #expect(prompts.reasons == ["Fill your password"])
    }

    // MARK: Generator

    @Test func aGeneratedPasswordIsLongReadableAndMixed() {
        let readable = Set(PasswordGenerator.alphabet)
        #expect(readable.isDisjoint(with: "0Oo1lI"))
        var seen = Set<String>()
        for _ in 0..<200 {
            let password = PasswordGenerator.strong()
            #expect(password.count == 20)
            let groups = password.split(separator: "-", omittingEmptySubsequences: false)
            #expect(groups.count == 3 && groups.allSatisfy { $0.count == 6 }, "\(groups.map(\.count))")
            #expect(groups.joined().allSatisfy(readable.contains))
            #expect(password.contains(where: \.isUppercase) && password.contains(where: \.isLowercase) && password.contains(where: \.isNumber))
            seen.insert(password)
        }
        #expect(seen.count == 200)
    }

    // MARK: Save offer

    @Test func theBarOffersToSaveOnlyWhatIsNew() {
        let saved = account("alice", on: "accounts.example.com", password: "one")
        let vault = VaultContents(credentials: [saved], neverSaved: ["example.org"])
        func offer(_ host: String, _ username: String, _ password: String, isPrivate: Bool = false) -> SaveOffer? {
            SaveDecision.offer(host: host, username: username, password: password, isPrivate: isPrivate, in: vault)
        }
        #expect(offer("www.example.com", "bob", "two") == .save)
        #expect(offer("example.net", "alice", "one") == .save, "another site")
        #expect(offer("www.example.com", "alice", "two") == .update(saved.id))
        #expect(offer("accounts.example.com", "alice", "one") == nil, "saved as it is")
        #expect(offer("www.example.com", "alice", "one") == nil, "saved on a sibling host")
        #expect(offer("www.example.com", "bob", "two", isPrivate: true) == nil)
        #expect(offer("www.example.com", "bob", "") == nil)
        #expect(offer("login.example.org", "bob", "two") == nil, "never for this site")
        #expect(offer("", "bob", "two") == nil)
    }

    @Test func neverForASiteIsKeptOncePerSite() {
        var vault = VaultContents()
        vault.neverSave("www.example.org")
        vault.neverSave("login.example.org")
        vault.neverSave("example.com")
        #expect(vault.neverSaved == ["example.com", "example.org"])
    }

    // MARK: Helpers

    private func account(_ username: String, on host: String, password: String = "secret") -> Credential {
        Credential(host: host, username: username, password: password, created: Self.date, modified: Self.date)
    }

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

/// Touch ID, answering every ask the same.
@MainActor private final class Prompts {
    private let granting: Bool
    private(set) var reasons: [String] = []

    init(granting: Bool) {
        self.granting = granting
    }

    func ask(_ reason: String) async -> Bool {
        reasons.append(reason)
        return granting
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
