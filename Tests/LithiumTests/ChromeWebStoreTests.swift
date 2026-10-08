import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithium

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChromeWebStoreTests {
    /// A CRX3 package: magic, version, header length, a header with a developer key proof (field 2)
    /// and the signed data naming the extension (field 10000), then the archive.
    private func package(crxID: [UInt8], archive: [UInt8] = Array("PK\u{3}\u{4}zip".utf8)) -> Data {
        let signedData: [UInt8] = [0x0A, UInt8(crxID.count)] + crxID
        let proof: [UInt8] = [0x0A, 0x03, 1, 2, 3, 0x12, 0x02, 4, 5]
        var header: [UInt8] = [0x12, UInt8(proof.count)] + proof
        header += varint(10000 << 3 | 2) + varint(UInt64(signedData.count)) + signedData
        var bytes = Array("Cr24".utf8) + [3, 0, 0, 0]
        bytes += withUnsafeBytes(of: UInt32(header.count).littleEndian, Array.init)
        return Data(bytes + header + archive)
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat {
            bytes.append(UInt8(value & 0x7F) | (value >= 0x80 ? 0x80 : 0))
            value >>= 7
        } while value > 0
        return bytes
    }

    private let crxID: [UInt8] = (0..<16).map { UInt8($0 * 0x11) }

    @Test func spellsIDsWithTheLettersAToP() {
        #expect(ChromeWebStore.extensionID(crxID) == "aabbccddeeffgghhiijjkkllmmnnoopp")
        #expect(ChromeWebStore.isExtensionID("mnjggcdmjocbbbhaepdhchncahnbgone"))
        #expect(!ChromeWebStore.isExtensionID("mnjggcdmjocbbbhaepdhchncahnbgonz"))
        #expect(!ChromeWebStore.isExtensionID("../../etc"))
    }

    @Test func takesTheArchiveOfTheRequestedExtensionOnly() throws {
        let data = package(crxID: crxID)
        #expect(try ChromeWebStore.archive(fromPackage: data, id: "aabbccddeeffgghhiijjkkllmmnnoopp") == Data("PK\u{3}\u{4}zip".utf8))
        #expect(throws: ChromeWebStore.PackageError.otherExtension) {
            try ChromeWebStore.archive(fromPackage: data, id: "mnjggcdmjocbbbhaepdhchncahnbgone")
        }
        #expect(throws: ChromeWebStore.PackageError.notAPackage) {
            try ChromeWebStore.archive(fromPackage: Data("PK\u{3}\u{4}zip".utf8), id: "aabbccddeeffgghhiijjkkllmmnnoopp")
        }
        #expect(throws: ChromeWebStore.PackageError.notAPackage) {
            try ChromeWebStore.archive(fromPackage: package(crxID: crxID, archive: Array("<html>".utf8)), id: "aabbccddeeffgghhiijjkkllmmnnoopp")
        }
        var truncated = data
        truncated.removeLast(data.count - 20)
        #expect(throws: ChromeWebStore.PackageError.notAPackage) {
            try ChromeWebStore.archive(fromPackage: truncated, id: "aabbccddeeffgghhiijjkkllmmnnoopp")
        }
    }

    @Test func downloadsFromGooglesUpdateServer() throws {
        let url = ChromeWebStore.downloadURL(for: "mnjggcdmjocbbbhaepdhchncahnbgone")
        #expect(url.host() == "clients2.google.com")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "x" }?.value == "id=mnjggcdmjocbbbhaepdhchncahnbgone&uc")
        #expect(items.first { $0.name == "prodversion" }?.value == ChromeWebStore.chromeVersion)
    }

    @Test func recognizesTheStore() {
        #expect(ChromeWebStore.isStore(URL(string: "https://chromewebstore.google.com/detail/x/mnjggcdmjocbbbhaepdhchncahnbgone")))
        #expect(!ChromeWebStore.isStore(URL(string: "http://chromewebstore.google.com/")))
        #expect(!ChromeWebStore.isStore(URL(string: "https://chromewebstore.google.com.example.com/")))
    }

    @Test func warnsLikeChrome() {
        let sponsorBlock: [String: Any] = [
            "permissions": ["storage", "scripting", "unlimitedStorage"],
            "host_permissions": ["https://*.youtube.com/*", "https://sponsor.ajay.app/*"],
            "content_scripts": [["matches": ["https://*.youtube.com/*", "https://www.youtube-nocookie.com/embed/*"]]],
        ]
        #expect(ChromeWebStore.warnings(for: sponsorBlock) == ["Read and change your data on sponsor.ajay.app, youtube-nocookie.com, and youtube.com"])

        let everything: [String: Any] = ["permissions": ["tabs", "webNavigation", "<all_urls>", "downloads"]]
        #expect(ChromeWebStore.warnings(for: everything) == [
            "Read and change all your data on all websites", "Read your browsing history", "Manage your downloads",
        ])
        #expect(ChromeWebStore.warnings(for: ["permissions": ["storage"]]).isEmpty)
    }

    /// The package installed may ask for what the user was shown, or less, never more.
    @Test func accessIsCoveredOnlyByWhatWasShown() {
        let shown = ChromeWebStore.Access(manifest: [
            "permissions": ["storage", "tabs"],
            "host_permissions": ["https://*.youtube.com/*", "https://sponsor.ajay.app/*"],
        ])
        let same = ChromeWebStore.Access(manifest: ["permissions": ["tabs"], "host_permissions": ["https://www.youtube.com/*"]])
        let otherSite = ChromeWebStore.Access(manifest: ["host_permissions": ["https://example.com/*"]])
        let everySite = ChromeWebStore.Access(manifest: ["permissions": ["<all_urls>"]])
        let history = ChromeWebStore.Access(manifest: ["permissions": ["history"]])
        #expect(same.isCovered(by: shown))
        #expect(!otherSite.isCovered(by: shown))
        #expect(!everySite.isCovered(by: shown))
        #expect(!history.isCovered(by: shown))
        #expect(otherSite.isCovered(by: everySite))
    }

    /// The names shown drop the scheme and a leading "*.", but what the package may reach doesn't.
    @Test func accessIsCoveredOnlyForTheSchemesAndSubdomainsShown() {
        let shown = ChromeWebStore.Access(manifest: ["host_permissions": ["https://example.com/*", "https://*.youtube.com/*"]])
        func access(_ pattern: String) -> ChromeWebStore.Access {
            ChromeWebStore.Access(manifest: ["host_permissions": [pattern]])
        }
        #expect(!access("*://*.example.com/*").isCovered(by: shown))
        #expect(!access("https://*.example.com/*").isCovered(by: shown))
        #expect(!access("https://www.example.com/*").isCovered(by: shown))
        #expect(!access("http://example.com/*").isCovered(by: shown))
        #expect(!access("https://*/*").isCovered(by: shown))
        #expect(access("https://example.com/path/*").isCovered(by: shown))
        #expect(access("https://music.youtube.com/*").isCovered(by: shown))
        #expect(!access("https://notyoutube.com/*").isCovered(by: shown))
        #expect(access("http://example.com/*").isCovered(by: access("*://example.com/*")))
        #expect(!access("https://example.com/*").isCovered(by: access("http://*/*")))
    }

    /// Sites allowed to message the extension, and optional site access, are granted like the rest,
    /// so they are shown and checked like the rest.
    @Test func messagingAndOptionalSitesAreShownAndChecked() {
        let shown = ChromeWebStore.Access(manifest: ["permissions": ["storage"]])
        let messaging = ChromeWebStore.Access(manifest: ["permissions": ["storage"], "externally_connectable": ["matches": ["https://example.com/*"]]])
        let optional = ChromeWebStore.Access(manifest: ["permissions": ["storage"], "optional_host_permissions": ["https://example.com/*"]])
        #expect(!messaging.isCovered(by: shown))
        #expect(!optional.isCovered(by: shown))
        #expect(messaging.isCovered(by: messaging))
        #expect(messaging.sites == ["example.com"])

        let granted = ChromeWebStore.Access(permissions: ["storage"], patterns: ["https://example.com/*"])
        #expect(!granted.isCovered(by: shown))
        #expect(granted.isCovered(by: optional))
    }

    /// Access to local files, or through a pattern that names no site, is granted, so it is shown.
    @Test func localFilesAndUnreadPatternsAreShown() {
        #expect(ChromeWebStore.warnings(for: ["host_permissions": ["file:///*"]]) == ["Read files on this Mac"])
        #expect(ChromeWebStore.warnings(for: ["host_permissions": ["https:///*"]]) == ["Reach https:///*"])
        #expect(ChromeWebStore.warnings(for: ["permissions": ["storage"]]).isEmpty)
    }

    /// Local files and patterns that can't be read name no site, and are only covered by what was shown.
    @Test func accessToLocalFilesIsCoveredOnlyWhenShown() {
        let shown = ChromeWebStore.Access(manifest: ["host_permissions": ["https://example.com/*"]])
        func access(_ pattern: String) -> ChromeWebStore.Access {
            ChromeWebStore.Access(manifest: ["host_permissions": ["https://example.com/*", pattern]])
        }
        #expect(!access("file:///*").isCovered(by: shown))
        #expect(!access("https:///*").isCovered(by: shown))
        #expect(access("file:///Users/*").isCovered(by: access("file:///*")))
        #expect(access("file:///*").isCovered(by: ChromeWebStore.Access(manifest: ["permissions": ["<all_urls>"]])))
        #expect(!access("file:///*").isCovered(by: ChromeWebStore.Access(manifest: ["host_permissions": ["*://*/*"]])))
        #expect(access("https:///*").isCovered(by: access("https:///*")))
    }

    /// The names shown drop the path, and many permissions show no warning; what the package may
    /// reach and use is compared as it is.
    @Test func accessIsCoveredOnlyForThePathsAndPermissionsShown() {
        let shown = ChromeWebStore.Access(manifest: [
            "permissions": ["storage"],
            "host_permissions": ["https://www.example.com/docs/*"],
        ])
        func access(_ pattern: String, _ permissions: [String] = ["storage"]) -> ChromeWebStore.Access {
            ChromeWebStore.Access(manifest: ["permissions": permissions, "host_permissions": [pattern]])
        }
        #expect(access("https://www.example.com/docs/*").isCovered(by: shown))
        #expect(access("https://www.example.com/docs/api/*").isCovered(by: shown))
        #expect(access("https://www.example.com/docs/*", []).isCovered(by: shown))
        #expect(!access("https://www.example.com/*").isCovered(by: shown))
        #expect(!access("*://*.example.com/*").isCovered(by: shown))
        #expect(!access("https://www.example.com/docs*").isCovered(by: shown))
        #expect(!access("https://www.example.com/docs/*", ["storage", "cookies"]).isCovered(by: shown))
        #expect(!access("https://www.example.com/docs/*", ["scripting"]).isCovered(by: shown))
    }

    /// The store page gets Chrome's user agent and `chrome.webstorePrivate`, answered by Lithium;
    /// installing needs the user's approval first, and no other site can reach the bridge.
    @Test func storePageTalksToLithiumAndNoOtherSiteDoes() async throws {
        let extensions = Extensions(folder: .temporaryDirectory.appending(path: "extensions-\(UUID())"), configuration: .nonPersistent())
        let store = try await page(at: "https://chromewebstore.google.com/detail/x/mnjggcdmjocbbbhaepdhchncahnbgone", extensions)
        let answers = try #require(try await store.callAsyncJavaScript("""
            const id = 'mnjggcdmjocbbbhaepdhchncahnbgone';
            const status = await new Promise((resolve) => chrome.webstorePrivate.getExtensionStatus(id, '{}', resolve));
            const version = await chrome.webstorePrivate.getFullChromeVersion();
            const all = await new Promise((resolve) => chrome.management.getAll(resolve));
            const error = await new Promise((resolve) => chrome.webstorePrivate.completeInstall(id, () => resolve(chrome.runtime.lastError?.message)));
            return { status, version: version.version_number, all: all.length, error, userAgent: navigator.userAgent };
            """, contentWorld: .page) as? [String: Any])
        #expect(answers["status"] as? String == "installable")
        #expect(answers["version"] as? String == ChromeWebStore.chromeVersion)
        #expect(answers["all"] as? Int == 0)
        #expect((answers["error"] as? String)?.hasSuffix("does not match a previous call to beginInstallWithManifest3") == true)
        #expect((answers["userAgent"] as? String)?.contains("Chrome/141.0.0.0") == true)
        #expect(extensions.installed.isEmpty)

        let other = try await page(at: "https://example.com/", extensions)
        let denied = try await other.callAsyncJavaScript("""
            return await window.webkit.messageHandlers.lithiumWebstore.postMessage({ member: 'management.getAll', args: [] })
              .then(() => 'answered', (error) => error.message);
            """, contentWorld: .page) as? String
        #expect(denied == "Not allowed")
    }

    /// An approval the store leaves unused lapses: a `completeInstall` much later doesn't add the
    /// extension without asking again. (The approval's own install would fetch from Google.)
    @Test func anApprovalLeftUnusedLapses() async throws {
        let extensions = Extensions(folder: .temporaryDirectory.appending(path: "extensions-\(UUID())"), configuration: .nonPersistent())
        let bridge = extensions.webstoreBridge
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let id = "mnjggcdmjocbbbhaepdhchncahnbgone"
        let begin = Task {
            await bridge.answer("webstorePrivate.beginInstallWithManifest3", arguments: [[
                "id": id, "manifest": #"{"name":"Blocker","manifest_version":3}"#,
            ]], window: window).value as? String
        }
        let deadline = Date().addingTimeInterval(10)
        while window.attachedSheet == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let sheet = try #require(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(await begin.value == "", "approved")

        let later = Date().addingTimeInterval(WebstoreBridge.approvalLifetime + 1)
        bridge.now = { later }
        let reply = await bridge.answer("webstorePrivate.completeInstall", arguments: [id], window: window)
        #expect(reply.error?.hasSuffix("does not match a previous call to beginInstallWithManifest3") == true)
        #expect(extensions.installed.isEmpty)
    }

    /// The tab takes the bridge away when another page shows and adds a new one when the store
    /// comes back; a store page restored from the back-forward cache must reach the new one.
    @Test func storePageReachesTheBridgeAddedAgain() async throws {
        let extensions = Extensions(folder: .temporaryDirectory.appending(path: "extensions-\(UUID())"), configuration: .nonPersistent())
        let store = try await page(at: "https://chromewebstore.google.com/", extensions)
        let controller = store.configuration.userContentController
        controller.removeScriptMessageHandler(forName: WebstoreBridge.name, contentWorld: .page)
        controller.addScriptMessageHandler(extensions.webstoreBridge, contentWorld: .page, name: WebstoreBridge.name)
        let count = try await store.callAsyncJavaScript("return (await chrome.management.getAll()).length", contentWorld: .page) as? Int
        #expect(count == 0)
    }

    private func page(at address: String, _ extensions: Extensions) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(ChromeWebStore.script)
        configuration.userContentController.addScriptMessageHandler(extensions.webstoreBridge, contentWorld: .page, name: WebstoreBridge.name)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = PageLoad()
        webView.navigationDelegate = navigation
        webView.loadHTMLString("<title>Page</title>", baseURL: URL(string: address))
        try await navigation.wait()
        return webView
    }

    /// Real Chrome Web Store and SponsorBlock: `LITHIUM_LIVE_TESTS=1 swift test --filter ChromeWebStoreTests`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHIUM_LIVE_TESTS"] == "1"))
    func downloadsARealExtension() async throws {
        let id = "mnjggcdmjocbbbhaepdhchncahnbgone"
        let archive = try ChromeWebStore.archive(fromPackage: try await ChromeWebStore.download(id), id: id)
        let file = URL.temporaryDirectory.appending(path: "\(UUID()).zip")
        try archive.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let webExtension = try await WKWebExtension(resourceBaseURL: file)
        #expect(webExtension.displayName?.contains("SponsorBlock") == true)
        #expect(webExtension.manifestVersion == 3)
        #expect(webExtension.errors.isEmpty)
    }
}
