import Foundation
import Observation
import PublicSuffixList
import Security
import WebKit

/// What Lithium knows about the site in a tab: its connection, and the cookies and data it stored.
@MainActor
@Observable
final class SiteInfo {
    struct Certificate: Equatable {
        let subject: String
        let issuer: String
        let validUntil: Date?
    }

    let host: String
    /// The registrable domain (github.com for gist.github.com): cookies and data are grouped by it.
    let site: String
    let isSecure: Bool
    let certificate: Certificate?

    private(set) var cookies: [HTTPCookie] = []
    private(set) var dataKinds: [String] = []
    private(set) var isLoading = true
    private(set) var isClearing = false

    @ObservationIgnored private var records: [WKWebsiteDataRecord] = []
    private let store = WKWebsiteDataStore.default()

    init(url: URL, trust: SecTrust?) {
        host = url.host() ?? ""
        site = Self.registrable(host)
        isSecure = url.scheme == "https" && trust != nil
        certificate = trust.flatMap(Self.certificate)
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
        dataKinds = Set(records.flatMap(\.dataTypes)).compactMap(Self.label).sorted()
        isLoading = false
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

    private static func label(_ type: String) -> String? {
        switch type {
        case WKWebsiteDataTypeCookies: nil
        case WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage: "Local storage"
        case WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases: "Databases"
        case WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache: "Cache"
        case WKWebsiteDataTypeServiceWorkerRegistrations: "Service workers"
        case WKWebsiteDataTypeFileSystem: "Files"
        default: nil
        }
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
