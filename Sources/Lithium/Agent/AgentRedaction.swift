import Foundation

/// Secrets taken out of what the network log and the console give agents (design section 7.5):
/// header values, fields of JSON and form bodies, card numbers, bearer tokens and JWTs. Pure and
/// off the main actor, since a body can be 256 KB of text.
enum AgentRedaction {
    static let mark = "[redacted]"

    /// Header names whose values are credentials as often as not: `Authorization`,
    /// `Proxy-Authorization`, `Cookie` and `Set-Cookie` among them.
    private static let secretHeader = try! NSRegularExpression(pattern: "auth|token|secret|key|session|cookie|csrf|xsrf|signature", options: .caseInsensitive)
    /// Names of JSON and form fields: the header names', and what passwords and cards are called.
    private static let secretField = try! NSRegularExpression(pattern: "auth|token|secret|key|session|cookie|csrf|xsrf|signature|password|passwd|pwd|card|cvc|cvv|iban", options: .caseInsensitive)

    private static let jsonField = try! NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.){1,100})"\s*:\s*("(?:[^"\\\n]|\\.)*"|-?\d[\d.eE+-]*|true|false)"#)
    /// `name=value` in a form body, a query string, or an address quoted in any text.
    private static let parameter = try! NSRegularExpression(pattern: #"(?:^|(?<=[?&#;\s]))([\w.\-\[\]%]{1,100})=([^&\s"'<>#]+)"#, options: .anchorsMatchLines)
    private static let inputTag = try! NSRegularExpression(pattern: #"<input\b[^>]*>"#, options: .caseInsensitive)
    private static let hiddenOrSecretInput = try! NSRegularExpression(pattern: #"\btype\s*=\s*["']?(password|hidden)|\b(name|id|autocomplete)\s*=\s*["']?[^"'\s>]*(auth|token|secret|key|session|csrf|xsrf|password|passwd|pwd|card|cc-|cvc|cvv|iban)"#, options: .caseInsensitive)
    private static let valueAttribute = try! NSRegularExpression(pattern: #"\bvalue\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, options: .caseInsensitive)
    private static let digits = try! NSRegularExpression(pattern: #"(?<![\d.])\d(?:[ -]?\d){12,18}(?![\d.])"#)
    private static let bearer = try! NSRegularExpression(pattern: #"\b(Bearer|Basic)\s+[A-Za-z0-9\-._~+/]{6,}=*"#, options: .caseInsensitive)
    private static let jwt = try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*"#)
    private static let credentialLine = try! NSRegularExpression(pattern: #"^(\s*(?:proxy-)?authorization|\s*(?:set-)?cookie)[ \t]*:.*$"#, options: [.caseInsensitive, .anchorsMatchLines])

    /// Every value of a secret-looking header is redacted; the others keep their value, with any
    /// address in it (`Location`, `Referer`) written as the log writes addresses.
    @MainActor
    static func headers(_ fields: [AnyHashable: Any]) -> [String: String] {
        var redacted: [String: String] = [:]
        for (name, value) in fields {
            let name = "\(name)"
            redacted[name] = matches(secretHeader, name) ? mark : AgentURLs.redacted("\(value)")
        }
        return redacted
    }

    /// A response body: secret JSON fields, form fields and query parameters, and hidden or
    /// password inputs' values, then what `text` takes out.
    static func body(_ body: String) -> String {
        var body = replacing(jsonField, in: body) { match, text in
            matches(secretField, text.substring(with: match.range(at: 1))) ? replace(match.range(at: 2), in: match, of: text, with: "\"\(mark)\"") : nil
        }
        body = replacing(parameter, in: body) { match, text in
            matches(secretField, text.substring(with: match.range(at: 1))) ? replace(match.range(at: 2), in: match, of: text, with: mark) : nil
        }
        body = replacing(inputTag, in: body) { match, text in
            let tag = text.substring(with: match.range)
            guard matches(hiddenOrSecretInput, tag) else { return nil }
            return replacing(valueAttribute, in: tag) { _, _ in "value=\"\(mark)\"" }
        }
        return text(body)
    }

    /// Any text (a console message, a body): card numbers that pass the Luhn check become
    /// `[card]`; bearer and basic credentials, JWTs, and `Authorization` and cookie lines (an
    /// echoed request, a debug page) lose their values.
    static func text(_ text: String) -> String {
        var text = replacing(digits, in: text) { match, text in
            let number = text.substring(with: match.range).filter(\.isNumber)
            return isLuhn(number) ? "[card]" : nil
        }
        text = replacing(bearer, in: text) { match, text in "\(text.substring(with: match.range(at: 1))) \(mark)" }
        text = replacing(jwt, in: text) { _, _ in mark }
        return replacing(credentialLine, in: text) { match, text in "\(text.substring(with: match.range(at: 1))): \(mark)" }
    }

    /// Each value (a cookie's) wherever it shows in `text`. Short ones would match by chance.
    static func scrubbing(_ values: [String], in text: String) -> String {
        values.filter { $0.count >= 6 }.reduce(text) { $0.replacingOccurrences(of: $1, with: mark) }
    }

    static func isLuhn(_ number: String) -> Bool {
        guard (13...19).contains(number.count) else { return false }
        var sum = 0
        for (index, character) in number.reversed().enumerated() {
            guard var digit = character.wholeNumberValue else { return false }
            if index % 2 == 1 {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
        }
        return sum % 10 == 0
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The match's text with `range` (inside it) swapped for `replacement`.
    private static func replace(_ range: NSRange, in match: NSTextCheckingResult, of text: NSString, with replacement: String) -> String {
        let whole = match.range
        let before = text.substring(with: NSRange(location: whole.location, length: range.location - whole.location))
        let after = text.substring(with: NSRange(location: NSMaxRange(range), length: NSMaxRange(whole) - NSMaxRange(range)))
        return before + replacement + after
    }

    /// Each match replaced by what `replacement` makes of it; nil leaves it as it is.
    private static func replacing(_ expression: NSRegularExpression, in text: String, _ replacement: (NSTextCheckingResult, NSString) -> String?) -> String {
        let source = text as NSString
        var output = ""
        var last = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let replaced = replacement(match, source) else { continue }
            output += source.substring(with: NSRange(location: last, length: match.range.location - last)) + replaced
            last = NSMaxRange(match.range)
        }
        guard last > 0 else { return text }
        return output + source.substring(from: last)
    }
}
