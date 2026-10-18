import CryptoKit
import Foundation
import WebKit

/// Session cookies (no expiry), which WebKit keeps only in memory, so sign-ins come back with the
/// tabs after a relaunch, as in Chrome. Saved at quit and with the session (`Browser.saveSessionCookies`),
/// so a crash loses only what came since; put back at the next launch. The file stays, for a crash
/// before the next save, which replaces it.
@MainActor
enum SessionCookies {
    /// Encrypted, so the file alone (a backup, a synced folder) gives no one the sign-ins. Builds
    /// that may not use the Keychain have their own: theirs, under a key of their own, would
    /// replace the installed app's.
    static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: Keychain.isAllowed ? "Lithium/session-cookies" : "Lithium/session-cookies-unkeyed")
    }

    /// Builds that may not use the user's Keychain (`Keychain.isAllowed`) keep theirs in memory.
    static var key: FileKey = Keychain.isAllowed ? .keychain : .memory()

    /// A site's session ends long before: an older file is from a session left long ago.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// The file's key once a save or the restore had it, for `drop`, which can't wait for the Keychain.
    private static var knownKey: SymmetricKey?

    /// Every store keyed by its space (`Space.mainID` for the default store). Removes the file
    /// when there is nothing to save, so it never outlives the sign-ins it held. Without the key (a
    /// locked Keychain) the file stays, unless `replacing` after a clear: clearing wins.
    static func save(_ stores: [Space.ID: WKWebsiteDataStore], replacing: Bool = false, now: Date = Date()) async {
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
        else {
            // Without the key, this launch restored nothing: none here doesn't mean none to keep (a
            // sign-out this launch looks the same, and comes back with the key). No file, no question
            // for the Keychain.
            let key = key
            if !replacing, FileManager.default.fileExists(atPath: fileURL.path),
               await Task.detached(operation: { key.read(false) }).value == nil { return }
            return forget()
        }
        // Off the main thread: the Keychain may block, on a prompt for the key.
        let (key, url) = (key, fileURL)
        let written = await Task.detached { () -> SymmetricKey? in
            guard let key = key.read(true), let sealed = try? AES.GCM.seal(plist, using: key).combined, StoredFile.writePrivately(sealed, to: url) else { return nil }
            return key
        }.value
        if let written { knownKey = written } else if replacing { forget() }
    }

    /// Puts each store's cookies back in that store only, but those `skipping` names (a site
    /// cleared meanwhile). Nil, at the cost of one file check, when there is no file. A file that
    /// can't be read (no key, another key, damaged, too old) restores nothing.
    static func restore(into store: @escaping (Space.ID) -> WKWebsiteDataStore?, skipping: @escaping (Space.ID, HTTPCookie) -> Bool = { _, _ in false },
                        now: Date = Date()) -> Task<Void, Never>? {
        guard let sealed = try? Data(contentsOf: fileURL) else { return nil }
        let key = key
        return Task {
            // Off the main thread: the Keychain may block, on a prompt for the key.
            let opened = await Task.detached { () -> (plist: Data, key: SymmetricKey)? in
                guard let key = key.read(false), let plist = unseal(sealed, with: key) else { return nil }
                return (plist, key)
            }.value
            if let opened { knownKey = opened.key }
            var restores: [(id: Space.ID, store: WKWebsiteDataStore, cookie: HTTPCookie)] = []
            if let plist = opened?.plist,
               let file = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
               let saved = file["saved"] as? Date, now.timeIntervalSince(saved) < maxAge,
               let stores = file["stores"] as? [String: [[String: Any]]] {
                for (id, cookies) in stores {
                    guard let id = UUID(uuidString: id), let target = store(id) else { continue }
                    restores += cookies.compactMap { properties in
                        HTTPCookie(properties: Dictionary(uniqueKeysWithValues: properties.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
                    }.filter { !skipping(id, $0) }.map { (id, target, $0) }
                }
            }
            // All at once: one at a time, pages would wait a round trip to WebKit per cookie.
            await withTaskGroup(of: Void.self) { group in
                for (_, store, cookie) in restores {
                    group.addTask { await store.httpCookieStore.setCookie(cookie) }
                }
            }
            // Cleared while on its way, the clear having run without it (a restore held up past the
            // pages' bound). The clear's save waits for this task, so the file loses it too.
            for (id, store, cookie) in restores where skipping(id, cookie) {
                await store.httpCookieStore.deleteCookie(cookie)
            }
        }
    }

    /// A quit that can't wait for the save after a clear: the cleared sites' cookies leave the
    /// file now, the others stay. Without the key at hand, the whole file goes: clearing wins.
    static func drop(_ sites: [(store: Space.ID, site: String)]) {
        guard let key = knownKey, let sealed = try? Data(contentsOf: fileURL), let plist = unseal(sealed, with: key),
              var file = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              var stores = file["stores"] as? [String: [[String: Any]]]
        else { return forget() }
        for (id, site) in sites {
            stores[id.uuidString]?.removeAll { SiteInfo.site(ofCookieDomain: $0[HTTPCookiePropertyKey.domain.rawValue] as? String ?? "") == site }
        }
        file["stores"] = stores
        guard let data = try? PropertyListSerialization.data(fromPropertyList: file, format: .binary, options: 0),
              let resealed = try? AES.GCM.seal(data, using: key).combined, StoredFile.writePrivately(resealed, to: fileURL)
        else { return forget() }
    }

    nonisolated private static func unseal(_ sealed: Data, with key: SymmetricKey) -> Data? {
        (try? AES.GCM.SealedBox(combined: sealed)).flatMap { try? AES.GCM.open($0, using: key) }
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

        /// A generic password in the login Keychain, made on first use.
        static let keychain = FileKey { creating in
            Keychain.sessionCookies.secret(creating: creating).map { SymmetricKey(data: $0) }
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
