import Foundation
import Security

/// One secret Lithium keeps in the login Keychain, read at most once a launch and never with a
/// prompt. The installed app is signed with a stable self-signed identity, so every rebuild has the
/// same designated requirement and keeps access to its items (a reinstall showed no prompt). One
/// this build can't read without asking is replaced instead or, if macOS won't let it go, left
/// alone for the launch.
final class Keychain: @unchecked Sendable {
    /// Only the installed app, signed with its own identity, uses the user's Keychain. Any other
    /// build (debug, ad-hoc signed, a test run, a throwaway home) would read the same items as
    /// another app, and the answer to its prompt changes who may read them: the real app gets asked
    /// next. Those builds keep their secrets in memory. Decided at launch (`atLaunch`), on the app
    /// as it was then: a bundle replaced on disk later doesn't change the answer.
    static let isAllowed: Bool = {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return allows(isDebug: isDebug, runsTests: ExternalApps.runsTests, environment: ProcessInfo.processInfo.environment,
                      bundle: Bundle.main.bundleURL, signed: hasSigningIdentity(Bundle.main.bundleURL))
    }()

    static func allows(isDebug: Bool, runsTests: Bool, environment: [String: String], bundle: URL, signed: Bool) -> Bool {
        !isDebug && !runsTests && environment["CFFIXED_USER_HOME"] == nil && bundle.pathExtension == "app" && signed
    }

    /// An ad-hoc signature, as the linker leaves, carries no certificate.
    static func hasSigningIdentity(_ bundle: URL) -> Bool {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return false }
        return ((info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [Any])?.isEmpty == false
    }

    /// False once the app was replaced on disk under this process (an update): the items trust the
    /// new code, and this process asking for them is what shows a prompt.
    static func runsCodeOnDisk(launched: String? = launchedExecutable, path: String? = Bundle.main.executablePath) -> Bool {
        runs(launched: launched, onDisk: executableOnDisk(path))
    }

    static func runs(launched: String?, onDisk: String?) -> Bool {
        launched != nil && onDisk == launched
    }

    /// The executable as launched, kept by `atLaunch`. Nil before, so the Keychain stays shut.
    /// Written once on the main thread before any Keychain call.
    nonisolated(unsafe) private(set) static var launchedExecutable: String?

    /// A new file (another inode) or a rewritten one once an update replaced the app.
    static func executableOnDisk(_ path: String?) -> String? {
        guard let path, let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let file = attributes[.systemFileNumber], let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return "\(file) \(modified.timeIntervalSince1970)"
    }

    /// The build judged as launched, before an update can replace it on disk.
    @MainActor static func atLaunch() {
        _ = isAllowed
        keepLaunchedExecutable()
    }

    @MainActor static func keepLaunchedExecutable(_ path: String? = Bundle.main.executablePath) {
        launchedExecutable = executableOnDisk(path)
    }

    static let sessionCookies = Keychain(service: "app.lithium.browser.session-cookies", account: "file-key",
                                         label: "Lithium sign-in cookies", size: 32)

    /// What builds that may not use the Keychain hand WebKit (`Tab.webCryptoMasterKey`) to wrap the
    /// CryptoKeys sites store, instead of WebKit's own login Keychain item. Theirs are throwaway
    /// profiles: a key for the launch is enough.
    static let launchWebCryptoKey = randomBytes(16)

    /// SecItem calls, so tests never reach the user's Keychain.
    struct Store: Sendable {
        var copy: @Sendable (_ query: [String: Any]) -> (status: OSStatus, data: Data?)
        var add: @Sendable (_ attributes: [String: Any]) -> OSStatus
        var delete: @Sendable (_ query: [String: Any]) -> OSStatus
        var runsCodeOnDisk: @Sendable () -> Bool

        static let login = Store(
            copy: { query in
                var found: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &found)
                return (status, found as? Data)
            },
            add: { SecItemAdd($0 as CFDictionary, nil) },
            delete: { SecItemDelete($0 as CFDictionary) },
            runsCodeOnDisk: { Keychain.runsCodeOnDisk() })
    }

    private enum State {
        case unread, missing, found(Data), unavailable
    }

    private let item: [String: Any]
    private let label: String
    private let size: Int
    private let store: Store
    private let lock = NSLock()
    private var state = State.unread

    init(service: String, account: String, label: String, size: Int, store: Store = .login) {
        item = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        self.label = label
        self.size = size
        self.store = store
    }

    /// `creating` makes one when there is none this build can read. After the first answer the
    /// Keychain isn't asked again this launch, whatever it was.
    func secret(creating: Bool) -> Data? {
        lock.withLock {
            if case .unread = state { state = store.runsCodeOnDisk() ? read() : .unavailable }
            if case .missing = state, creating { state = store.runsCodeOnDisk() ? make() : .unavailable }
            if case .found(let secret) = state { return secret }
            return nil
        }
    }

    private func read() -> State {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let (status, data) = store.copy(query)
        guard status == errSecSuccess, let data, data.count == size else { return .missing }
        return .found(data)
    }

    private func make() -> State {
        let secret = Self.randomBytes(size)
        var added = item
        added[kSecValueData as String] = secret
        added[kSecAttrLabel as String] = label
        var status = store.add(added)
        // One this build can't read (made by another build, access refused, damaged) would
        // otherwise stop every save. Replaced: what it opened is about to be rewritten.
        var deleted = item
        deleted[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        if status == errSecDuplicateItem, store.delete(deleted) == errSecSuccess {
            status = store.add(added)
        }
        return status == errSecSuccess ? .found(secret) : .unavailable
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
