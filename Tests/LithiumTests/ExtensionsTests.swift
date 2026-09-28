import Foundation
import Testing
import WebKit
@testable import Lithium

@MainActor
struct ExtensionsTests {
    private let id = "aabbccddeeffgghhiijjkkllmmnnoopp"

    /// A tiny Manifest V3 extension, zipped with its files at the root like a store package.
    private func archive(manifest: String = #"{"manifest_version": 3, "name": "Tiny", "version": "1.0"}"#) throws -> Data {
        let source = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID())")
        let zip = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID()).zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: zip)
        }
        try Data(manifest.utf8).write(to: source.appending(path: "manifest.json"))
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
}
