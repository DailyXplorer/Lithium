import Foundation
import PublicSuffixList

enum SearchEngine: String, CaseIterable, Identifiable {
    case brave, duckDuckGo, google, kagi, ecosia, startpage

    var id: Self { self }
    static let preferenceKey = "searchEngine"

    static var current: SearchEngine {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(SearchEngine.init(rawValue:)) ?? .brave
    }

    var name: String {
        switch self {
        case .brave: "Brave Search"
        case .duckDuckGo: "DuckDuckGo"
        case .google: "Google"
        case .kagi: "Kagi"
        case .ecosia: "Ecosia"
        case .startpage: "Startpage"
        }
    }

    var home: URL {
        switch self {
        case .brave: URL(string: "https://search.brave.com/")!
        case .duckDuckGo: URL(string: "https://duckduckgo.com/")!
        case .google: URL(string: "https://www.google.com/")!
        case .kagi: URL(string: "https://kagi.com/")!
        case .ecosia: URL(string: "https://www.ecosia.org/")!
        case .startpage: URL(string: "https://www.startpage.com/")!
        }
    }

    func url(searching query: String) -> URL {
        let path = switch self {
        case .brave: "https://search.brave.com/search"
        case .duckDuckGo: "https://duckduckgo.com/"
        case .google: "https://www.google.com/search"
        case .kagi: "https://kagi.com/search"
        case .ecosia: "https://www.ecosia.org/search"
        case .startpage: "https://www.startpage.com/do/search"
        }
        var components = URLComponents(string: path)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        // URLComponents leaves "+" as is, and search engines read it as a space: "c++" would search "c".
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

enum AddressInput {
    enum Target: Equatable {
        case address(URL)
        case search(String)
    }

    /// Whether typed text is an address to open or words to search for.
    static func target(for rawInput: String) -> Target? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let url = URL(string: input), let scheme = url.scheme?.lowercased() {
            if ["http", "https"].contains(scheme), url.host() != nil { return .address(url) }
            if ["about", "file", "data", Internal.scheme].contains(scheme) { return .address(url) }
            // Handed to Mail by the browser. Read as `http://` below, "mailto:alice@…" would open
            // a website with the typed text as its credentials.
            if scheme == "mailto" { return .address(url) }
        }

        // "alice@example.com" would open example.com with "alice" as its login: an email
        // address, like "user:password@host", is searched instead.
        if !input.contains(" "), let url = URL(string: "http://" + input), let host = url.host(), url.user == nil, url.password == nil {
            if host == "localhost" || isIPAddress(host) {
                return .address(url)
            }
            // A port alone doesn't make an address: "10:30" and "john3:16" are searches.
            if looksLikeDomain(host) {
                if url.port != nil { return .address(url) }
                if let secure = URL(string: "https://" + input) { return .address(secure) }
            }
        }
        return .search(input)
    }

    static func url(for rawInput: String, engine: SearchEngine = .current) -> URL? {
        switch target(for: rawInput) {
        case .address(let url): url
        case .search(let query): engine.url(searching: query)
        case nil: nil
        }
    }

    /// Names that aren't public suffixes but are used on local networks ("mac-mini.local", "router.lan").
    private static let localSuffixes: Set<String> = ["local", "localhost", "internal", "lan", "home", "test"]

    /// A host ending in a real suffix, so "node.js" and "config.json" stay searches. The suffix list
    /// answers with the bare last label, not marked ICANN, for a suffix it doesn't know.
    private static func looksLikeDomain(_ host: String) -> Bool {
        let host = host.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let tld = labels.last else { return false }
        if localSuffixes.contains(String(tld)) { return true }
        guard let (suffix, icann) = PublicSuffixList.parsePublicSuffix(host) else { return false }
        return icann || suffix.contains(".")
    }

    /// Dotted IPv4, or IPv6 typed in brackets (`[::1]`), which Foundation may hand back without them.
    private static func isIPAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return true }
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var address = in6_addr()
        return bare.contains(":") && inet_pton(AF_INET6, bare, &address) == 1
    }
}
