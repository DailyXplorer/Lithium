import AppKit
import CryptoKit
import Observation
import Security

/// A release's number: "0.10" comes after "0.9", and "1.0" is "1.0.0".
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let description: String
    private let parts: [Int]

    init?(_ text: String) {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? -1 }
        guard !fields.isEmpty, fields.count <= 4, !fields.contains(where: { $0 < 0 }) else { return nil }
        var parts = fields
        while parts.last == 0 { parts.removeLast() }
        self.parts = parts
        description = text
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { a.parts == b.parts }
    static func < (a: AppVersion, b: AppVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
}

/// What a release publishes as `latest.json`: the shape a Tauri updater reads.
struct UpdateManifest: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let url: URL
        /// Base64 of the Ed25519 signature of the archive's bytes.
        let signature: String
    }

    let version: String
    let platforms: [String: Asset]
}

enum UpdateError: Error, Equatable {
    /// The feed or the archive can't be fetched, or isn't what a release publishes.
    case unreadable
    /// The archive isn't signed by the release key.
    case forged
    /// The archive holds something else than the Lithium the feed announced, or one that can't launch.
    case wrongApp
}

/// Where a build of Lithium finds its updates, and how it tells its own from a forgery.
struct UpdateChannel: Sendable {
    struct Update: Sendable, Equatable {
        let version: AppVersion
        let archive: URL
        let signature: Data
    }

    let feed: URL
    /// The release key's public half, 32 bytes.
    let key: Data
    let current: AppVersion
    let identifier: String
    var session = URLSession(configuration: .ephemeral)

    #if arch(arm64)
    static let platform = "darwin-aarch64"
    #else
    static let platform = "darwin-x86_64"
    #endif

    /// The release after this build, or nil when this build is the latest.
    func latest() async throws(UpdateError) -> Update? {
        guard let (data, response) = try? await session.data(from: feed), Self.isOK(response),
              let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data),
              let version = AppVersion(manifest.version) else { throw .unreadable }
        guard version > current else { return nil }
        guard let asset = manifest.platforms[Self.platform], asset.url.scheme == feed.scheme,
              let signature = Data(base64Encoded: asset.signature) else { throw .unreadable }
        return Update(version: version, archive: asset.url, signature: signature)
    }

    /// Downloads `update`, checks it, and unpacks it where it can take `app`'s place.
    func stage(_ update: Update, for app: URL) async throws(UpdateError) -> StagedUpdate {
        guard let (file, response) = try? await session.download(from: update.archive), Self.isOK(response) else { throw .unreadable }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let bytes = try? Data(contentsOf: file, options: .mappedIfSafe) else { throw .unreadable }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: key), key.isValidSignature(update.signature, for: bytes) else { throw .forged }
        // On the app's volume: the swap is then two renames, and neither can stop halfway.
        guard let folder = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true) else { throw .unreadable }
        guard await Self.run("/usr/bin/ditto", ["-x", "-k", file.path, folder.path]),
              let staged = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: staged.appending(path: "Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == identifier,
              // The archive's own number, which the signature covers: an old release served under
              // a new number stops here.
              (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == update.version,
              Self.isLaunchable(staged) else {
            try? FileManager.default.removeItem(at: folder)
            throw .wrongApp
        }
        return StagedUpdate(app: staged, version: update.version)
    }

    /// An Apple silicon Mac refuses to launch a bundle whose signature doesn't seal its files.
    static func isLaunchable(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    private static func isOK(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse).map { $0.statusCode == 200 } ?? true
    }

    private static func run(_ tool: String, _ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}

/// A checked copy of the next version, waiting next to the app it replaces.
struct StagedUpdate: Sendable, Equatable {
    let app: URL
    let version: AppVersion

    /// Waits for the process to be gone (a bundle swapped under a running app has it read the
    /// next version's resources), and for a minute at most: a dialog can keep the app open.
    /// The old bundle is put back if the new one can't take its place.
    private static let swap = """
    pid=$1 target=$2 staged=$3 opener=$4
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      waited=$((waited + 1))
      [ "$waited" -gt 300 ] && exit 1
      sleep 0.2
    done
    folder=$(dirname "$staged")
    mv "$target" "$folder/previous.app" || exit 1
    if ! mv "$staged" "$target"; then
      mv "$folder/previous.app" "$target"
      exit 1
    fi
    rm -rf "$folder"
    [ -n "$opener" ] && "$opener" "$target"
    exit 0
    """

    /// Puts this copy in `target`'s place once the process `pid` is gone, then opens it with
    /// `opener` if one is given.
    @discardableResult
    func install(over target: URL, after pid: pid_t = getpid(), opener: String?) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.swap, "sh", String(pid), target.path, app.path, opener ?? ""]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}

/// Keeps a release build of Lithium up to date: asks the feed once a day, downloads and checks
/// what it finds, and swaps the app when it quits. A build without a feed has no updater.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle, checking, upToDate, failed
        case downloading(String)
        /// Staged: it installs when Lithium quits.
        case ready(String)
        /// Found, but this copy can't replace itself (run from the disk image, or a folder it can't write to).
        case manual(String)
    }

    private(set) var state = State.idle
    @ObservationIgnored private let channel: UpdateChannel
    @ObservationIgnored private let app: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var staged: StagedUpdate?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var opensAfterQuit = false

    private static let automaticKey = "updateAutomatically"
    private static let checkedKey = "updateChecked"
    static let interval: TimeInterval = 24 * 60 * 60

    init(channel: UpdateChannel, app: URL, defaults: UserDefaults = .standard) {
        self.channel = channel
        self.app = app
        self.defaults = defaults
    }

    /// The updater of a release build: `scripts/release` writes the feed and the key in its
    /// Info.plist. Any other build (a checkout's, a fork's) has neither, and never asks.
    static func bundled(_ bundle: Bundle = .main) -> Updater? {
        let info = bundle.infoDictionary ?? [:]
        guard let feed = (info["LithiumUpdateFeed"] as? String).flatMap(URL.init(string:)), feed.scheme == "https",
              let key = (info["LithiumUpdateKey"] as? String).flatMap({ Data(base64Encoded: $0) }), key.count == 32,
              let current = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
              let identifier = bundle.bundleIdentifier else { return nil }
        return Updater(channel: UpdateChannel(feed: feed, key: key, current: current, identifier: identifier), app: bundle.bundleURL)
    }

    var isAutomatic: Bool {
        get { defaults.object(forKey: Self.automaticKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.automaticKey) }
    }

    var checked: Date? { defaults.object(forKey: Self.checkedKey) as? Date }

    /// The page with every release, for a copy that can't update itself.
    var downloads: URL { channel.feed.deletingLastPathComponent().deletingLastPathComponent() }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            // Not while the app launches and restores its tabs.
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                if let self, isAutomatic, Self.isDue(last: checked) { await check() }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    /// A check dated in the future (clock set ahead) counts as old, or checks would stop until
    /// the clock caught up.
    static func isDue(last: Date?, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(last ?? .distantPast)
        return age > interval || age < 0
    }

    /// Marks the check as running before returning: the settings page reads the state in the same reply.
    func checkNow() {
        guard begin() else { return }
        Task { await finishCheck() }
    }

    func check() async {
        guard begin() else { return }
        await finishCheck()
    }

    /// A staged update stays the one to install: the next check follows the relaunch.
    private func begin() -> Bool {
        guard staged == nil, state != .checking, !isDownloading else { return false }
        state = .checking
        return true
    }

    private func finishCheck() async {
        do {
            let update = try await channel.latest()
            if let update, Self.canReplace(app) {
                state = .downloading(update.version.description)
                staged = try await channel.stage(update, for: app)
                state = .ready(update.version.description)
            } else {
                state = update.map { .manual($0.version.description) } ?? .upToDate
            }
            // Not after a failure: the next hour tries again.
            defaults.set(Date(), forKey: Self.checkedKey)
        } catch {
            state = .failed
        }
    }

    /// macOS runs an app opened from a disk image or from Downloads out of a read-only copy
    /// elsewhere: replacing that copy would update nothing the user can find again.
    static func canReplace(_ app: URL) -> Bool {
        !app.path.contains("/AppTranslocation/") && FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: app.path)
    }

    /// Quits into the staged version.
    func relaunch() {
        guard staged != nil else { return }
        opensAfterQuit = true
        NSApp.terminate(nil)
        // Still here: a dialog kept Lithium open, and a later quit is not a relaunch.
        opensAfterQuit = false
    }

    /// From `applicationWillTerminate`: the next launch is the new version.
    func installAtQuit(after pid: pid_t = getpid()) {
        try? staged?.install(over: app, after: pid, opener: opensAfterQuit ? "/usr/bin/open" : nil)
    }

    private var isDownloading: Bool {
        if case .downloading = state { true } else { false }
    }
}
