import ContentBlockerConverter
import CryptoKit
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
        /// The SHA-256 of FilterSources.json, which scripts/update-filters.py writes too: a list's
        /// new address or a changed token changes no group, and would wait for the next update.
        var digest: String? = nil

        /// Whether `manifest` was built from these groups and lists. A folder downloaded before a
        /// list was added lacks it until refreshed, however recent it is.
        func built(_ manifest: Manifest) -> Bool {
            groups == manifest.groups.compactMapValues(\.lists) && (digest == nil || manifest.sources == digest)
        }
    }

    let sources: Sources
    var session: URLSession = .shared
    /// The set shipped with the app, whose `lists/` copies stand in for a failing list the
    /// downloaded set doesn't hold yet (the first update after installing or upgrading).
    var bundledFilters: URL? = Resources.bundle.url(forResource: "Filters", withExtension: nil)
    /// Rules a download needs to count as a list; the smallest real one holds well over this.
    var minimumRules = 10

    static func bundled() -> FilterUpdater? {
        guard let url = Resources.bundle.url(forResource: "FilterSources", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              var sources = try? JSONDecoder().decode(Sources.self, from: data) else { return nil }
        sources.digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return FilterUpdater(sources: sources)
    }

    /// Builds a complete filter folder in a temporary location, then swaps it into `destination`,
    /// so a failed or interrupted update never leaves a half-written set behind.
    /// A list that fails to download (a dead server, an error page, an empty or HTML body)
    /// doesn't hold back the others:
    /// it keeps the last good copy the newer of the folder and the bundled set holds for it (after
    /// an upgrade, the bundled one), and is named in the manifest's `failedLists`. When every list
    /// fails, or a failing one has no copy at all, nothing is written and the error thrown, so the
    /// current set keeps that list's rules.
    func update(into destination: URL) async throws {
        Self.removeAbandonedStaging(beside: destination)
        var downloaded: [String: [String]] = [:]
        var failed: [String] = []
        var lastError: Error?
        let names = Set(sources.groups.values.joined()).filter { sources.lists[$0] != nil }
        for name in names.sorted() {
            guard let url = sources.lists[name] else { continue }
            do {
                var seen: Set<URL> = []
                let lines = try await expand(url, seen: &seen)
                // A captive portal, a parked domain or an emptied file answers 200 too: anything
                // that doesn't look like a filter list fails, so it never replaces the last good copy.
                guard lines.count >= minimumRules else { throw URLError(.cannotParseResponse) }
                downloaded[name] = lines
            } catch {
                NSLog("Lithium: filter list %@ failed to download: %@", name, error.localizedDescription)
                failed.append(name)
                lastError = error
                let copy = Self.newestFirst([destination, bundledFilters].compactMap { $0 }).lazy
                    .compactMap { try? String(contentsOf: Self.copy(of: name, in: $0), encoding: .utf8) }.first
                guard let copy else { throw error }
                downloaded[name] = copy.split(separator: "\n").map(String.init)
            }
        }
        if let lastError, failed.count == names.count { throw lastError }

        let staging = destination.deletingLastPathComponent().appending(path: ".filters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging.appending(path: "lists"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (name, lines) in downloaded {
            try lines.joined(separator: "\n").write(to: Self.copy(of: name, in: staging), atomically: false, encoding: .utf8)
        }

        var groups: [String: Manifest.Group] = [:]
        var advanced: [String] = []
        var scriptlets: [String] = []
        for (group, names) in sources.groups {
            var unique = Set<String>()
            var rules: [String] = []
            for name in names {
                for rule in downloaded[name] ?? [] where Self.isAllowed(rule, list: name) && unique.insert(rule).inserted {
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
            scriptletRules: scriptlets.count,
            failedLists: failed.isEmpty ? nil : failed,
            sources: sources.digest
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

    /// Quitting during an update ends it before its `defer` removes the staging folder. One left
    /// untouched for a day is such an update's, not one under way, and goes, as AdvancedBlocking's do.
    static func removeAbandonedStaging(beside destination: URL) {
        let folder = destination.deletingLastPathComponent()
        let others = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for other in others where other.lastPathComponent.hasPrefix(".filters-") {
            guard let modified = try? other.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(modified) >= 24 * 60 * 60 else { continue }
            try? FileManager.default.removeItem(at: other)
        }
    }

    /// A uBO `+js()` filter from one of uBO's own lists, the only ones trusted with its `trusted-` scriptlets.
    static func isUBOScriptlet(_ rule: String, list: String) -> Bool {
        list.hasPrefix("ubo-") && (rule.contains("##+js(") || rule.contains("#@#+js("))
    }

    /// Rules that run code in every matching page (uBO's `+js()`, AdGuard's `#%#` scriptlets and
    /// JavaScript, and their exceptions) come only from uBO's own lists. The in-page engine can't
    /// tell which list a rule came from, so another list's would run as trusted as uBO's.
    static func isAllowed(_ rule: String, list: String) -> Bool {
        list.hasPrefix("ubo-") || !(rule.contains("+js(") || rule.contains("#%#") || rule.contains("#@%#"))
    }

    /// Where a filter folder keeps a list as last downloaded, for when it next fails.
    private static func copy(of list: String, in folder: URL) -> URL {
        folder.appending(path: "lists/\(list).txt")
    }

    /// Filter folders, the one with the newest manifest first, as the app picks the set it loads;
    /// in the order given when their dates are equal.
    static func newestFirst(_ folders: [URL], now: Date = Date()) -> [URL] {
        let dates = folders.map { Manifest.read(in: $0)?.comparableDate(now: now) ?? .distantPast }
        return folders.indices.sorted { dates[$0] != dates[$1] ? dates[$0] > dates[$1] : $0 < $1 }.map { folders[$0] }
    }

    private func expand(_ url: URL, seen: inout Set<URL>) async throws -> [String] {
        guard seen.insert(url).inserted else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Lithium-filter-updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { throw URLError(.badServerResponse) }
        // An HTML page (an error or login page served with 200) would parse into junk rules.
        let body = String(decoding: data, as: UTF8.self)
        if body.first(where: { !$0.isWhitespace && $0 != "\u{FEFF}" }) == "<" { throw URLError(.cannotParseResponse) }

        var lines: [String] = []
        var conditions: [Bool] = []
        for raw in body.split(whereSeparator: \.isNewline) {
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
                // Only from the list's own server: an include elsewhere (another site, a file on
                // the Mac) is skipped.
                if let included = URL(string: path, relativeTo: url)?.absoluteURL,
                   included.scheme?.lowercased() == url.scheme?.lowercased(),
                   included.host()?.lowercased() == url.host()?.lowercased(), included.port == url.port {
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
    /// Lists that failed to download: their last good copy stands in, if there is one.
    var failedLists: [String]? = nil
    /// The FilterSources.json it was built from (`FilterUpdater.Sources.digest`).
    var sources: String? = nil

    var date: Date? { ISO8601DateFormatter().date(from: updated) }

    /// For choosing the newest set. A set dated in the future (built with the clock set ahead)
    /// counts as the oldest: taken as built now, it would still outrank every set built after it.
    func comparableDate(now: Date = Date()) -> Date {
        guard let date, date <= now else { return .distantPast }
        return date
    }

    static func read(in folder: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: folder.appending(path: "manifest.json")) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }
}
