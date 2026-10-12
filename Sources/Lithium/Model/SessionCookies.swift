import CryptoKit
import Foundation
import Security
import WebKit

/// Session cookies (no expiry), which WebKit keeps only in memory, so sign-ins come back with the
/// tabs after a relaunch, as in Chrome. Saved at quit, put back at the next launch and the file
/// deleted then: it never exists while Lithium runs, so whatever clears data meanwhile (a site's
/// data, a space) is what the next quit saves. A crash loses the session's, as before.
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
        guard !saved.isEmpty else { return forget() }
        do {
            let plist = try PropertyListSerialization.data(fromPropertyList: ["saved": now, "stores": saved], format: .binary, options: 0)
            guard let key = key.read(true) else { return forget() }
            let sealed = try AES.GCM.seal(plist, using: key).combined ?? Data()
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sealed.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            forget()
        }
    }

    /// Puts each store's cookies back in that store only, then deletes the file. Nil, at the cost
    /// of one file check, when there is nothing to restore. A file that can't be read (no key, another
    /// key, damaged, too old) restores nothing.
    static func restore(into store: (Space.ID) -> WKWebsiteDataStore?, now: Date = Date()) -> Task<Void, Never>? {
        guard let sealed = try? Data(contentsOf: fileURL) else { return nil }
        forget()
        var restores: [(WKWebsiteDataStore, [HTTPCookie])] = []
        if let key = key.read(false),
           let box = try? AES.GCM.SealedBox(combined: sealed),
           let plist = try? AES.GCM.open(box, using: key),
           let file = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
           let saved = file["saved"] as? Date, now.timeIntervalSince(saved) < maxAge,
           let stores = file["stores"] as? [String: [[String: Any]]] {
            for (id, cookies) in stores {
                guard let id = UUID(uuidString: id), let target = store(id) else { continue }
                restores.append((target, cookies.compactMap { properties in
                    HTTPCookie(properties: Dictionary(uniqueKeysWithValues: properties.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
                }))
            }
        }
        guard !restores.isEmpty else { return nil }
        return Task {
            for (store, cookies) in restores {
                for cookie in cookies { await store.httpCookieStore.setCookie(cookie) }
            }
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
            return SecItemAdd(added as CFDictionary, nil) == errSecSuccess ? key : nil
        }
    }
}
