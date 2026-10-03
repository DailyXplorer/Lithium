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

    /// What the lock in the address bar and the panel say of the page shown.
    enum Connection: Equatable {
        case secure, notEncrypted, certificateNotValid, notLoaded

        /// WebKit shows an https page only once its certificate checks out, and Lithium never
        /// accepts one that doesn't. The web view's `serverTrust` can't tell: it is nil for a page a
        /// service worker answered, or that came over a connection already open (youtube.com).
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
    /// Where the certificate is asked for when the web view has none: the page's server.
    @ObservationIgnored private var certificateURL: URL?
    @ObservationIgnored var fetchTrust: (URL) async -> SecTrust? = SiteInfo.fetchTrust

    private(set) var cookieCount: Int?
    private(set) var hasData = false
    private(set) var isClearing = false

    @ObservationIgnored private var cookies: [HTTPCookie] = []
    @ObservationIgnored private var records: [WKWebsiteDataRecord] = []
    private let store = WKWebsiteDataStore.default()

    init(host: String, connection: Connection = .secure) {
        self.host = host
        site = Self.registrable(host)
        self.connection = connection
    }

    convenience init(url: URL, loadError: NSError? = nil) {
        self.init(host: url.host() ?? "", connection: Connection(url: url, loadError: loadError))
        certificateURL = Self.certificateURL(for: url)
    }

    /// The page's server (scheme, host and port) without the rest of its address.
    nonisolated static func certificateURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host?.isEmpty == false else { return nil }
        components.user = nil
        components.password = nil
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    nonisolated static func registrable(_ host: String) -> String {
        PublicSuffixList.effectiveTLDPlusOne(host.lowercased()) ?? host.lowercased()
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

    /// Removes every cookie and piece of storage of the site (all its subdomains).
    func clear() async {
        isClearing = true
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        for cookie in cookies {
            await store.httpCookieStore.deleteCookie(cookie)
        }
        isClearing = false
        await load()
    }

    /// The certificate of the page shown, from its web view's trust; when the web view has none
    /// to give, asked of the site over a new connection, without cookies.
    func loadCertificate(trust: SecTrust?) async {
        guard connection == .secure, certificate == .loading else { return }
        var trust = trust
        if trust == nil, let certificateURL {
            trust = await fetchTrust(certificateURL)
            // Closed before the answer: still to load, so opening the certificate again asks again.
            guard !Task.isCancelled else { return }
        }
        certificate = trust.flatMap(Self.certificate).map(CertificateLookup.found) ?? .unavailable
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

    private static func certificate(from trust: SecTrust) -> Certificate? {
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

/// Keeps the trust the server presented, and lets the system judge it as usual. Redirects are
/// not followed: the root of a site can redirect to another host, whose certificate isn't this one's.
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
