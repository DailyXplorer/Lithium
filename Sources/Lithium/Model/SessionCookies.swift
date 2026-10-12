import CryptoKit
import Foundation
import Security
import WebKit

/// Session cookies (no expiry), which WebKit keeps only in memory, so sign-ins come back with the
/// tabs after a relaunch, as in Chrome. Saved at quit and with the session (`Browser.saveSessionCookies`),
/// so a crash loses only what came since; put back at the next launch, and the file deleted then.
@MainActor
enum SessionCookies {
    /// Encrypted, so the file alone (a backup, a synced folder) gives no one the sign-ins.
    static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Lithium/session-cookies")
    }

    /// Tests keep theirs in memory: they never touch the user's Keychain.
    static var key: FileKey = ExternalApps.runsTests ? .memory() : .keychain

    /// A site's session ends long before: an older file is from a session left long ago.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// Every store keyed by its space (`Space.mainID` for the default store). Removes the file
    /// when there is nothing to save, so it never outlives the sign-ins it held.
    static func save(_ stores: [Space.ID: WKWebsiteDataStore], now: Date = Date()) async {
        var saved: [String: [[String: Any]]] = [:]
        for (id, store) in stores {
            // Only what a plist holds: a property WebKit adds later that it can't is left out.
            let cookies = await store.httpCookieStore.allCookies().filter(\.isSessionOnly).map { cookie in
                Dictionary(uniqueKeysWithValues: (cookie.properties ?? [:]).compactMap { key, value in
                    PropertyListSerialization.propertyList(value, isValidFor: .binary) ? (key.rawValue, value) : nil
                })
            }
            if !cookies.isEmpty { saved[id.uuidString] = cookies }
        }
        guard !saved.isEmpty,
              let plist = try? PropertyListSerialization.data(fromPropertyList: ["saved": now, "stores": saved], format: .binary, options: 0)
        else { return forget() }
        // Off the main thread: the Keychain may block, on a prompt for the key.
        let (key, url) = (key, fileURL)
        let written = await Task.detached {
            guard let key = key.read(true), let sealed = try? AES.GCM.seal(plist, using: key).combined else { return false }
            return write(sealed, to: url)
        }.value
        if !written { forget() }
    }

    /// Made 0600 before it takes the file's place, so others can't read it even for a moment.
    nonisolated private static func write(_ data: Data, to url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return false }
        let temporary = folder.appending(path: ".\(url.lastPathComponent)-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard (try? handle.write(contentsOf: data)) != nil, (try? handle.close()) != nil,
              rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        return true
    }

    /// Puts each store's cookies back in that store only, then deletes the file. Nil, at the cost
    /// of one file check, when there is no file. A file that can't be read (no key, another
    /// key, damaged, too old) restores nothing.
    static func restore(into store: @escaping (Space.ID) -> WKWebsiteDataStore?, now: Date = Date()) -> Task<Void, Never>? {
        guard let sealed = try? Data(contentsOf: fileURL) else { return nil }
        let key = key
        return Task {
            // Off the main thread: the Keychain may block, on a prompt for the key.
            let plist = await Task.detached {
                key.read(false).flatMap { key in (try? AES.GCM.SealedBox(combined: sealed)).flatMap { try? AES.GCM.open($0, using: key) } }
            }.value
            var restores: [(WKWebsiteDataStore, HTTPCookie)] = []
            if let plist,
               let file = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
               let saved = file["saved"] as? Date, now.timeIntervalSince(saved) < maxAge,
               let stores = file["stores"] as? [String: [[String: Any]]] {
                for (id, cookies) in stores {
                    guard let id = UUID(uuidString: id), let target = store(id) else { continue }
                    restores += cookies.compactMap { properties in
                        HTTPCookie(properties: Dictionary(uniqueKeysWithValues: properties.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
                    }.map { (target, $0) }
                }
            }
            // All at once: one at a time, pages would wait a round trip to WebKit per cookie.
            await withTaskGroup(of: Void.self) { group in
                for (store, cookie) in restores {
                    group.addTask { await store.httpCookieStore.setCookie(cookie) }
                }
            }
            // Only once they are back: a quit or crash before then still finds them in the file.
            // Unless a save rewrote it meanwhile, after a restore Lithium stopped waiting for.
            if (try? Data(contentsOf: fileURL)) == sealed { forget() }
        }
    }

    static func forget() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The file's key. `read(true)` makes one when there is none.
    struct FileKey: Sendable {
        let read: @Sendable (_ creating: Bool) -> SymmetricKey?

        static func memory() -> FileKey {
            let key = SymmetricKey(size: .bits256)
            return FileKey { _ in key }
        }

        /// A generic password in the login Keychain, made on first use. One that can't be read
        /// counts as none.
        static let keychain = FileKey { creating in
            let item: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: "app.lithium.browser.session-cookies",
                kSecAttrAccount: "file-key",
            ]
            var query = item
            query[kSecReturnData] = true
            var found: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data, data.count == 32 {
                return SymmetricKey(data: data)
            }
            guard creating else { return nil }
            let key = SymmetricKey(size: .bits256)
            var added = item
            added[kSecValueData] = key.withUnsafeBytes { Data($0) }
            added[kSecAttrLabel] = "Lithium sign-in cookies"
            var status = SecItemAdd(added as CFDictionary, nil)
            // One this build can't read (signed differently, access refused, damaged) would otherwise
            // stop every save. Replaced: the file it opened is about to be rewritten.
            if status == errSecDuplicateItem, SecItemDelete(item as CFDictionary) == errSecSuccess {
                status = SecItemAdd(added as CFDictionary, nil)
            }
            return status == errSecSuccess ? key : nil
        }
    }
}

extension Task where Success == Void, Failure == Never {
    /// Until it ends or `limit` passes, whichever comes first; it goes on either way.
    func wait(atMost limit: Duration) async {
        let timer = Task<Void, Never> { try? await Task<Never, Never>.sleep(for: limit) }
        Task<Void, Never> {
            await value
            timer.cancel()
        }
        await timer.value
    }
}
