import Foundation
import Testing
@testable import Lithium

/// The session, favorites, extension list and site permissions survive a file or entry this
/// build can't read: nothing is written over it before it is kept aside.
@MainActor
struct StoredStateTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "stored-state-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The files kept aside next to `file`, with what they hold.
    private func keptAside(_ file: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("\(file.lastPathComponent).unreadable-") }
            .map { try String(contentsOf: $0, encoding: .utf8) }
    }

    @Test(arguments: ["", #"[{"id": "6E2B"#])
    func anUnreadableSessionIsKeptAside(_ contents: String) throws {
        let file = try folder().appending(path: "session.json")
        try Data(contents.utf8).write(to: file)
        #expect(SessionStore.load(from: file) == Session())
        #expect(!FileManager.default.fileExists(atPath: file.path), "launch writes a new session where it was")
        #expect(try keptAside(file) == [contents])
    }

    /// A session there but not readable (its permissions) isn't taken for none: the next save
    /// would replace it.
    @Test func aSessionThatCantBeOpenedIsKeptAside() throws {
        let file = try folder().appending(path: "session.json")
        try Data(#"{"tabs": [], "selectedIndex": 0}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        #expect(SessionStore.load(from: file) == Session())
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(aside.count == 1 && aside[0].hasPrefix("session.json.unreadable-"))
    }

    /// A field this build doesn't know (a newer build's) is no reason to lose the tabs.
    @Test func aSessionWithAnUnknownFieldIsRead() throws {
        let file = try folder().appending(path: "session.json")
        try Data(#"{"tabs": [{"url": "https://example.com/", "title": "Example", "group": "Work"}], "selectedIndex": 0}"#.utf8).write(to: file)
        #expect(SessionStore.load(from: file).tabs.map(\.title) == ["Example"])
        #expect(try keptAside(file).isEmpty)
    }

    @Test(arguments: ["", #"[{"id": "6E2B"#])
    func unreadableFavoritesAreKeptAside(_ contents: String) throws {
        let file = try folder().appending(path: "pins.json")
        try Data(contents.utf8).write(to: file)
        #expect(PinStore.load(from: file).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try keptAside(file) == [contents])
    }

    /// One favorite this build can't read (its `url` isn't one) doesn't take the others with it;
    /// the file as it was is kept aside, and the readable ones written in its place.
    @Test func aFavoriteThatCantBeReadLeavesTheOthers() throws {
        let file = try folder().appending(path: "pins.json")
        let contents = """
            [{"id": "6E2B5B9C-4C5E-4F6B-9E0A-1A2B3C4D5E6F", "url": "https://mail.example.com/", "title": "Mail", "color": "blue"},
             {"id": "not a uuid", "url": "https://calendar.example.com/", "title": "Calendar"},
             {"id": "7F3C6CAD-5D6F-4A7C-8F1B-2B3C4D5E6F70", "url": "https://notes.example.com/", "title": "Notes"}]
            """
        try Data(contents.utf8).write(to: file)
        #expect(PinStore.load(from: file).map(\.title) == ["Mail", "Notes"])
        #expect(try keptAside(file) == [contents])
        #expect(PinStore.load(from: file).map(\.title) == ["Mail", "Notes"])
        #expect(try keptAside(file).count == 1, "read again, nothing more is kept aside")
    }

    @Test(arguments: ["", #"[{"id": "6E2B"#])
    func anUnreadableExtensionListIsKeptAside(_ contents: String) throws {
        let folder = try folder()
        let file = folder.appending(path: "installed.json")
        try Data(contents.utf8).write(to: file)
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        #expect(extensions.installed.isEmpty)
        #expect(try keptAside(file) == [contents])
    }

    @Test func anExtensionThatCantBeReadLeavesTheOthers() throws {
        let folder = try folder()
        let contents = """
            [{"id": "aaaa", "name": "One", "version": "1.0", "isEnabled": false, "pinned": true},
             {"id": "bbbb", "name": "Two", "version": "1.0"},
             {"id": "cccc", "name": "Three", "version": "2.0", "isEnabled": true}]
            """
        try Data(contents.utf8).write(to: folder.appending(path: "installed.json"))
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        #expect(extensions.installed.map(\.id) == ["aaaa", "cccc"])
        #expect(extensions.installed.first?.isEnabled == false)
        #expect(try keptAside(folder.appending(path: "installed.json")) == [contents])
    }

    /// An install whose list can't be written would be gone after a relaunch: it fails, rather
    /// than tell the store it worked.
    @Test func anInstallThatCantBeSavedFails() async throws {
        let folder = try folder()
        // A folder where the list goes: writing it fails.
        try FileManager.default.createDirectory(at: folder.appending(path: "installed.json"), withIntermediateDirectories: true)
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        await #expect(throws: (any Error).self) {
            try await extensions.install(archive: try Self.archive(), id: "aabbccddeeffgghhiijjkkllmmnnoopp")
        }
    }

    /// A newer build's kind of permission, or of answer, stays saved when this one saves another.
    @Test func unknownPermissionsSurviveASave() throws {
        let suite = "stored-state-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([
            "a.example": ["notifications": "allow", "camera": "deny"],
            "b.example": ["camera": "ask", "location": "allow"],
            "c.example": ["midi": "deny"],
        ], forKey: "sitePermissions")

        let permissions = SitePermissions(defaults: defaults)
        #expect(permissions.decisions["a.example"] == [.camera: .deny])
        #expect(permissions.decisions["c.example"] == nil)
        permissions.set(.allow, for: .microphone, host: "d.example")
        permissions.set(.allow, for: .camera, host: "b.example")

        let saved = defaults.dictionary(forKey: "sitePermissions") as? [String: [String: String]]
        #expect(saved == [
            "a.example": ["notifications": "allow", "camera": "deny"],
            "b.example": ["camera": "allow", "location": "allow"],
            "c.example": ["midi": "deny"],
            "d.example": ["microphone": "allow"],
        ])
    }

    /// A tiny Manifest V3 extension, zipped like a store package.
    private static func archive() throws -> Data {
        let source = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID())")
        let zip = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID()).zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: zip)
        }
        try Data(#"{"manifest_version": 3, "name": "Tiny", "version": "1.0"}"#.utf8).write(to: source.appending(path: "manifest.json"))
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", source.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        return try Data(contentsOf: zip)
    }
}
