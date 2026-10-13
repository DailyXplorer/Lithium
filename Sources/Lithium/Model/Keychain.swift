import Foundation
import Security

/// One secret Lithium keeps in the login Keychain, read at most once a launch and never with a
/// prompt. No explicit `kSecAttrAccess`: the default one already trusts the app by its designated
/// requirement. What an update can still fail on is the item's partition list, which names the
/// build (its cdhash) when the app has no team ID, and only the user's password changes that. One
/// this build can't read without it is replaced instead.
final class Keychain: @unchecked Sendable {
    /// Only the installed app, signed with its own identity, uses the user's Keychain. Any other
    /// build (debug, ad-hoc signed, a test run, a throwaway home) would read the same items as
    /// another app, and the answer to its prompt changes who may read them: the real app gets asked
    /// next. Those builds keep their secrets in memory. Decided at launch (`atLaunch`), on the app
    /// as it was then: a bundle replaced on disk later doesn't change the answer.
    @MainActor static let isAllowed: Bool = {
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
    static func runsCodeOnDisk() -> Bool {
        runs(launched: launchedExecutable, onDisk: executableOnDisk())
    }

    static func runs(launched: String?, onDisk: String?) -> Bool {
        launched != nil && onDisk == launched
    }

    static let launchedExecutable = executableOnDisk()

    /// A new file (another inode) or a rewritten one once an update replaced the app.
    private static func executableOnDisk() -> String? {
        guard let path = Bundle.main.executablePath, let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let file = attributes[.systemFileNumber], let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return "\(file) \(modified.timeIntervalSince1970)"
    }

    /// Prompts off process-wide, so WebKit's own Keychain reads in this process fail rather than
    /// ask too: Keychain calls then return errSecInteractionNotAllowed where they would show one.
    /// And the build judged as launched, before an update can replace it on disk.
    @MainActor static func atLaunch() {
        SecKeychainSetUserInteractionAllowed(false)
        _ = (isAllowed, launchedExecutable)
    }

    static let sessionCookies = Keychain(service: "app.lithium.browser.session-cookies", account: "file-key",
                                         label: "Lithium sign-in cookies", size: 32)

    /// Wraps the CryptoKeys sites store (IndexedDB). Lithium hands it to WebKit
    /// (`Tab.webCryptoMasterKey`), whose own item would ask for the password after every update.
    static let webCrypto = Keychain(service: "app.lithium.browser.webcrypto", account: "master-key",
                                    label: "Lithium WebCrypto key", size: 16)

    /// Where the Keychain is off or fails: WebKit would otherwise fall back to its own item.
    static let launchWebCryptoKey = randomBytes(16)

    static func webCryptoKey(allowed: Bool, keychain: Keychain = webCrypto) -> Data {
        (allowed ? keychain.secret(creating: true) : nil) ?? launchWebCryptoKey
    }

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
            runsCodeOnDisk: Keychain.runsCodeOnDisk)
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
