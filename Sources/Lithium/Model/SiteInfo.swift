import Foundation
import Observation
import PublicSuffixList
import Security
import WebKit

/// What Lithium knows about a site: its connection, and the cookies and data it stored.
@MainActor
@Observable
final class SiteInfo {
    struct Certificate: Equatable {
        let subject: String
        let issuer: String
        let validUntil: Date?
    }

    enum CertificateLookup: Equatable {
        case loading, found(Certificate), unavailable
    }

    enum Connection: Equatable {
        case secure, notEncrypted, certificateNotValid, notLoaded

        /// WebKit shows an https page only once its certificate checks out. `serverTrust` can't tell:
        /// it is nil for a page a service worker answered, or over a connection already open.
        /// Lithium's error page keeps the address that failed, https or not: the error decides.
        init(url: URL?, loadError: NSError?) {
            if let loadError {
                let isCertificate = loadError.domain == NSURLErrorDomain
                    && (NSURLErrorClientCertificateRequired...NSURLErrorSecureConnectionFailed).contains(loadError.code)
                self = isCertificate ? .certificateNotValid : .notLoaded
            } else {
                self = url?.scheme?.lowercased() == "https" ? .secure : .notEncrypted
            }
        }

        var reason: String {
            switch self {
            case .secure: ""
            case .notEncrypted: "Connection isn’t encrypted"
            case .certificateNotValid: "Certificate not valid"
            case .notLoaded: "Page didn’t load"
            }
        }
    }

    let host: String
    /// The registrable domain (github.com for gist.github.com): cookies and data are grouped by it.
    let site: String
    let connection: Connection
    private(set) var certificate = CertificateLookup.loading
    @ObservationIgnored private var certificateURL: URL?
    @ObservationIgnored var fetchTrust: (URL) async -> SecTrust? = SiteInfo.fetchTrust

    private(set) var cookieCount: Int?
    private(set) var hasData = false
    private(set) var isClearing = false

    @ObservationIgnored private var cookies: [HTTPCookie] = []
    @ObservationIgnored private var records: [WKWebsiteDataRecord] = []
    /// The tab's own: a private tab's panel never reads or clears the user's store.
    private let store: WKWebsiteDataStore

    init(host: String, connection: Connection = .secure, store: WKWebsiteDataStore = .default()) {
        self.host = host
        site = Self.registrable(host)
        self.connection = connection
        self.store = store
    }

    convenience init(url: URL, loadError: NSError? = nil, store: WKWebsiteDataStore = .default()) {
        self.init(host: url.host() ?? "", connection: Connection(url: url, loadError: loadError), store: store)
        certificateURL = Self.certificateURL(for: url)
    }

    nonisolated static func certificateURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host?.isEmpty == false else { return nil }
        components.user = nil
        components.password = nil
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// An IP address is a site of its own (brackets dropped): the suffix list would take its last
    /// label for a TLD and group `192.168.0.1` with `10.0.0.1` as "0.1".
    nonisolated static func registrable(_ host: String) -> String {
        let host = host.lowercased()
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var address = in6_addr()
        if bare.contains(":") ? inet_pton(AF_INET6, bare, &address) == 1 : inet_pton(AF_INET, bare, &address) == 1 { return bare }
        return PublicSuffixList.effectiveTLDPlusOne(host) ?? host
    }

    func load() async {
        let site = site
        let allCookies = await store.httpCookieStore.allCookies()
        cookies = allCookies.filter { Self.registrable($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == site }
        records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            .filter { Self.registrable($0.displayName) == site }
        cookieCount = cookies.count
        hasData = !cookies.isEmpty || !records.isEmpty
    }

    /// Before a clear that waits its turn (`Browser.clearData`): the button stops at the click.
    func willClear() {
        isClearing = true
    }

    func clear() async {
        isClearing = true
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        for cookie in cookies {
            await store.httpCookieStore.deleteCookie(cookie)
        }
        isClearing = false
        await load()
    }

    /// From the web view's trust, else asked of the site over a new connection, without cookies.
    func loadCertificate(trust: SecTrust?) async {
        guard connection == .secure, certificate == .loading else { return }
        var trust = trust
        if trust == nil, let certificateURL {
            trust = await fetchTrust(certificateURL)
            // Closed before the answer: still to load, so opening the certificate again asks again.
            guard !Task.isCancelled else { return }
        }
        let found = if let trust { await Self.certificateInBackground(from: SharedTrust(trust: trust)) } else { Certificate?.none }
        certificate = found.map(CertificateLookup.found) ?? .unavailable
    }

    /// Only read once handed over; SecTrust is thread-safe, but not marked Sendable.
    private struct SharedTrust: @unchecked Sendable {
        let trust: SecTrust
    }

    /// Reading the chain has the Security framework evaluate a trust nothing evaluated yet, which
    /// can wait on the network (revocation, a missing intermediate): never on the main thread.
    private nonisolated static func certificateInBackground(from shared: SharedTrust) async -> Certificate? {
        certificate(from: shared.trust)
    }

    private nonisolated static func fetchTrust(_ url: URL) async -> SecTrust? {
        let catcher = TrustCatcher()
        let session = URLSession(configuration: .ephemeral, delegate: catcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        _ = try? await session.data(for: request)
        return catcher.trust
    }

    private nonisolated static func certificate(from trust: SecTrust) -> Certificate? {
        assert(!Thread.isMainThread, "Security evaluates the trust here, which may block")
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let subject = SecCertificateCopySubjectSummary(leaf) as String? ?? ""
        let issuer = chain.count > 1 ? (SecCertificateCopySubjectSummary(chain[1]) as String? ?? "") : subject
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        let values = SecCertificateCopyValues(leaf, keys, nil) as? [String: [String: Any]]
        let notAfter = (values?[kSecOIDX509V1ValidityNotAfter as String]?[kSecPropertyKeyValue as String] as? NSNumber)
            .map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
        return Certificate(subject: subject, issuer: issuer, validUntil: notAfter)
    }
}

/// Redirects are not followed: another host's certificate isn't this site's.
private final class TrustCatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private(set) var trust: SecTrust?

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, trust == nil {
            trust = challenge.protectionSpace.serverTrust
        }
        return (.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
