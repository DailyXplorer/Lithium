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
        case unavailable, notAPackage, otherExtension

        var errorDescription: String? {
            switch self {
            case .unavailable: "The Chrome Web Store has no version of this extension for Lithium."
            case .notAPackage: "The download is not an extension package."
            case .otherExtension: "The download is a different extension than the one requested."
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

    /// What an extension will be able to do, from its manifest, in the words Chrome uses.
    static func warnings(for manifest: [String: Any]) -> [String] {
        let permissions = manifest["permissions"] as? [String] ?? []
        var patterns = (manifest["host_permissions"] as? [String] ?? []) + permissions.filter { $0.contains("://") || $0 == "<all_urls>" }
        for script in manifest["content_scripts"] as? [[String: Any]] ?? [] {
            patterns += script["matches"] as? [String] ?? []
        }
        var warnings: [String] = []
        let hosts = patterns.map(host(of:))
        if hosts.contains("*") {
            warnings.append("Read and change all your data on all websites")
        } else {
            let sites = Array(Set(hosts.compactMap { $0 })).sorted()
            if !sites.isEmpty {
                let formatter = ListFormatter()
                formatter.locale = Locale(identifier: "en")
                warnings.append("Read and change your data on \(formatter.string(from: sites) ?? sites.joined(separator: ", "))")
            }
        }
        for warning in permissions.compactMap({ permissionWarnings[$0] }) where !warnings.contains(warning) {
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
    /// Extensions the user agreed to add, waiting for the store's `completeInstall`.
    private var approved: Set<String> = []

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
        approved.insert(id)
        return Reply(value: "")
    }

    private func completeInstall(_ id: String?, window: NSWindow?) async -> Reply {
        guard let id, approved.remove(id) != nil else {
            return Reply(error: "\(id ?? "") does not match a previous call to beginInstallWithManifest3")
        }
        do {
            try await extensions.install(id: id)
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
