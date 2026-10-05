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

    /// Lithium's pages could turn protections off, an extension's pages hold its UI and data,
    /// and `javascript:`, `data:` and `blob:` documents would run whatever the agent wrote with
    /// the opener's rights or none to check. Only the web and an empty page are left.
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

    /// Opening `url` from `current` scrolls to an anchor of the document shown instead of loading
    /// another: the two differ only in a fragment, which `url` has.
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

    /// Query (and `key=value` fragment) parameters whose values are secrets as often as not:
    /// sign-in links, OAuth redirects, signed downloads.
    private static let secretName = /token|secret|password|passwd|pwd|session|sig|signature|key|code|auth/.ignoresCase()

    /// The address as the log keeps it: no user name or password, and secret-looking parameter
    /// values replaced. Strings that aren't addresses come back unchanged.
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

    /// Every string in a tool's arguments, as the log keeps it.
    static func redacted(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let string): .string(redacted(string))
        case .array(let items): .array(items.map(redacted))
        case .object(let fields): .object(fields.mapValues(redacted))
        default: value
        }
    }

    /// `wait_for`'s URL condition: `/regex/`, or a glob where `*` is any run of characters and
    /// `?` one character, matched against the whole address.
    static func matcher(for pattern: String) throws -> (String) -> Bool {
        if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            let regex = try NSRegularExpression(pattern: String(pattern.dropFirst().dropLast()))
            return { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        }
        let body = pattern.map { character -> String in
            switch character {
            case "*": ".*"
            case "?": "."
            default: NSRegularExpression.escapedPattern(for: String(character))
            }
        }.joined()
        let regex = try NSRegularExpression(pattern: "^\(body)$")
        return { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    }
}
