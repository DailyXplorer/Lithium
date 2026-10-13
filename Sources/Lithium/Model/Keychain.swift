import Foundation
import Security

/// One secret Lithium keeps in the login Keychain, read at most once a launch and never with a
/// prompt: one this build can't read without the user's password (macOS ties an item to the build
/// that made it when the app has no team ID, so an update can't read it) is replaced instead.
final class Keychain: @unchecked Sendable {
    /// Only the installed app, signed with its own identity, uses the user's Keychain. Any other
    /// build (debug, ad-hoc signed, a test run, a throwaway home) would read the same items as
    /// another app, and the answer to its prompt changes who may read them: the real app gets asked
    /// next. Those builds keep their secrets in memory.
    @MainActor static let isAllowed: Bool = {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return allows(isDebug: isDebug, runsTests: ExternalApps.runsTests,
                      environment: ProcessInfo.processInfo.environment, bundle: Bundle.main.bundleURL)
    }()

    static func allows(isDebug: Bool, runsTests: Bool, environment: [String: String], bundle: URL) -> Bool {
        !isDebug && !runsTests && environment["CFFIXED_USER_HOME"] == nil && bundle.pathExtension == "app" && hasSigningIdentity(bundle)
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

    /// Process-wide, so WebKit's own Keychain reads in this process fail rather than ask too.
    /// Keychain calls then return errSecInteractionNotAllowed where they would show a prompt.
    @MainActor static func turnOffPrompts() {
        SecKeychainSetUserInteractionAllowed(false)
    }

    static let sessionCookies = Keychain(service: "app.lithium.browser.session-cookies", account: "file-key",
                                         label: "Lithium sign-in cookies", size: 32)

    /// Wraps the CryptoKeys sites store (IndexedDB). Lithium hands it to WebKit
    /// (`Tab.webCryptoMasterKey`), whose own item would ask for the password after every update.
    static let webCrypto = Keychain(service: "app.lithium.browser.webcrypto", account: "master-key",
                                    label: "Lithium WebCrypto key", size: 16)

    /// Where the Keychain is off or fails: WebKit would otherwise fall back to its own item.
    static let launchWebCryptoKey = randomBytes(16)

    static func webCryptoKey(allowed: Bool) -> Data {
        (allowed ? webCrypto.secret(creating: true) : nil) ?? launchWebCryptoKey
    }

    /// SecItem calls, so tests never reach the user's Keychain.
    struct Store: Sendable {
        var copy: @Sendable (_ query: [String: Any]) -> (status: OSStatus, data: Data?)
        var add: @Sendable (_ attributes: [String: Any]) -> OSStatus
        var delete: @Sendable (_ query: [String: Any]) -> OSStatus

        static let login = Store(
            copy: { query in
                var found: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &found)
                return (status, found as? Data)
            },
            add: { SecItemAdd($0 as CFDictionary, nil) },
            delete: { SecItemDelete($0 as CFDictionary) })
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
            if case .unread = state { state = read() }
            if case .missing = state, creating { state = make() }
            if case .found(let secret) = state { return secret }
            return nil
        }
    }

    private func read() -> State {
        var query = item
        query[kSecReturnData as String] = true
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
        if status == errSecDuplicateItem, store.delete(item) == errSecSuccess {
            status = store.add(added)
        }
        return status == errSecSuccess ? .found(secret) : .unavailable
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
