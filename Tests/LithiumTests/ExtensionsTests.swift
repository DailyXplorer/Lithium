import Foundation
import Testing
import WebKit
@testable import Lithium

@MainActor
struct ExtensionsTests {
    private let id = "aabbccddeeffgghhiijjkkllmmnnoopp"

    /// A tiny Manifest V3 extension, zipped with its files at the root like a store package.
    private func archive(manifest: String = #"{"manifest_version": 3, "name": "Tiny", "version": "1.0"}"#, links: [String: String] = [:]) throws -> Data {
        let source = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID())")
        let zip = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID()).zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: zip)
        }
        try Data(manifest.utf8).write(to: source.appending(path: "manifest.json"))
        for (name, destination) in links {
            try FileManager.default.createSymbolicLink(atPath: source.appending(path: name).path, withDestinationPath: destination)
        }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", source.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        return try Data(contentsOf: zip)
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "extensions-\(UUID())")
    }

    @Test func installedExtensionsAreKeptUnpacked() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        try await extensions.install(archive: try archive(), id: id)

        #expect(extensions.contexts[id] != nil)
        #expect(extensions.installed.map(\.name) == ["Tiny"])
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "\(id)/manifest.json").path))
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(entries == ["\(id)", "\(id).zip", "installed.json"])
    }

    /// The store showed the user one manifest; a package asking for more is refused and nothing is kept.
    @Test func aPackageAskingForMoreThanShownIsRefused() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        let shown = ChromeWebStore.Access(manifest: ["permissions": ["storage"]])
        let greedy = try archive(manifest: #"{"manifest_version": 3, "name": "Tiny", "version": "1.0", "host_permissions": ["<all_urls>"]}"#)

        await #expect(throws: ChromeWebStore.PackageError.moreAccess) {
            try await extensions.install(archive: greedy, id: id, approved: shown)
        }
        #expect(extensions.contexts[id] == nil)
        #expect(extensions.installed.isEmpty)

        try await extensions.install(archive: try archive(), id: id, approved: shown)
        #expect(extensions.contexts[id] != nil)
    }

    /// A link in the package could have WebKit serve a file from anywhere on the Mac: the package
    /// is refused, and nothing is kept.
    @Test func aPackageWithALinkIsRefused() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        let linked = try archive(links: ["hosts.txt": "/etc/hosts"])

        await #expect(throws: ChromeWebStore.PackageError.notAPackage) {
            try await extensions.install(archive: linked, id: id)
        }
        #expect(extensions.contexts[id] == nil)
        #expect(extensions.installed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: id).path))
    }

    /// Two installs of one extension at once (the store's button pressed twice) leave it loaded once.
    @Test(.timeLimit(.minutes(1))) func overlappingInstallsLoadItOnce() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        let package = try archive()
        let first = Task { try await extensions.install(archive: package, id: id) }
        let second = Task { try await extensions.install(archive: package, id: id) }
        try await first.value
        try await second.value

        #expect(extensions.controller.extensionContexts.count == 1)
        #expect(extensions.contexts[id].map { extensions.controller.extensionContexts.contains($0) } == true)
        #expect(extensions.installed.count == 1)
    }

    /// Removed while an install of it is still opening its files, the extension stays removed.
    @Test(.timeLimit(.minutes(1))) func removedWhileInstallingStaysRemoved() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        let installing = Task { try await extensions.install(archive: try archive(), id: id) }
        // The files are in place before WebKit opens them, and the list changes once it has.
        let manifest = folder.appending(path: "\(id)/manifest.json").path
        while !FileManager.default.fileExists(atPath: manifest), extensions.installed.isEmpty { await Task.yield() }
        try #require(extensions.installed.isEmpty, "the install ended before it could be removed")
        await extensions.remove(id: id)
        try await installing.value

        #expect(extensions.installed.isEmpty)
        #expect(extensions.contexts[id] == nil)
        #expect(extensions.controller.extensionContexts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: manifest))
    }

    /// Earlier builds only kept the ZIP archive: the next launch unpacks it and loads the files,
    /// and keeps the archive for those builds.
    @Test func archivesFromEarlierBuildsAreUnpackedAtLaunch() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try archive().write(to: folder.appending(path: "\(id).zip"))
        let entry = InstalledExtension(id: id, name: "Tiny", version: "1.0", isEnabled: true)
        try JSONEncoder().encode([entry]).write(to: folder.appending(path: "installed.json"))

        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        extensions.start()
        await extensions.waitUntilLoaded()

        #expect(extensions.contexts[id] != nil)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "\(id)/manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "\(id).zip").path))
    }

    private func prepared(manifest: String, worker: String? = nil) throws -> (folder: URL, manifest: [String: Any]) {
        let folder = folder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: folder.appending(path: "manifest.json"))
        if let worker {
            let file = folder.appending(path: worker)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        try ExtensionCompatibility.apply(to: folder)
        let data = try Data(contentsOf: folder.appending(path: "manifest.json"))
        return (folder, try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }

    private func text(_ file: URL) throws -> String {
        String(decoding: try Data(contentsOf: file), as: UTF8.self)
    }

    /// The module service worker becomes one, next to it, that imports the compatibility script first.
    @Test func aModuleServiceWorkerLoadsTheCompatibilityScriptFirst() throws {
        let (folder, manifest) = try prepared(manifest: #"""
            {"manifest_version": 3, "name": "Tiny", "version": "1.0",
             // A comment, as Chrome allows.
             "background": {"service_worker": "background/background.js", "type": "module"}}
            """#, worker: "background/background.js")
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(manifest["background"] as? [String: String] == ["service_worker": "background/lithium-background.js", "type": "module"])
        #expect(manifest["name"] as? String == "Tiny")
        #expect(try text(folder.appending(path: "background/lithium-background.js")) == "import \"/lithium-compat.js\";\nimport \"./background.js\";\n")
        #expect(try text(folder.appending(path: "lithium-compat.js")).contains("onCreatedNavigationTarget"))
    }

    @Test func aClassicServiceWorkerImportsTheCompatibilityScriptFirst() throws {
        let (folder, manifest) = try prepared(manifest: #"{"manifest_version": 3, "name": "Tiny", "version": "1.0", "background": {"service_worker": "worker.js"}}"#)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(manifest["background"] as? [String: String] == ["service_worker": "lithium-background.js"])
        #expect(try text(folder.appending(path: "lithium-background.js")) == "importScripts(\"/lithium-compat.js\", \"worker.js\");\n")
    }

    /// Loaded again at the next launch, a prepared extension stays as it is.
    @Test func preparingTwiceChangesNothing() throws {
        let (folder, _) = try prepared(manifest: #"{"manifest_version": 3, "name": "Tiny", "version": "1.0", "background": {"service_worker": "worker.js"}}"#)
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try text(folder.appending(path: "manifest.json"))

        try ExtensionCompatibility.apply(to: folder)
        #expect(try text(folder.appending(path: "manifest.json")) == before)
        #expect(try text(folder.appending(path: "lithium-background.js")) == "importScripts(\"/lithium-compat.js\", \"worker.js\");\n")
    }

    /// The worker's path comes from the package: one leading out of the extension's folder is
    /// refused before anything is written, there or in the folder.
    @Test func aServiceWorkerPathCannotLeadOutOfTheFolder() throws {
        let parent = folder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let extensionFolder = parent.appending(path: "extension")
        let outside = parent.appending(path: "outside")
        try FileManager.default.createDirectory(at: extensionFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let original = #"{"manifest_version": 3, "name": "Tiny", "version": "1.0", "background": {"service_worker": "../outside/worker.js"}}"#
        try Data(original.utf8).write(to: extensionFolder.appending(path: "manifest.json"))

        #expect(throws: ExtensionCompatibility.OutsideFolder.self) { try ExtensionCompatibility.apply(to: extensionFolder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try text(extensionFolder.appending(path: "manifest.json")) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: extensionFolder.path) == ["manifest.json"])
    }

    /// A quote in the worker's name stays inside the string the loader passes on.
    @Test func aWorkerNameIsQuotedInTheLoader() throws {
        let (folder, _) = try prepared(manifest: #"{"manifest_version": 3, "name": "Tiny", "version": "1.0", "background": {"service_worker": "a\");evil(\".js"}}"#)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(try text(folder.appending(path: "lithium-background.js")) == #"importScripts("/lithium-compat.js", "a\");evil(\".js");"# + "\n")
    }

    @Test func anExtensionWithoutAServiceWorkerIsLeftAlone() throws {
        let original = #"{"manifest_version": 3, "name": "Tiny", "version": "1.0"}"#
        let (folder, _) = try prepared(manifest: original)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(try text(folder.appending(path: "manifest.json")) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["manifest.json"])
    }

    /// An earlier build that updates the extension writes a new archive; it replaces the old files.
    @Test func aNewerArchiveIsUnpackedAgain() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = Extensions(folder: folder, configuration: .nonPersistent())
        try await first.install(archive: try archive(), id: id)
        let stale = folder.appending(path: "\(id)/stale.txt")
        try Data("old".utf8).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: folder.appending(path: id).path)
        try archive().write(to: folder.appending(path: "\(id).zip"))

        let second = Extensions(folder: folder, configuration: .nonPersistent())
        second.start()
        await second.waitUntilLoaded()

        #expect(second.contexts[id] != nil)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    /// Turned off again while it was still loading (the settings switch doesn't wait), the
    /// extension stays off.
    @Test(.timeLimit(.minutes(1))) func turnedOffWhileLoadingStaysOff() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        try await extensions.install(archive: try archive(), id: id)
        await extensions.setEnabled(false, id: id)
        try #require(extensions.contexts[id] == nil)
        // Files older than the archive are unpacked again (`ditto`), which keeps the load waiting
        // long enough to turn the extension off in the middle of it.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: folder.appending(path: id).path)

        let turningOn = Task { await extensions.setEnabled(true, id: id) }
        while extensions.installed.first?.isEnabled != true { await Task.yield() }
        try #require(extensions.contexts[id] == nil, "the load ended before it could be turned off")
        await extensions.setEnabled(false, id: id)
        await turningOn.value

        #expect(extensions.contexts[id] == nil)
        #expect(extensions.installed.first?.isEnabled == false)
    }
}
