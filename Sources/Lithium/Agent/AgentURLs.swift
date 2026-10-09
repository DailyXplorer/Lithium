import Foundation

/// Which addresses an agent may open, and how addresses are written into the action log.
@MainActor
enum AgentURLs {
    enum Verdict: Equatable {
        case allowed
        /// `file:` URLs give a page read access to their folder, so the user allows each one.
        case needsConfirmation
        case blocked(String)
    }

    /// Lithium's pages could turn protections off, extension pages hold their data, and
    /// `javascript:`, `data:` and `blob:` would run agent-written code. Only the web and about:blank are left.
    static func verdict(for url: URL) -> Verdict {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return url.host()?.isEmpty == false ? .allowed : .blocked("\(url.absoluteString) has no host.")
        case "about":
            return url.absoluteString.lowercased() == "about:blank" ? .allowed : .blocked("Only about:blank is open to agents.")
        case "file":
            return .needsConfirmation
        case Internal.scheme:
            return .blocked("Lithium’s own pages are out of reach for agents.")
        case Extensions.scheme:
            return .blocked("Extension pages are out of reach for agents.")
        case let scheme?:
            return .blocked("\(scheme): addresses are out of reach for agents. Open an http or https address.")
        case nil:
            return .blocked("\(url.absoluteString) is not a full address. Include https://.")
        }
    }

    /// The two differ only in a fragment, which `url` has: opening it scrolls instead of loading.
    static func isMoveWithinPage(from current: URL?, to url: URL) -> Bool {
        guard let current, url.fragment != nil else { return false }
        return withoutFragment(current) == withoutFragment(url)
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host()?.lowercased() == b.host()?.lowercased() && a.port == b.port
    }

    private static func withoutFragment(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    /// A tab showing one of these can't be read or driven, though it can be listed, selected and closed.
    static func isBlocked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return [Internal.scheme, Extensions.scheme].contains(url.scheme?.lowercased())
    }

    private static let secretName = /token|secret|password|passwd|pwd|session|sig|signature|key|code|auth/.ignoresCase()

    /// No user name or password, and secret-looking parameter values replaced. Non-addresses come back unchanged.
    static func redacted(_ string: String) -> String {
        guard string.contains(":"), var parts = URLComponents(string: string), parts.scheme != nil else { return string }
        guard parts.user != nil || parts.password != nil || parts.percentEncodedQuery != nil || parts.percentEncodedFragment != nil else { return string }
        let query = parts.percentEncodedQuery
        let fragment = parts.percentEncodedFragment
        parts.user = nil
        parts.password = nil
        // Put back by hand: URLComponents refuses the brackets of "[redacted]" in a query.
        parts.percentEncodedQuery = nil
        parts.percentEncodedFragment = nil
        guard var redacted = parts.string else { return string }
        if let query { redacted += "?" + redactedParameters(query) }
        if let fragment { redacted += "#" + (fragment.contains("=") ? redactedParameters(fragment) : fragment) }
        return redacted
    }

    private static func redactedParameters(_ encoded: String) -> String {
        encoded.split(separator: "&", omittingEmptySubsequences: false).map { pair in
            guard let equals = pair.firstIndex(of: "=") else { return String(pair) }
            let name = pair[..<equals]
            let decoded = name.removingPercentEncoding ?? String(name)
            return decoded.contains(secretName) ? "\(name)=[redacted]" : String(pair)
        }.joined(separator: "&")
    }

    static func redacted(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let string): .string(redacted(string))
        case .array(let items): .array(items.map(redacted))
        case .object(let fields): .object(fields.mapValues(redacted))
        default: value
        }
    }

    /// `wait_for`'s URL glob (`*`, `?`) against the whole address. Nil for a `/regex/`: one can
    /// backtrack for minutes on the main thread, where nothing can interrupt it.
    static func matcher(for pattern: String) -> ((String) -> Bool)? {
        if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") { return nil }
        let pattern = Array(pattern)
        return { globMatches(pattern, Array($0)) }
    }

    /// Two pointers that go back only to the last `*`: at most pattern × text steps.
    private static func globMatches(_ pattern: [Character], _ text: [Character]) -> Bool {
        var (p, t) = (0, 0)
        var lastStar: (pattern: Int, text: Int)?
        while t < text.count {
            if p < pattern.count, pattern[p] == "*" {
                lastStar = (p, t)
                p += 1
            } else if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                p += 1
                t += 1
            } else if let star = lastStar {
                lastStar = (star.pattern, star.text + 1)
                (p, t) = (star.pattern + 1, star.text + 1)
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
