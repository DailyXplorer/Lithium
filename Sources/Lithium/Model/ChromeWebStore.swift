import AppKit
import WebKit

/// The Chrome Web Store (chromewebstore.google.com), made to install into Lithium. The store's own
/// page drives its Add to Chrome button through `chrome.webstorePrivate`; `webstore.js` gives it one
/// that talks to `WebstoreBridge`, which asks the user before anything is added. Extensions are
/// downloaded from Google's update server, as Chrome does, and must be the one the store asked for.
enum ChromeWebStore {
    static let host = "chromewebstore.google.com"

    /// The Chrome the store sees. Below 142.0.7430 the store judges the browser by its user agent;
    /// from that version on it also wants Chrome's client hints, which WebKit does not send.
    static let chromeVersion = "141.0.7390.0"

    static func isStore(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host() == host
    }

    static func isExtensionID(_ id: String) -> Bool {
        id.range(of: "^[a-p]{32}$", options: .regularExpression) != nil
    }

    @MainActor static let script: WKUserScript = {
        let source = Resources.bundle.url(forResource: "webstore", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return WKUserScript(
            source: source.replacingOccurrences(of: "__CHROME_VERSION__", with: chromeVersion),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
    }()

    static func downloadURL(for id: String) -> URL {
        URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&acceptformat=crx3&prodversion=\(chromeVersion)&x=id%3D\(id)%26uc")!
    }

    static func download(_ id: String) async throws -> Data {
        let (data, response) = try await session.data(from: downloadURL(for: id))
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { throw PackageError.unavailable }
        return data
    }

    private static let session = URLSession(configuration: .ephemeral)

    enum PackageError: LocalizedError {
        case unavailable, notAPackage, otherExtension, moreAccess

        var errorDescription: String? {
            switch self {
            case .unavailable: "The Chrome Web Store has no version of this extension for Lithium."
            case .notAPackage: "The download is not an extension package."
            case .otherExtension: "The download is a different extension than the one requested."
            case .moreAccess: "The downloaded version asks for more access than you agreed to. Try adding it again."
            }
        }
    }

    /// The ZIP archive inside a CRX3 package, once the package's signed header names extension `id`.
    ///
    /// Layout: "Cr24", format version 3 and the header's length (little-endian), the header (a
    /// `CrxFileHeader` protobuf), then the archive. The header's `signed_header_data` (field 10000)
    /// is a `SignedData` whose `crx_id` (field 1) is the 16 bytes the extension's id spells out.
    static func archive(fromPackage package: Data, id: String) throws -> Data {
        let bytes = [UInt8](package)
        guard bytes.count > 12, bytes.starts(with: Array("Cr24".utf8)),
              littleEndian(bytes, at: 4) == 3 else { throw PackageError.notAPackage }
        let headerEnd = 12 + Int(littleEndian(bytes, at: 8))
        guard headerEnd < bytes.count else { throw PackageError.notAPackage }
        let header = bytes[12..<headerEnd]
        guard let signed = field(10000, in: header), let crxID = field(1, in: signed), crxID.count == 16 else {
            throw PackageError.notAPackage
        }
        guard extensionID(crxID) == id else { throw PackageError.otherExtension }
        let archive = bytes[headerEnd...]
        guard archive.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { throw PackageError.notAPackage }
        return Data(archive)
    }

    /// Chrome spells ids with the letters a to p for the hex digits 0 to f.
    static func extensionID<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> String {
        String(bytes.flatMap { [$0 >> 4, $0 & 0x0F] }.map { Character(UnicodeScalar(UInt8(ascii: "a") + $0)) })
    }

    private static func littleEndian(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }

    /// The first length-delimited field `number` of a protobuf message.
    private static func field(_ number: UInt64, in message: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        var index = message.startIndex
        func varint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) where index < message.endIndex {
                let byte = message[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }
        while index < message.endIndex {
            guard let key = varint() else { return nil }
            switch key & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 1:
                index += 8
            case 2:
                guard let length = varint(), length <= UInt64(message.endIndex - index) else { return nil }
                let end = index + Int(length)
                if key >> 3 == number { return message[index..<end] }
                index = end
            case 5:
                index += 4
            default:
                return nil
            }
        }
        return nil
    }

    /// What an extension's manifest lets it do, as far as Chrome warns about it.
    struct Access {
        var allSites = false
        var sites: Set<String> = []
        /// In manifest order, without repeats.
        var permissions: [String] = []
        /// Whether a `file:` pattern gives it the files on this Mac, which no site name shows.
        var localFiles: Bool { patterns.contains { $0.scheme == "file" } }
        /// Patterns that are neither a site nor local files, shown as written.
        var otherAccess: [String] { unreadPatterns.sorted() }
        /// What decides coverage: `sites` are only the names shown, without schemes or subdomain wildcards.
        private var patterns: Set<SitePattern> = []
        /// Patterns `SitePattern` can't read, which only the same pattern covers: whatever they
        /// reach, they are granted all the same.
        private var unreadPatterns: Set<String> = []
        /// Also what decides coverage: `permissions` are only their warnings, and many have none
        /// (`cookies`, `scripting`), though every one asked for is granted.
        private var apiPermissions: Set<String> = []

        /// Lithium grants every site pattern WebKit finds in the manifest, optional ones and the
        /// sites allowed to message the extension (`externally_connectable`) included, so all of them
        /// are shown and compared, though Chrome warns about fewer.
        init(manifest: [String: Any]) {
            let declared = (manifest["permissions"] as? [String] ?? []) + (manifest["optional_permissions"] as? [String] ?? [])
            var patterns = (manifest["host_permissions"] as? [String] ?? [])
                + (manifest["optional_host_permissions"] as? [String] ?? [])
                + declared.filter(Self.isPattern)
            for script in manifest["content_scripts"] as? [[String: Any]] ?? [] {
                patterns += script["matches"] as? [String] ?? []
            }
            patterns += (manifest["externally_connectable"] as? [String: Any])?["matches"] as? [String] ?? []
            self.init(permissions: declared.filter { !Self.isPattern($0) }, patterns: patterns)
            let hosts = patterns.compactMap(ChromeWebStore.host(of:))
            allSites = hosts.contains("*")
            sites = allSites ? [] : Set(hosts)
            // Optional API permissions aren't granted at install: the user is asked when the extension wants them.
            let required = manifest["permissions"] as? [String] ?? []
            for warning in required.compactMap({ ChromeWebStore.permissionWarnings[$0] }) where !permissions.contains(warning) {
                permissions.append(warning)
            }
        }

        /// What an extension will be granted, as WebKit reads it from the package, for comparing only.
        init(permissions: [String], patterns: [String]) {
            self.patterns = Set(patterns.compactMap(SitePattern.init))
            unreadPatterns = Set(patterns.filter { SitePattern($0) == nil })
            apiPermissions = Set(permissions)
        }

        private static func isPattern(_ permission: String) -> Bool {
            permission.contains("://") || permission == "<all_urls>"
        }

        /// Whether the user, having agreed to `approved`, already agreed to all of this.
        func isCovered(by approved: Access) -> Bool {
            patterns.allSatisfy { pattern in approved.patterns.contains { $0.covers(pattern) } }
                && unreadPatterns.isSubset(of: approved.unreadPatterns)
                && apiPermissions.isSubset(of: approved.apiPermissions)
        }
    }

    /// The scheme, host and path of a match pattern, which decide the pages it reaches.
    struct SitePattern: Hashable {
        /// Nil for `<all_urls>`, every scheme; "*" is http and https, as in Chrome.
        let scheme: String?
        /// "*" for every host.
        let host: String
        /// The host and every subdomain of it, from a leading "*.".
        let withSubdomains: Bool
        /// From the "/" on, "*" standing for any characters.
        let path: String

        /// A `file:` pattern has no host, "" here. Nil for a pattern that can't be read.
        init?(_ pattern: String) {
            if pattern == "<all_urls>" {
                scheme = nil
                host = "*"
                withSubdomains = true
                path = "/*"
                return
            }
            guard let range = pattern.range(of: "://") else { return nil }
            let rest = pattern[range.upperBound...]
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            let authority = rest[..<slash].lowercased()
            path = String(rest[slash...])
            withSubdomains = authority.hasPrefix("*.")
            host = withSubdomains ? String(authority.dropFirst(2)) : authority
            let scheme = pattern[..<range.lowerBound].lowercased()
            guard !host.isEmpty || (scheme == "file" && !authority.hasPrefix("*.")) else { return nil }
            self.scheme = scheme
        }

        func covers(_ other: SitePattern) -> Bool {
            guard let scheme else { return true }
            guard let otherScheme = other.scheme,
                  scheme == otherScheme || (scheme == "*" && ["http", "https"].contains(otherScheme)) else { return false }
            guard Self.matches(path, other.path) else { return false }
            if host == "*" { return true }
            if other.host == "*" { return false }
            if withSubdomains { return other.host == host || other.host.hasSuffix("." + host) }
            return !other.withSubdomains && other.host == host
        }

        /// Whether `text`, its own "*" taken as a plain character, matches `glob`: then every path
        /// the text reaches as a pattern, the glob reaches too. Backtracks to the last "*" only,
        /// so a manifest full of them can't stall the check.
        static func matches(_ glob: String, _ text: String) -> Bool {
            let wildcard = Array(glob), literal = Array(text)
            var g = 0, t = 0
            var star: Int?
            var resume = 0
            while t < literal.count {
                if g < wildcard.count, wildcard[g] == "*" {
                    star = g
                    resume = t
                    g += 1
                } else if g < wildcard.count, wildcard[g] == literal[t] {
                    g += 1
                    t += 1
                } else if let star {
                    g = star + 1
                    resume += 1
                    t = resume
                } else {
                    return false
                }
            }
            while g < wildcard.count, wildcard[g] == "*" { g += 1 }
            return g == wildcard.count
        }
    }

    /// What an extension will be able to do, from its manifest, in the words Chrome uses.
    static func warnings(for manifest: [String: Any]) -> [String] {
        let access = Access(manifest: manifest)
        var warnings: [String] = []
        if access.allSites {
            warnings.append("Read and change all your data on all websites")
        } else if !access.sites.isEmpty {
            let sites = access.sites.sorted()
            let formatter = ListFormatter()
            formatter.locale = Locale(identifier: "en")
            warnings.append("Read and change your data on \(formatter.string(from: sites) ?? sites.joined(separator: ", "))")
        }
        // Granted like the sites, so shown like them, though they name no site.
        if access.localFiles { warnings.append("Read files on this Mac") }
        if !access.otherAccess.isEmpty { warnings.append("Reach \(access.otherAccess.joined(separator: ", "))") }
        for warning in access.permissions where !warnings.contains(warning) {
            warnings.append(warning)
        }
        return warnings
    }

    /// The site a match pattern covers, "*" for every site, nil for none (such as `file:` patterns).
    private static func host(of pattern: String) -> String? {
        if pattern == "<all_urls>" { return "*" }
        guard let range = pattern.range(of: "://") else { return nil }
        let host = pattern[range.upperBound...].prefix { $0 != "/" }
        if host == "*" { return "*" }
        let site = host.hasPrefix("*.") ? host.dropFirst(2) : host
        return site.isEmpty ? nil : (site.hasPrefix("www.") ? String(site.dropFirst(4)) : String(site))
    }

    private static let permissionWarnings: [String: String] = [
        "bookmarks": "Read and change your bookmarks",
        "clipboardRead": "Read data you copy and paste",
        "clipboardWrite": "Modify data you copy and paste",
        "contentSettings": "Change which features websites can use, such as cookies and JavaScript",
        "debugger": "Access the page debugger backend",
        "declarativeNetRequest": "Block content on any page",
        "downloads": "Manage your downloads",
        "geolocation": "Detect your physical location",
        "history": "Read and change your browsing history",
        "management": "Manage your apps, extensions, and themes",
        "nativeMessaging": "Communicate with cooperating native applications",
        "notifications": "Display notifications",
        "privacy": "Change your privacy-related settings",
        "proxy": "Read and change all your data on all websites",
        "tabs": "Read your browsing history",
        "topSites": "Read a list of your most frequently visited websites",
        "webNavigation": "Read your browsing history",
    ]
}

/// Answers the store page's `chrome.webstorePrivate` and `chrome.management` calls (`webstore.js`).
/// It only exists while a tab shows the store, and only answers the store's own top frame. Adding
/// or removing an extension always goes through a confirmation in Lithium's own UI first.
@MainActor
final class WebstoreBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "lithiumWebstore"
    private unowned let extensions: Extensions
    /// Extensions the user agreed to add, with the access they were shown, waiting for the store's `completeInstall`.
    private var approved: [String: ChromeWebStore.Access] = [:]

    init(extensions: Extensions) {
        self.extensions = extensions
    }

    /// `value` goes to the page's callback; `error` becomes `chrome.runtime.lastError` while it runs.
    struct Reply {
        var value: Any?
        var error: String?
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == "https", origin.host == ChromeWebStore.host,
              let body = message.body as? [String: Any], let member = body["member"] as? String else { return (nil, "Not allowed") }
        let reply = await answer(member, arguments: body["args"] as? [Any] ?? [], window: message.webView?.window)
        var result: [String: Any] = [:]
        result["value"] = reply.value
        result["error"] = reply.error
        return (result, nil)
    }

    func answer(_ member: String, arguments: [Any], window: NSWindow?) async -> Reply {
        let id = arguments.first as? String
        switch member {
        case "webstorePrivate.beginInstallWithManifest3":
            return await beginInstall(arguments.first as? [String: Any], window: window)
        case "webstorePrivate.completeInstall":
            return await completeInstall(id, window: window)
        case "webstorePrivate.getExtensionStatus":
            guard let entry = extensions.installed.first(where: { $0.id == id }) else { return Reply(value: "installable") }
            return Reply(value: entry.isEnabled ? "enabled" : "disabled")
        case "webstorePrivate.getFullChromeVersion":
            return Reply(value: ["version_number": ChromeWebStore.chromeVersion])
        case "webstorePrivate.getReferrerChain":
            // An empty Safe Browsing referrer chain, which the store sends along with installs.
            return Reply(value: "EgIIAA==")
        case "webstorePrivate.getMV2DeprecationStatus":
            return Reply(value: "inactive")
        case "webstorePrivate.getBrowserLogin":
            return Reply(value: ["login": ""])
        case "webstorePrivate.getStoreLogin":
            return Reply(value: "")
        case "webstorePrivate.getWebGLStatus":
            return Reply(value: "webgl_allowed")
        case "webstorePrivate.shouldShowEnterprisePromotionBanner":
            return Reply(value: "PROMOTION_TYPE_UNSPECIFIED")
        case "webstorePrivate.isInIncognitoMode", "webstorePrivate.getIsLauncherEnabled", "webstorePrivate.isPendingCustodianApproval":
            return Reply(value: false)
        case "webstorePrivate.setStoreLogin", "webstorePrivate.enableAppLauncher",
             "webstorePrivate.logEnterprisePromoShown", "webstorePrivate.onEnterprisePromoClick":
            return Reply()
        case "management.getAll":
            return Reply(value: extensions.installed.map(Self.info))
        case "management.get":
            guard let entry = extensions.installed.first(where: { $0.id == id }) else { return Reply(error: "Failed to find extension with id \(id ?? "").") }
            return Reply(value: Self.info(entry))
        case "management.setEnabled":
            guard let id, extensions.installed.contains(where: { $0.id == id }) else { return Reply(error: "Failed to find extension with id \(id ?? "").") }
            await extensions.setEnabled(arguments.dropFirst().first as? Bool ?? true, id: id)
            return Reply()
        case "management.uninstall":
            return await uninstall(id, window: window)
        default:
            return Reply(error: "\(member) is not available in Lithium.")
        }
    }

    private func beginInstall(_ details: [String: Any]?, window: NSWindow?) async -> Reply {
        guard let id = details?["id"] as? String, ChromeWebStore.isExtensionID(id) else {
            return Reply(value: "invalid_id", error: "Invalid extension id")
        }
        guard let manifest = (details?["manifest"] as? String)
            .flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }) else {
            return Reply(value: "manifest_error", error: "Invalid manifest")
        }
        guard manifest["theme"] == nil, manifest["app"] == nil else {
            return Reply(value: "unsupported_extension_type", error: "Lithium adds extensions, not themes or apps.")
        }
        let name = details?["localizedName"] as? String ?? manifest["name"] as? String ?? id
        let warnings = ChromeWebStore.warnings(for: manifest)
        let alert = NSAlert()
        alert.messageText = "Add “\(name)”?"
        alert.informativeText = warnings.isEmpty ? "It needs no special access." : "It can:\n" + warnings.map { "• \($0)" }.joined(separator: "\n")
        alert.addButton(withTitle: "Add Extension")
        alert.addButton(withTitle: "Cancel")
        if let icon = await Self.icon(at: details?["iconUrl"] as? String) { alert.icon = icon }
        guard await present(alert, in: window) == .alertFirstButtonReturn else {
            return Reply(value: "user_cancelled", error: "User cancelled install")
        }
        approved[id] = ChromeWebStore.Access(manifest: manifest)
        return Reply(value: "")
    }

    private func completeInstall(_ id: String?, window: NSWindow?) async -> Reply {
        guard let id, let access = approved.removeValue(forKey: id) else {
            return Reply(error: "\(id ?? "") does not match a previous call to beginInstallWithManifest3")
        }
        do {
            try await extensions.install(id: id, approved: access)
            return Reply()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t add this extension"
            alert.informativeText = error.localizedDescription
            _ = await present(alert, in: window)
            return Reply(error: error.localizedDescription)
        }
    }

    private func uninstall(_ id: String?, window: NSWindow?) async -> Reply {
        guard let entry = extensions.installed.first(where: { $0.id == id }) else {
            return Reply(error: "Failed to find extension with id \(id ?? "").")
        }
        let alert = NSAlert()
        alert.messageText = "Remove “\(entry.name)”?"
        alert.informativeText = "Its settings and data are removed with it."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard await present(alert, in: window) == .alertFirstButtonReturn else {
            return Reply(error: "The user did not accept the uninstall.")
        }
        await extensions.remove(id: entry.id)
        return Reply()
    }

    /// `chrome.management.ExtensionInfo`, as far as the store reads it.
    private static func info(_ entry: InstalledExtension) -> [String: Any] {
        [
            "id": entry.id, "name": entry.name, "shortName": entry.name, "description": "", "version": entry.version,
            "enabled": entry.isEnabled, "mayDisable": true, "mayEnable": true, "isApp": false, "type": "extension",
            "installType": "normal", "offlineEnabled": false, "optionsUrl": "", "permissions": [String](),
            "hostPermissions": [String](), "icons": [[String: Any]](),
        ]
    }

    /// The store's icon for the extension, for the confirmation. Only Google's image servers.
    private static func icon(at address: String?) async -> NSImage? {
        guard let url = address.flatMap(URL.init(string:)), url.scheme == "https",
              let host = url.host(), host.hasSuffix(".googleusercontent.com") || host.hasSuffix(".gstatic.com") else { return nil }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 3)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return NSImage(data: data)
    }

    private func present(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }
}
