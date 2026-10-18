import CryptoKit
import Foundation

/// One saved account. Its description leaves the password out, so a stray log line can't show it.
struct Credential: Codable, Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var id = UUID()
    /// The host the account was saved on, lowercased ("accounts.example.com").
    var host: String
    var username: String
    var password: String
    var note = ""
    var created: Date
    var modified: Date

    /// What fills and saves match on: an account works across one site's hosts, never another site.
    var site: String { SiteInfo.registrable(host) }

    var description: String { "Credential(\(username) on \(host))" }
    var debugDescription: String { description }
}

/// Everything the vault file holds.
struct VaultContents: Codable, Equatable, Sendable {
    var credentials: [Credential] = []
    /// Registrable sites, sorted and unique.
    var neverSaved: [String] = []

    mutating func neverSave(_ host: String) {
        let site = SiteInfo.registrable(host)
        guard !site.isEmpty else { return }
        neverSaved = Set(neverSaved + [site]).sorted()
    }
}

enum VaultError: Error, Equatable {
    /// There is a file but no key this launch can read, or no key could be made.
    case noKey
    /// The key doesn't open it: changed on disk, cut short, or another key's.
    case damaged
    /// From a newer Lithium.
    case unknownVersion
    case unwritable
}

/// "LPV1", whose last byte is the format's version, then the AES-GCM box of the JSON contents.
/// The header is also the box's authenticated data, so a swapped header fails to open too.
enum VaultFile {
    static let magic = Data("LPV1".utf8)

    static func seal(_ contents: VaultContents, key: SymmetricKey) throws(VaultError) -> Data {
        guard let json = try? JSONEncoder().encode(contents),
              let box = try? AES.GCM.seal(json, using: key, authenticating: magic).combined
        else { throw .unwritable }
        return magic + box
    }

    static func open(_ data: Data, key: SymmetricKey) throws(VaultError) -> VaultContents {
        guard data.starts(with: magic) else {
            throw data.starts(with: magic.prefix(3)) && data.count > 3 ? VaultError.unknownVersion : .damaged
        }
        guard let box = try? AES.GCM.SealedBox(combined: Data(data.dropFirst(magic.count))),
              let json = try? AES.GCM.open(box, using: key, authenticating: magic),
              let contents = try? JSONDecoder().decode(VaultContents.self, from: json)
        else { throw .damaged }
        return contents
    }
}

/// The vault file and the key that opens it, read and written off the main thread: the Keychain
/// may block. A file there that this launch can't open is never written over: the passwords it
/// holds come back with a launch that has the key.
actor PasswordStore {
    let fileURL: URL
    /// `creating` makes one when there is none. Only asked so when there is no file, since a new
    /// key would leave the file's passwords behind for good.
    private let key: @Sendable (_ creating: Bool) -> SymmetricKey?

    init(fileURL: URL, key: @escaping @Sendable (_ creating: Bool) -> SymmetricKey?) {
        self.fileURL = fileURL
        self.key = key
    }

    init(fileURL: URL, keychain: Keychain) {
        self.init(fileURL: fileURL) { creating in keychain.secret(creating: creating).map { SymmetricKey(data: $0) } }
    }

    /// Builds that may not use the Keychain (`Keychain.isAllowed`) keep a vault of their own under
    /// a key for the launch. The last launch's file went with its key, so it goes.
    static let app: PasswordStore = {
        let folder = URL.applicationSupportDirectory.appending(path: "Lithium")
        guard Keychain.isAllowed else {
            let url = folder.appending(path: "passwords-unkeyed")
            try? FileManager.default.removeItem(at: url)
            let key = SymmetricKey(size: .bits256)
            return PasswordStore(fileURL: url) { _ in key }
        }
        return PasswordStore(fileURL: folder.appending(path: "passwords"), keychain: .passwords)
    }()

    /// Empty, without asking the Keychain, when there is no file yet.
    func load() throws(VaultError) -> VaultContents {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return VaultContents() }
        return try openFile()
    }

    func save(_ contents: VaultContents) throws(VaultError) {
        let key: SymmetricKey
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let existing = self.key(false) else { throw .noKey }
            _ = try openFile(with: existing)
            key = existing
        } else {
            guard let made = self.key(true) else { throw .noKey }
            key = made
        }
        guard StoredFile.writePrivately(try VaultFile.seal(contents, key: key), to: fileURL) else { throw .unwritable }
    }

    private func openFile(with known: SymmetricKey? = nil) throws(VaultError) -> VaultContents {
        guard let data = try? Data(contentsOf: fileURL) else { throw .damaged }
        guard let opening = known ?? self.key(false) else { throw .noKey }
        return try VaultFile.open(data, key: opening)
    }
}
