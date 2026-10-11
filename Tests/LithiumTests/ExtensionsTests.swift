import Foundation
import Testing
import WebKit
@testable import Lithium

@MainActor
struct ExtensionsTests {
    private let id = "aabbccddeeffgghhiijjkkllmmnnoopp"

    /// A tiny Manifest V3 extension, zipped with its files at the root like a store package.
    private func archive(manifest: String = #"{"manifest_version": 3, "name": "Tiny", "version": "1.0"}"#, files: [String: String] = [:], data: [String: Data] = [:], links: [String: String] = [:]) throws -> Data {
        let source = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID())")
        let zip = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID()).zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: zip)
        }
        try Data(manifest.utf8).write(to: source.appending(path: "manifest.json"))
        for (name, contents) in files {
            try Data(contents.utf8).write(to: source.appending(path: name))
        }
        for (name, contents) in data {
            try contents.write(to: source.appending(path: name))
        }
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

    /// Removed while an install of it is still under way, the extension stays removed.
    @Test(.timeLimit(.minutes(1))) func removedWhileInstallingStaysRemoved() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        let package = try archive()
        let installing = Task { try await extensions.install(archive: package, id: id) }
        // The install writes the package before it waits for `ditto` to unpack it.
        while (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty != false { await Task.yield() }
        try #require(extensions.installed.isEmpty, "the install ended before it could be removed")
        let manifest = folder.appending(path: "\(id)/manifest.json").path
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

    /// Extensions load together at launch: each turned on is running once they are done, and the
    /// one turned off isn't.
    @Test(.timeLimit(.minutes(1))) func everyExtensionTurnedOnLoadsAtLaunch() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ids = ["a", "b", "c", "d"].map { String(repeating: $0, count: 32) }
        let worker = #""background": {"service_worker": "background.js"}"#
        for id in ids {
            try archive(manifest: #"{"manifest_version": 3, "name": "\#(id)", "version": "1.0", \#(worker)}"#, files: ["background.js": ""])
                .write(to: folder.appending(path: "\(id).zip"))
        }
        let entries = ids.map { InstalledExtension(id: $0, name: $0, version: "1.0", isEnabled: $0 != ids[2]) }
        try JSONEncoder().encode(entries).write(to: folder.appending(path: "installed.json"))

        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        extensions.start()
        await extensions.waitUntilLoaded()

        #expect(Set(extensions.contexts.keys) == [ids[0], ids[1], ids[3]])
        #expect(extensions.controller.extensionContexts.count == 3)
        for id in [ids[0], ids[1], ids[3]] {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "\(id)/\(ExtensionCompatibility.worker)").path))
        }
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

    /// Nothing updated an extension, and Remove then Add deletes its data. A newer version from the
    /// store replaces it in place, on or off as it was, and the store is asked once a day at most.
    @Test(.timeLimit(.minutes(1))) func newerVersionsReplaceTheInstalledOnceADay() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        try await extensions.install(archive: try archive(), id: id)
        await extensions.setEnabled(false, id: id)
        var asked: [[InstalledExtension]] = []
        extensions.latestVersions = { installed in
            asked.append(installed)
            return [self.id: "1.10"]
        }
        let newer = try archive(manifest: #"{"manifest_version": 3, "name": "Tiny", "version": "1.10"}"#)
        extensions.downloadArchive = { _ in newer }

        await extensions.updateIfDue()
        #expect(asked.map { $0.map(\.version) } == [["1.0"]])
        #expect(extensions.installed == [InstalledExtension(id: id, name: "Tiny", version: "1.10", isEnabled: false)])
        #expect(extensions.contexts[id] == nil)

        await extensions.updateIfDue()
        #expect(asked.count == 1)
        await extensions.updateIfDue(now: .now + Extensions.updateInterval + 60)
        #expect(asked.count == 2)
        // Offered again, the same version isn't installed again.
        #expect(extensions.installed.first?.version == "1.10")
    }

    /// The user agreed to what the installed version asks for: a version asking for more is
    /// refused, and the installed one keeps running.
    @Test(.timeLimit(.minutes(1))) func anUpdateAskingForMoreIsRefused() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        try await extensions.install(archive: try archive(), id: id)
        extensions.latestVersions = { _ in [self.id: "2.0"] }
        let greedy = try archive(manifest: #"{"manifest_version": 3, "name": "Tiny", "version": "2.0", "host_permissions": ["<all_urls>"]}"#)
        extensions.downloadArchive = { _ in greedy }

        await extensions.updateIfDue()
        #expect(extensions.installed.first?.version == "1.0")
        #expect(extensions.contexts[id] != nil)
    }

    /// A refused version was downloaded and refused again every day, and Settings never said so.
    /// It's remembered across launches, and only a newer one is downloaded.
    @Test(.timeLimit(.minutes(1))) func aRefusedUpdateIsntDownloadedAgain() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        try await extensions.install(archive: try archive(), id: id)
        var latest = "2.0"
        extensions.latestVersions = { _ in [self.id: latest] }
        var downloads = 0
        let greedy = try archive(manifest: #"{"manifest_version": 3, "name": "Tiny", "version": "2.0", "host_permissions": ["<all_urls>"]}"#)
        extensions.downloadArchive = { _ in
            downloads += 1
            return greedy
        }

        await extensions.updateIfDue()
        #expect(downloads == 1)
        #expect(extensions.installed.first?.refusedVersion == "2.0")

        let relaunched = Extensions(folder: folder, configuration: .nonPersistent())
        #expect(relaunched.installed.first?.refusedVersion == "2.0")
        relaunched.latestVersions = extensions.latestVersions
        relaunched.downloadArchive = extensions.downloadArchive
        await relaunched.updateIfDue(now: .now + Extensions.updateInterval + 60)
        #expect(downloads == 1)

        latest = "2.1"
        let newer = try archive(manifest: #"{"manifest_version": 3, "name": "Tiny", "version": "2.1"}"#)
        relaunched.downloadArchive = { _ in
            downloads += 1
            return newer
        }
        await relaunched.updateIfDue(now: .now + 2 * (Extensions.updateInterval + 60))
        #expect(downloads == 2)
        #expect(relaunched.installed == [InstalledExtension(id: id, name: "Tiny", version: "2.1", isEnabled: true)])
    }

    /// A refused version could never be accepted, short of removing the extension and its data:
    /// Settings shows what it can do, and once accepted it replaces the installed one in place.
    @Test(.timeLimit(.minutes(1))) func aRefusedUpdateCanBeAccepted() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        try await extensions.install(archive: try archive(), id: id)
        extensions.latestVersions = { _ in [self.id: "2.0"] }
        let greedy = try archive(manifest: #"{"manifest_version": 3, "name": "Tiny", "version": "2.0", "host_permissions": ["<all_urls>"]}"#)
        extensions.downloadArchive = { _ in greedy }
        await extensions.updateIfDue()
        try #require(extensions.installed.first?.refusedVersion == "2.0")

        var shown: [[String]] = []
        await #expect(throws: ChromeWebStore.PackageError.moreAccess) {
            try await extensions.updateRefused(id: id) { warnings in
                shown.append(warnings)
                return false
            }
        }
        #expect(extensions.installed.first?.version == "1.0")
        #expect(extensions.installed.first?.refusedVersion == "2.0")

        try await extensions.updateRefused(id: id) { warnings in
            shown.append(warnings)
            return true
        }
        #expect(shown == Array(repeating: ["Read and change all your data on all websites"], count: 2))
        #expect(extensions.installed == [InstalledExtension(id: id, name: "Tiny", version: "2.0", isEnabled: true)])
        #expect(extensions.contexts[id] != nil)
    }

    /// An update adding only permissions Chrome doesn't warn about asked for "more access" without
    /// naming any, and accepting granted them unseen.
    @Test(.timeLimit(.minutes(1))) func anUpdatePromptNamesPermissionsWithNoWarning() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        try await extensions.install(archive: try archive(), id: id)
        extensions.latestVersions = { _ in [self.id: "2.0"] }
        let newer = try archive(manifest: #"{"manifest_version": 3, "name": "Tiny", "version": "2.0", "permissions": ["tabs", "storage", "cookies"]}"#)
        extensions.downloadArchive = { _ in newer }
        await extensions.updateIfDue()
        try #require(extensions.installed.first?.refusedVersion == "2.0")

        var shown: [String] = []
        await #expect(throws: ChromeWebStore.PackageError.moreAccess) {
            try await extensions.updateRefused(id: id) { warnings in
                shown = warnings
                return false
            }
        }
        #expect(shown == ["Read your browsing history", "Use these features: cookies, storage"])
    }

    /// Clicked again while the first click's download ran, Update downloaded and asked twice, or
    /// reinstalled the version just accepted.
    @Test(.timeLimit(.minutes(1))) func aSecondUpdateClickWhileDownloadingDoesNothing() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        try await extensions.install(archive: try archive(), id: id)
        extensions.latestVersions = { _ in [self.id: "2.0"] }
        let greedy = try archive(manifest: #"{"manifest_version": 3, "name": "Tiny", "version": "2.0", "host_permissions": ["<all_urls>"]}"#)
        extensions.downloadArchive = { _ in greedy }
        await extensions.updateIfDue()
        try #require(extensions.installed.first?.refusedVersion == "2.0")

        var downloads = 0
        var prompts = 0
        let decline: @MainActor ([String]) async -> Bool = { _ in
            prompts += 1
            return false
        }
        extensions.downloadArchive = { _ in
            downloads += 1
            if downloads == 1 { try await extensions.updateRefused(id: self.id, confirm: decline) }
            return greedy
        }
        await #expect(throws: ChromeWebStore.PackageError.moreAccess) {
            try await extensions.updateRefused(id: self.id, confirm: decline)
        }
        #expect(downloads == 1)
        #expect(prompts == 1)

        // Once it's done, Update can be clicked again.
        try await extensions.updateRefused(id: id) { _ in true }
        #expect(extensions.installed == [InstalledExtension(id: id, name: "Tiny", version: "2.0", isEnabled: true)])
    }

    /// Removed while Update downloads the refused version, the extension stays removed.
    @Test(.timeLimit(.minutes(1))) func removedWhileUpdatingStaysRemoved() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        try await extensions.install(archive: try archive(), id: id)
        extensions.latestVersions = { _ in [self.id: "2.0"] }
        let greedy = try archive(manifest: #"{"manifest_version": 3, "name": "Tiny", "version": "2.0", "host_permissions": ["<all_urls>"]}"#)
        extensions.downloadArchive = { _ in greedy }
        await extensions.updateIfDue()
        try #require(extensions.installed.first?.refusedVersion == "2.0")
        let manifest = folder.appending(path: "\(id)/manifest.json").path

        extensions.downloadArchive = { _ in
            await extensions.remove(id: self.id)
            return greedy
        }
        try await extensions.updateRefused(id: id) { _ in true }

        #expect(extensions.installed.isEmpty)
        #expect(extensions.contexts[id] == nil)
        #expect(!FileManager.default.fileExists(atPath: manifest))
    }

    /// Settings showed no icon for a turned-off extension: it has no context to draw one from.
    @Test func aTurnedOffExtensionKeepsItsIcon() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = NSImage(size: NSSize(width: 48, height: 48), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
        let png = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
        let manifest = #"{"manifest_version": 3, "name": "Tiny", "version": "1.0", "icons": {"16": "../../outside.png", "48": "icon.png"}}"#
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        try await extensions.install(archive: try archive(manifest: manifest, data: ["icon.png": png]), id: id)
        #expect(extensions.icon(id) != nil)

        await extensions.setEnabled(false, id: id)
        #expect(extensions.contexts[id] == nil)
        #expect(extensions.icon(id) != nil)
        // Only a path inside the extension's files is read.
        #expect(extensions.icon(id, size: 16) == nil)
        #expect(extensions.icon("ppoonnmmllkkjjiihhggffeeddccbbaa") == nil)
    }

    /// The day's check was recorded before the download, so one that failed (offline) left the
    /// update for the next day. It's tried again on the next check; once installed, it waits a day.
    @Test(.timeLimit(.minutes(1))) func aFailedUpdateDownloadIsTriedAgain() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        try await extensions.install(archive: try archive(), id: id)
        var asked = 0
        extensions.latestVersions = { _ in
            asked += 1
            return [self.id: "1.10"]
        }
        extensions.downloadArchive = { _ in throw URLError(.notConnectedToInternet) }

        await extensions.updateIfDue()
        #expect(extensions.installed.first?.version == "1.0")

        let newer = try archive(manifest: #"{"manifest_version": 3, "name": "Tiny", "version": "1.10"}"#)
        extensions.downloadArchive = { _ in newer }
        await extensions.updateIfDue()
        #expect(asked == 2)
        #expect(extensions.installed.first?.version == "1.10")
        await extensions.updateIfDue()
        #expect(asked == 2)
    }

    /// Only launch checked for updates, so a Lithium left running never got any. Coming back to
    /// it checks too, once a day at most, and checks overlapping ask the store once.
    @Test(.timeLimit(.minutes(1))) func comingBackToLithiumChecksForUpdates() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        try await extensions.install(archive: try archive(), id: id)
        var asked = 0
        extensions.latestVersions = { _ in
            asked += 1
            try await Task.sleep(for: .milliseconds(200))
            return [:]
        }
        extensions.checksForUpdates = true

        extensions.appDidChangeActive(false)
        extensions.appDidChangeActive(true)
        for _ in 0..<50 where asked == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(asked == 1)
        // While the store hasn't answered, the last check's date is still old.
        await extensions.updateIfDue()
        #expect(asked == 1, "a second check while one is in flight")
        try await Task.sleep(for: .milliseconds(300))

        extensions.appDidChangeActive(false)
        extensions.appDidChangeActive(true)
        try await Task.sleep(for: .milliseconds(100))
        await extensions.updateIfDue()
        #expect(asked == 1, "checked less than a day ago")
    }
}
