import ContentBlockerConverter
import Foundation

/// Downloads the filter lists named in FilterSources.json and compiles them with AdGuard's
/// converter, producing the same folder layout as scripts/update-filters.py:
/// one WebKit JSON per group, advanced.txt for the in-page engine, scriptlets.txt for uBO's
/// `+js()` filters (run by uBO's own scriptlets, not converted), and manifest.json.
struct FilterUpdater: Sendable {
    struct Sources: Decodable, Sendable {
        let lists: [String: URL]
        let groups: [String: [String]]
        let trueTokens: Set<String>

        /// Whether `manifest` was built from these groups and lists. A folder downloaded before a
        /// list was added lacks it until refreshed, however recent it is.
        func built(_ manifest: Manifest) -> Bool {
            groups == manifest.groups.compactMapValues(\.lists)
        }
    }

    let sources: Sources
    var session: URLSession = .shared

    static func bundled() -> FilterUpdater? {
        guard let url = Resources.bundle.url(forResource: "FilterSources", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let sources = try? JSONDecoder().decode(Sources.self, from: data) else { return nil }
        return FilterUpdater(sources: sources)
    }

    /// Builds a complete filter folder in a temporary location, then swaps it into `destination`,
    /// so a failed or interrupted update never leaves a half-written set behind.
    func update(into destination: URL) async throws {
        var downloaded: [String: [String]] = [:]
        for name in Set(sources.groups.values.joined()) {
            guard let url = sources.lists[name] else { continue }
            var seen: Set<URL> = []
            downloaded[name] = try await expand(url, seen: &seen)
        }

        let staging = destination.deletingLastPathComponent().appending(path: ".filters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var groups: [String: Manifest.Group] = [:]
        var advanced: [String] = []
        var scriptlets: [String] = []
        for (group, names) in sources.groups {
            var unique = Set<String>()
            var rules: [String] = []
            for name in names {
                for rule in downloaded[name] ?? [] where unique.insert(rule).inserted {
                    if Self.isUBOScriptlet(rule, list: name) { scriptlets.append(rule) } else { rules.append(rule) }
                }
            }
            let result = ContentBlockerConverter().convertArray(rules: rules, safariVersion: .autodetect(), advancedBlocking: true)
            try result.safariRulesJSON.write(to: staging.appending(path: "\(group).json"), atomically: false, encoding: .utf8)
            advanced += (result.advancedRulesText ?? "").split(separator: "\n").map(String.init)
            groups[group] = Manifest.Group(lists: names, sourceRules: result.sourceRulesCount, webkitRules: result.safariRulesCount)
        }
        var uniqueAdvanced = Set<String>()
        advanced = advanced.filter { uniqueAdvanced.insert($0).inserted }
        try (advanced.joined(separator: "\n") + "\n").write(to: staging.appending(path: "advanced.txt"), atomically: false, encoding: .utf8)
        var uniqueScriptlets = Set<String>()
        scriptlets = scriptlets.filter { uniqueScriptlets.insert($0).inserted }
        try (scriptlets.joined(separator: "\n") + "\n").write(to: staging.appending(path: "scriptlets.txt"), atomically: false, encoding: .utf8)

        let manifest = Manifest(
            format: Manifest.currentFormat,
            updated: ISO8601DateFormatter().string(from: Date()),
            groups: groups,
            advancedRules: advanced.count,
            scriptletRules: scriptlets.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appending(path: "manifest.json"))

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }

    /// A uBO `+js()` filter from one of uBO's own lists, the only ones trusted with its `trusted-` scriptlets.
    static func isUBOScriptlet(_ rule: String, list: String) -> Bool {
        list.hasPrefix("ubo-") && (rule.contains("##+js(") || rule.contains("#@#+js("))
    }

    private func expand(_ url: URL, seen: inout Set<URL>) async throws -> [String] {
        guard seen.insert(url).inserted else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Lithium-filter-updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { throw URLError(.badServerResponse) }

        var lines: [String] = []
        var conditions: [Bool] = []
        for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("!#if ") {
                conditions.append(Self.evaluate(String(line.dropFirst(5)), trueTokens: sources.trueTokens))
            } else if line == "!#else", !conditions.isEmpty {
                conditions[conditions.count - 1].toggle()
            } else if line == "!#endif", !conditions.isEmpty {
                conditions.removeLast()
            } else if conditions.contains(false) {
                continue
            } else if line.hasPrefix("!#include ") {
                let path = line.dropFirst(10).trimmingCharacters(in: .whitespaces)
                if let included = URL(string: path, relativeTo: url)?.absoluteURL {
                    lines += try await expand(included, seen: &seen)
                }
            } else if !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[Adblock") {
                lines.append(line)
            }
        }
        return lines
    }

    /// Evaluates a uBO preprocessor condition such as `env_safari && !ext_ubol || (cap_x)`.
    static func evaluate(_ expression: String, trueTokens: Set<String>) -> Bool {
        var tokens: [String] = []
        var index = expression.startIndex
        while index < expression.endIndex {
            let character = expression[index]
            if character.isWhitespace {
                index = expression.index(after: index)
            } else if "()!".contains(character) {
                tokens.append(String(character))
                index = expression.index(after: index)
            } else if expression[index...].hasPrefix("&&") || expression[index...].hasPrefix("||") {
                tokens.append(String(expression[index..<expression.index(index, offsetBy: 2)]))
                index = expression.index(index, offsetBy: 2)
            } else {
                let end = expression[index...].firstIndex { !($0.isLetter || $0.isNumber || $0 == "_") } ?? expression.endIndex
                guard end > index else { return false }
                tokens.append(String(expression[index..<end]))
                index = end
            }
        }

        var position = 0
        func primary() -> Bool {
            guard position < tokens.count else { return false }
            let token = tokens[position]
            position += 1
            switch token {
            case "!": return !primary()
            case "(":
                let value = or()
                if position < tokens.count, tokens[position] == ")" { position += 1 }
                return value
            default: return trueTokens.contains(token)
            }
        }
        func and() -> Bool {
            var value = primary()
            while position < tokens.count, tokens[position] == "&&" {
                position += 1
                value = primary() && value
            }
            return value
        }
        func or() -> Bool {
            var value = and()
            while position < tokens.count, tokens[position] == "||" {
                position += 1
                value = and() || value
            }
            return value
        }
        return or()
    }
}

struct Manifest: Codable {
    struct Group: Codable {
        var lists: [String]? = nil
        var sourceRules: Int? = nil
        let webkitRules: Int
    }
    /// 2: uBO's `+js()` filters live apart in scriptlets.txt. Older folders are ignored.
    static let currentFormat = 2
    var format: Int? = nil
    let updated: String
    let groups: [String: Group]
    let advancedRules: Int?
    var scriptletRules: Int? = nil

    var date: Date? { ISO8601DateFormatter().date(from: updated) }
}
