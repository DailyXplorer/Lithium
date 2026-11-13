import CryptoKit
import Foundation
import Testing
@testable import Lithium

/// Updates from a release feed: which release counts as newer, what an archive must prove
/// before it is unpacked and kept, and how the app is swapped once it has quit. The feed, the
/// archives and the apps are files of the test's own: nothing is fetched, opened or launched.
@MainActor
@Suite(.serialized)
struct UpdaterTests {
    private static let identifier = "example.updater.app"
    private let folder = FileManager.default.temporaryDirectory.appending(path: "updater-\(UUID().uuidString)")
    private let releaseKey = Curve25519.Signing.PrivateKey()

    @Test func aReleaseIsNewerByItsNumbersNotItsText() throws {
        let version = { (text: String) in try #require(AppVersion(text)) }
        #expect(try version("0.10") > version("0.9"))
        #expect(try version("1.0.1") > version("1.0"))
        #expect(try version("1.0") == version("1.0.0"))
        #expect(try version("2") > version("1.9.9"))
        for text in ["", "1.a", "1..2", "-1", "1.2.3.4.5", "v1.0"] {
            #expect(AppVersion(text) == nil, "\(text)")
        }
    }

    @Test func aCheckIsDueOnceADayAndWhenTheClockWentBack() {
        let now = Date()
        #expect(Updater.isDue(last: nil, now: now))
        #expect(!Updater.isDue(last: now.addingTimeInterval(-3600), now: now))
        #expect(Updater.isDue(last: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(Updater.isDue(last: now.addingTimeInterval(3600), now: now))
    }

    @Test func theFeedOffersOnlyAReleaseAfterThisOneBuiltForThisMac() async throws {
        defer { cleanUp() }
        let archive = try archive(of: app(version: "2.0"))
        let offered = try await channel(feed: feed(version: "2.0", archive: archive)).latest()
        #expect(offered?.version == AppVersion("2.0"))
        #expect(offered?.archive == archive)

        #expect(try await channel(feed: feed(version: "1.0", archive: archive)).latest() == nil)
        #expect(try await channel(feed: feed(version: "0.9", archive: archive)).latest() == nil)

        await #expect(throws: UpdateError.unreadable) { try await channel(feed: write("not a manifest", to: "broken.json")).latest() }
        await #expect(throws: UpdateError.unreadable) { try await channel(feed: folder.appending(path: "missing.json")).latest() }
        await #expect(throws: UpdateError.unreadable) { try await channel(feed: feed(version: "2.0", archive: archive, platform: "another-mac")).latest() }
        // A feed read over one scheme never sends the download to another.
        let elsewhere = try #require(URL(string: "http://example.com/Lithium.zip"))
        await #expect(throws: UpdateError.unreadable) { try await channel(feed: feed(version: "2.0", archive: elsewhere)).latest() }
    }

    @Test func anArchiveIsKeptOnlyWhenTheReleaseKeySignedItAndItHoldsThatRelease() async throws {
        defer { cleanUp() }
        let installed = try app(version: "1.0", in: "installed")
        let archive = try archive(of: app(version: "2.0"))
        let update = try #require(try await channel(feed: feed(version: "2.0", archive: archive)).latest())
        let staged = try await channel().stage(update, for: installed)
        defer { try? FileManager.default.removeItem(at: staged.app.deletingLastPathComponent()) }
        #expect(staged.version == AppVersion("2.0"))
        #expect(version(of: staged.app) == "2.0")

        // One byte changed on the way.
        var bytes = try Data(contentsOf: archive)
        bytes[bytes.count / 2] ^= 1
        let tampered = folder.appending(path: "tampered.zip")
        try bytes.write(to: tampered)
        await #expect(throws: UpdateError.forged) {
            try await channel().stage(.init(version: update.version, archive: tampered, signature: update.signature), for: installed)
        }
        // Signed, but by someone else.
        let stranger = try Curve25519.Signing.PrivateKey().signature(for: Data(contentsOf: archive))
        await #expect(throws: UpdateError.forged) {
            try await channel().stage(.init(version: update.version, archive: archive, signature: stranger), for: installed)
        }
    }

    @Test func aSignedArchiveOfSomethingElseIsRefused() async throws {
        defer { cleanUp() }
        let installed = try app(version: "1.0", in: "installed")
        func refused(_ app: URL, _ version: String) async throws {
            let archive = try archive(of: app)
            let update = try #require(try await channel(feed: feed(version: version, archive: archive)).latest())
            await #expect(throws: UpdateError.wrongApp) { try await channel().stage(update, for: installed) }
        }
        // An old release served under a new number.
        try await refused(app(version: "0.5", in: "old"), "2.0")
        try await refused(app(version: "2.0", identifier: "example.another.app", in: "other"), "2.0")
        // A file added after signing: macOS would refuse to launch it.
        let broken = try app(version: "2.0", in: "broken")
        try Data("added".utf8).write(to: broken.appending(path: "Contents/Resources/added.txt"))
        try await refused(broken, "2.0")
    }

    @Test func theAppIsSwappedOnceItHasQuitThenOpened() async throws {
        defer { cleanUp() }
        let installed = try app(version: "1.0", in: "installed")
        let staged = StagedUpdate(app: try app(version: "2.0", in: "staged"), version: try #require(AppVersion("2.0")))
        let opened = folder.appending(path: "opened.txt")
        let opener = folder.appending(path: "opener.sh")
        try Data("#!/bin/sh\nprintf %s \"$1\" > '\(opened.path)'\n".utf8).write(to: opener)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)

        let running = try run("/bin/sleep", ["0.4"])
        let swap = try staged.install(over: installed, after: running.processIdentifier, opener: opener.path)
        #expect(version(of: installed) == "1.0", "still running: untouched")
        try await finished(swap)
        #expect(swap.terminationStatus == 0)
        #expect(!running.isRunning)
        #expect(version(of: installed) == "2.0")
        #expect(try String(contentsOf: opened, encoding: .utf8) == installed.path)
        #expect(!FileManager.default.fileExists(atPath: staged.app.deletingLastPathComponent().path), "nothing left behind")
    }

    @Test func theOldAppStaysWhenTheNewOneCannotTakeItsPlace() async throws {
        defer { cleanUp() }
        let installed = try app(version: "1.0", in: "installed")
        let staged = StagedUpdate(app: try app(version: "2.0", in: "staged"), version: try #require(AppVersion("2.0")))
        try FileManager.default.removeItem(at: staged.app)
        let gone = try run("/usr/bin/true", [])
        try await finished(gone)

        let swap = try staged.install(over: installed, after: gone.processIdentifier, opener: nil)
        try await finished(swap)
        #expect(swap.terminationStatus != 0)
        #expect(version(of: installed) == "1.0")
    }

    @Test func aReleaseBuildFindsDownloadsAndInstallsItsUpdateAtQuit() async throws {
        defer { cleanUp() }
        let installed = try app(version: "1.0", in: "installed")
        let archive = try archive(of: app(version: "2.0"))
        let defaults = try #require(UserDefaults(suiteName: folder.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: folder.lastPathComponent) }
        let updater = Updater(channel: channel(feed: try feed(version: "2.0", archive: archive)), app: installed, defaults: defaults)
        #expect(updater.checked == nil)

        await updater.check()
        #expect(updater.state == .ready("2.0"))
        #expect(updater.checked != nil)
        #expect(version(of: installed) == "1.0", "not before Lithium quits")
        // A second check keeps the staged update.
        await updater.check()
        #expect(updater.state == .ready("2.0"))

        let gone = try run("/usr/bin/true", [])
        try await finished(gone)
        updater.installAtQuit(after: gone.processIdentifier)
        for _ in 0..<500 where version(of: installed) != "2.0" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(version(of: installed) == "2.0")
    }

    @Test func aBuildThatIsTheLatestOrCannotReplaceItselfDownloadsNothing() async throws {
        defer { cleanUp() }
        let installed = try app(version: "1.0", in: "installed")
        let archive = try archive(of: app(version: "2.0"))
        let defaults = try #require(UserDefaults(suiteName: folder.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: folder.lastPathComponent) }

        let latest = Updater(channel: channel(feed: try feed(version: "1.0", archive: archive)), app: installed, defaults: defaults)
        await latest.check()
        #expect(latest.state == .upToDate)

        let offline = Updater(channel: channel(feed: folder.appending(path: "missing.json")), app: installed, defaults: defaults)
        await offline.check()
        #expect(offline.state == .failed)

        // A folder Lithium can't write to, as the disk image it is opened from.
        let parent = installed.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        let readOnly = Updater(channel: channel(feed: try feed(version: "2.0", archive: archive)), app: installed, defaults: defaults)
        await readOnly.check()
        #expect(readOnly.state == .manual("2.0"))
        #expect(!Updater.canReplace(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/1/d/Lithium.app")))
    }

    /// `LITHIUM_RELEASE_DIR=.build/dist ./scripts/test --filter UpdaterTests`, after
    /// `./scripts/release`: what it built is an update a release build of Lithium accepts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHIUM_RELEASE_DIR"] != nil))
    func whatAReleaseBuiltIsAnUpdateLithiumAccepts() async throws {
        defer { cleanUp() }
        let release = URL(filePath: ProcessInfo.processInfo.environment["LITHIUM_RELEASE_DIR"] ?? "", directoryHint: .isDirectory)
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(contentsOf: release.appending(path: "latest.json")))
        let asset = try #require(manifest.platforms[UpdateChannel.platform])
        let publicKey = try String(contentsOf: URL(filePath: #filePath).appending(path: "../../../Support/UpdateKey.txt").standardizedFileURL, encoding: .utf8)
        let key = try #require(Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)))
        let channel = UpdateChannel(feed: release.appending(path: "latest.json"), key: key, current: try #require(AppVersion("0")), identifier: "app.lithium.browser")
        let update = UpdateChannel.Update(version: try #require(AppVersion(manifest.version)), archive: release.appending(path: "Lithium.zip"),
                                          signature: try #require(Data(base64Encoded: asset.signature)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let staged = try await channel.stage(update, for: folder)
        defer { try? FileManager.default.removeItem(at: staged.app.deletingLastPathComponent()) }
        #expect(staged.version == update.version)
        // macOS asks before it opens a quarantined app: an update must not come back as one.
        #expect(try staged.app.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties == nil)
        // The next version finds its own updates the same way.
        let info = try #require(NSDictionary(contentsOf: staged.app.appending(path: "Contents/Info.plist")))
        #expect((info["LithiumUpdateFeed"] as? String)?.hasSuffix("/releases/latest/download/latest.json") == true)
        #expect((info["LithiumUpdateKey"] as? String).flatMap { Data(base64Encoded: $0) } == key)
        #expect(asset.url.absoluteString.hasSuffix("/releases/download/v\(manifest.version)/Lithium.zip"))
    }

    // MARK: - A release of the test's own

    private func channel(feed: URL? = nil) -> UpdateChannel {
        UpdateChannel(feed: feed ?? folder.appending(path: "latest.json"), key: releaseKey.publicKey.rawRepresentation,
                      current: AppVersion("1.0")!, identifier: Self.identifier)
    }

    /// A bundle macOS would launch: a real executable, sealed by an ad hoc signature.
    private func app(version: String, identifier: String = UpdaterTests.identifier, in name: String = "release") throws -> URL {
        let app = folder.appending(path: "\(name)/Lithium.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appending(path: "Contents/MacOS/Lithium"))
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                   "CFBundleExecutable": "Lithium", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        let signing = try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        signing.waitUntilExit()
        try #require(signing.terminationStatus == 0)
        return app
    }

    private func archive(of app: URL) throws -> URL {
        let archive = app.deletingLastPathComponent().appending(path: "Lithium.zip")
        let zipping = try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
        zipping.waitUntilExit()
        try #require(zipping.terminationStatus == 0)
        return archive
    }

    private func feed(version: String, archive: URL, platform: String = UpdateChannel.platform) throws -> URL {
        let signature = archive.isFileURL ? try releaseKey.signature(for: Data(contentsOf: archive)).base64EncodedString() : ""
        let manifest: [String: Any] = ["version": version, "platforms": [platform: ["url": archive.absoluteString, "signature": signature]]]
        return try write(String(decoding: JSONSerialization.data(withJSONObject: manifest), as: UTF8.self), to: "latest-\(UUID().uuidString).json")
    }

    private func write(_ text: String, to name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try Data(text.utf8).write(to: file)
        return file
    }

    private func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func finished(_ process: Process) async throws {
        while process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }
}
