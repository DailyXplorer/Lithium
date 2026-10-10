import ContentBlockerConverter
import CryptoKit
import Foundation

/// A filter list shown in Settings: one Lithium ships, or one from the catalog, off until chosen.
struct FilterListInfo: Sendable {
    let id: String
    let name: String
    let summary: String
    let section: String
    var url: URL? = nil
    var homepage: URL? = nil
}

/// Which lists the user changed. All empty, Lithium loads the shipped set exactly as before.
struct FilterChoices: Codable, Equatable, Sendable {
    /// Shipped lists turned off.
    var off: Set<String> = []
    /// Catalog lists turned on.
    var on: Set<String> = []
    /// Lists added by address, in the order added.
    var added: [URL] = []
    /// When each chosen list was last downloaded, and its rule count.
    var copies: [String: Copy] = [:]

    struct Copy: Codable, Equatable, Sendable {
        var rules: Int
        var updated: Date
        var failed = false
    }

    var isDefault: Bool { off.isEmpty && on.isEmpty && added.isEmpty }

    /// The lists in the extra group, catalog first, each with the address it comes from.
    var extraLists: [(id: String, url: URL)] {
        FilterLists.catalog.filter { on.contains($0.id) }.compactMap { info in info.url.map { (info.id, $0) } }
            + added.map { (FilterLists.id(of: $0), $0) }
    }
}

/// The lists to choose from, and the filter set built from the user's choice.
enum FilterLists {
    /// The group of the user's own filters, trusted like uBO's lists (`FilterUpdater.isTrusted`).
    static let myFiltersID = "my-filters"
    static let extraGroup = "extra"

    /// Shipped lists, by the id FilterSources.json gives them.
    static let shipped: [FilterListInfo] = [
        .init(id: "ubo-filters", name: "uBlock Origin filters", summary: "Ads, pop-ups and trackers.", section: "uBlock Origin"),
        .init(id: "ubo-quick-fixes", name: "uBlock Origin quick fixes", summary: "Fixes for the latest ad tricks.", section: "uBlock Origin"),
        .init(id: "ubo-unbreak", name: "uBlock Origin unbreak", summary: "Keeps sites working that other lists break.", section: "uBlock Origin"),
        .init(id: "ubo-privacy", name: "uBlock Origin privacy", summary: "Trackers the other lists miss.", section: "uBlock Origin"),
        .init(id: "ubo-badware", name: "uBlock Origin badware risks", summary: "Sites known for scams and fake downloads.", section: "uBlock Origin"),
        .init(id: "ubo-resource-abuse", name: "uBlock Origin resource abuse", summary: "Scripts that mine cryptocurrency.", section: "uBlock Origin"),
        .init(id: "easylist", name: "EasyList", summary: "The most used ad blocking list.", section: "Ads"),
        .init(id: "easyprivacy", name: "EasyPrivacy", summary: "Tracking scripts and pixels.", section: "Privacy"),
        .init(id: "peter-lowe", name: "Peter Lowe’s list", summary: "Ad and tracking servers.", section: "Privacy"),
        .init(id: "urlhaus", name: "Malicious URL blocklist", summary: "Sites that spread malware, from URLhaus.", section: "Malware"),
        .init(id: "ubo-cookies", name: "uBlock Origin cookie notices", summary: "Hides cookie banners.", section: "Cookie notices"),
        .init(id: "easylist-cookies", name: "EasyList cookie notices", summary: "Hides cookie banners.", section: "Cookie notices"),
    ]

    /// Well-known optional lists, from uBlock Origin's catalog (assets.json).
    static let catalog: [FilterListInfo] = [
        .init(id: "ubo-annoyances", name: "uBlock Origin annoyances", summary: "Pop-ups, overlays and other distractions.", section: "Annoyances",
              url: URL(string: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/annoyances-others.txt"),
              homepage: URL(string: "https://github.com/uBlockOrigin/uAssets")),
        .init(id: "easylist-annoyances", name: "EasyList annoyances", summary: "Banners, prompts and other page clutter.", section: "Annoyances",
              url: URL(string: "https://ublockorigin.github.io/uAssetsCDN/thirdparties/easylist-annoyances.txt"),
              homepage: URL(string: "https://easylist.to")),
        .init(id: "easylist-social", name: "EasyList social", summary: "Share buttons and social media widgets.", section: "Annoyances",
              url: URL(string: "https://easylist.to/easylist/fanboy-social.txt"), homepage: URL(string: "https://easylist.to")),
        .init(id: "easylist-newsletters", name: "EasyList newsletters", summary: "Newsletter sign-up prompts.", section: "Annoyances",
              url: URL(string: "https://ublockorigin.github.io/uAssetsCDN/thirdparties/easylist-newsletters.txt"),
              homepage: URL(string: "https://easylist.to")),
        .init(id: "easylist-notifications", name: "EasyList notifications", summary: "Requests to show notifications.", section: "Annoyances",
              url: URL(string: "https://ublockorigin.github.io/uAssetsCDN/thirdparties/easylist-notifications.txt"),
              homepage: URL(string: "https://easylist.to")),
        .init(id: "fanboy-annoyance", name: "Fanboy’s annoyance list", summary: "All of EasyList’s annoyance lists in one.", section: "Annoyances",
              url: URL(string: "https://easylist.to/easylist/fanboy-annoyance.txt"), homepage: URL(string: "https://easylist.to")),
        .init(id: "adguard-annoyances", name: "AdGuard annoyances", summary: "Pop-ups, widgets and app banners.", section: "Annoyances",
              url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/14.txt"),
              homepage: URL(string: "https://github.com/AdguardTeam/AdguardFilters")),
        .init(id: "liste-fr", name: "Liste FR", summary: "Ads on French websites.", section: "Regional",
              url: URL(string: "https://easylist-downloads.adblockplus.org/liste_fr.txt"), homepage: URL(string: "https://github.com/easylist/listefr")),
        .init(id: "adguard-french", name: "AdGuard French", summary: "Ads on French websites, by AdGuard.", section: "Regional",
              url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/16.txt"),
              homepage: URL(string: "https://github.com/AdguardTeam/AdguardFilters")),
        .init(id: "easylist-germany", name: "EasyList Germany", summary: "Ads on German websites.", section: "Regional",
              url: URL(string: "https://easylist.to/easylistgermany/easylistgermany.txt"), homepage: URL(string: "https://easylist.to")),
        .init(id: "hide-youtube-shorts", name: "Hide YouTube Shorts", summary: "Removes Shorts from YouTube’s pages and menus.", section: "Community",
              url: URL(string: "https://raw.githubusercontent.com/gijsdev/ublock-hide-yt-shorts/master/list.txt"),
              homepage: URL(string: "https://github.com/gijsdev/ublock-hide-yt-shorts")),
    ]

    /// Never `ubo-`: an added list mustn't be trusted to run code in pages.
    static func id(of url: URL) -> String {
        "url-" + SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The address of a list typed in: http(s) with a host, no password, of a sane length.
    static func validatedURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 2048, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()),
              let host = url.host(), !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// Where chosen lists, the user's filters and the converted groups are kept.
    struct Storage: Sendable {
        let folder: URL
        static let standard = Storage(folder: URL.applicationSupportDirectory.appending(path: "Lithium/FilterLists"))

        var myFilters: URL { folder.appending(path: "my-filters.txt") }
        var built: URL { folder.appending(path: "built") }
        func copy(of id: String) -> URL { folder.appending(path: "lists/\(id).txt") }

        var hasMyFilters: Bool { FileManager.default.fileExists(atPath: myFilters.path) }

        func readMyFilters() -> String {
            (try? String(contentsOf: myFilters, encoding: .utf8)) ?? ""
        }

        /// No file for empty filters: its absence keeps the shipped set as it is.
        func writeMyFilters(_ text: String) throws {
            if text.allSatisfy(\.isWhitespace) {
                try? FileManager.default.removeItem(at: myFilters)
                return
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: myFilters, atomically: true, encoding: .utf8)
        }

        func save(_ lines: [String], for id: String) throws {
            try FileManager.default.createDirectory(at: copy(of: id).deletingLastPathComponent(), withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: copy(of: id), atomically: true, encoding: .utf8)
        }
    }

    /// A list's lines, preprocessed as the shipped lists are, refused if it is HTML, binary or too big.
    static func download(_ url: URL, session: URLSession = .shared) async throws -> [String] {
        let tokens = FilterUpdater.bundled()?.sources.trueTokens ?? []
        let updater = FilterUpdater(sources: .init(lists: [:], groups: [:], trueTokens: tokens), session: session)
        return try await updater.download(url)
    }

    /// A line of the user's filters that Lithium can't apply.
    struct Problem: Equatable, Sendable {
        let line: Int
        let text: String
        let message: String
    }

    /// Converted one line at a time, so each problem names its own line.
    static func problems(in text: String) -> [Problem] {
        var problems: [Problem] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[Adblock") else { continue }
            if let message = problem(line) { problems.append(Problem(line: index + 1, text: line, message: message)) }
        }
        return problems
    }

    private static func problem(_ line: String) -> String? {
        if line.contains("##+js(") || line.contains("#@#+js(") {
            guard line.hasSuffix(")"), let start = line.range(of: "+js(") else { return "Not a complete scriptlet." }
            let name = line[start.upperBound...].prefix { $0 != "," && $0 != ")" }
                .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            // `site#@#+js()` turns every scriptlet off on the site.
            if name.isEmpty, line.contains("#@#+js(") { return nil }
            guard let ubo = UBOScriptlets.bundled else { return nil }
            return ubo.resourceName(name) == nil ? "Unknown scriptlet “\(name)”." : nil
        }
        let result = ContentBlockerConverter().convertArray(rules: [line], safariVersion: .autodetect(), advancedBlocking: true)
        if result.errorsCount > 0 || (result.safariRulesCount == 0 && (result.advancedRulesText ?? "").isEmpty) {
            return "Not supported."
        }
        return nil
    }
}

/// One compiled rule list: the converted rules in `file`, under an identifier naming what they hold.
struct FilterGroup: Sendable {
    let name: String
    let identifier: String
    let file: URL
    let webkitRules: Int

    /// Part of each compiled list's name: bump it when `Privacy.prepared(_:)` changes, so lists are rebuilt.
    static let preparation = 4

    /// A shipped set's groups, named after the set's date.
    static func shipped(in folder: URL, manifest: Manifest) -> [FilterGroup] {
        let stamp = manifest.updated.filter(\.isNumber)
        return manifest.groups.keys.sorted().map { group in
            FilterGroup(name: group, identifier: "lithium-\(group)-\(stamp)-p\(preparation)",
                        file: folder.appending(path: "\(group).json"), webkitRules: manifest.groups[group]?.webkitRules ?? 0)
        }
    }
}

/// The filter set the user chose: the shipped groups less the lists turned off, a group for the
/// lists they added and one for their own filters. Each group is converted once per content and
/// compiled under an identifier holding that content's hash, so a change converts and compiles
/// only the group it touches.
struct ChosenFilters: Sendable {
    let groups: [FilterGroup]
    /// advanced.txt and scriptlets.txt for the in-page engine, and the hash naming the engine.
    let engineFolder: URL
    let engineStamp: String
    let advancedRules: Int
    let scriptletRules: Int

    /// Part of each converted group's hash: bump it when the conversion changes.
    static let conversion = 1

    /// Shipped groups stay as compiled while no shipped list is off. Off the main thread.
    static func build(base: URL, manifest: Manifest, choices: FilterChoices, storage: FilterLists.Storage) -> ChosenFilters? {
        let fileManager = FileManager.default
        let read = { (file: URL) in
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map(String.init)
        }
        var groups: [FilterGroup] = []
        var converted: [Converted] = []
        var advanced: [String] = []
        var scriptlets: [String] = []
        if choices.off.isEmpty {
            groups = FilterGroup.shipped(in: base, manifest: manifest)
            advanced = read(base.appending(path: "advanced.txt"))
            scriptlets = read(base.appending(path: "scriptlets.txt"))
        } else {
            for (group, entry) in manifest.groups.sorted(by: { $0.key < $1.key }) {
                // A set without its lists' names can't be split: it stays whole.
                guard let names = entry.lists else { return nil }
                let lists = names.filter { !choices.off.contains($0) }.map { ($0, read(base.appending(path: "lists/\($0).txt"))) }
                guard let built = convert(group, lists, into: storage.built) else { return nil }
                converted.append(built)
            }
        }
        let extra = choices.extraLists.compactMap { list -> (String, [String])? in
            fileManager.fileExists(atPath: storage.copy(of: list.id).path) ? (list.id, read(storage.copy(of: list.id))) : nil
        }
        if !extra.isEmpty, let group = convert(FilterLists.extraGroup, extra, into: storage.built) { converted.append(group) }
        let mine = read(storage.myFilters).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("!") }
        if !mine.isEmpty, let group = convert(FilterLists.myFiltersID, [(FilterLists.myFiltersID, mine)], into: storage.built) {
            converted.append(group)
        }

        for group in converted {
            groups.append(group.planned)
            advanced += read(group.folder.appending(path: "advanced.txt"))
            scriptlets += read(group.folder.appending(path: "scriptlets.txt"))
        }
        var seen = Set<String>()
        advanced = advanced.filter { seen.insert($0).inserted }
        seen = []
        scriptlets = scriptlets.filter { seen.insert($0).inserted }

        // The engine is rebuilt only when what it gets changes, not for every network rule.
        let text = (advanced.joined(separator: "\n") + "\n", scriptlets.joined(separator: "\n") + "\n")
        let stamp = "u" + digest(text.0 + "\u{0}" + text.1)
        let engineFolder = storage.built.appending(path: "engine-\(stamp)")
        if !fileManager.fileExists(atPath: engineFolder.path) {
            let staging = storage.built.appending(path: ".staging-\(UUID().uuidString)")
            do {
                try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
                try text.0.write(to: staging.appending(path: "advanced.txt"), atomically: false, encoding: .utf8)
                try text.1.write(to: staging.appending(path: "scriptlets.txt"), atomically: false, encoding: .utf8)
                try fileManager.moveItem(at: staging, to: engineFolder)
            } catch {
                try? fileManager.removeItem(at: staging)
                return nil
            }
        }

        // What this set doesn't use goes: converting a group again is a few seconds at most.
        let used = Set(converted.map(\.folder.lastPathComponent) + [engineFolder.lastPathComponent])
        for other in (try? fileManager.contentsOfDirectory(at: storage.built, includingPropertiesForKeys: nil)) ?? []
        where !used.contains(other.lastPathComponent) && !other.lastPathComponent.hasPrefix(".staging-") {
            try? fileManager.removeItem(at: other)
        }
        return ChosenFilters(groups: groups, engineFolder: engineFolder, engineStamp: stamp,
                             advancedRules: advanced.count, scriptletRules: scriptlets.count)
    }

    private struct Converted {
        let planned: FilterGroup
        let folder: URL
    }

    private struct Info: Codable {
        let webkitRules: Int
    }

    /// The group as converted before when its rules are the same; otherwise converted now.
    private static func convert(_ group: String, _ lists: [(String, [String])], into built: URL) -> Converted? {
        let sorted = FilterUpdater.sorted(lists)
        let hash = digest("c\(conversion)\n\(group)\n" + sorted.rules.joined(separator: "\n") + "\u{0}" + sorted.scriptlets.joined(separator: "\n"))
        let folder = built.appending(path: "\(group)-\(hash)")
        let planned = { (info: Info) in
            Converted(planned: FilterGroup(name: group, identifier: "lithium-\(group)-h\(hash)-p\(FilterGroup.preparation)",
                                           file: folder.appending(path: "rules.json"), webkitRules: info.webkitRules),
                      folder: folder)
        }
        if let data = try? Data(contentsOf: folder.appending(path: "info.json")), let info = try? JSONDecoder().decode(Info.self, from: data) {
            return planned(info)
        }

        let result = ContentBlockerConverter().convertArray(rules: sorted.rules, safariVersion: .autodetect(), advancedBlocking: true)
        if result.discardedSafariRules > 0 {
            NSLog("Lithium: filter group %@ is over WebKit's rule limit, %d rules discarded", group, result.discardedSafariRules)
        }
        let info = Info(webkitRules: result.safariRulesCount)
        let fileManager = FileManager.default
        let staging = built.appending(path: ".staging-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try result.safariRulesJSON.write(to: staging.appending(path: "rules.json"), atomically: false, encoding: .utf8)
            try ((result.advancedRulesText ?? "") + "\n").write(to: staging.appending(path: "advanced.txt"), atomically: false, encoding: .utf8)
            try (sorted.scriptlets.joined(separator: "\n") + "\n").write(to: staging.appending(path: "scriptlets.txt"), atomically: false, encoding: .utf8)
            // Last: its presence says the folder is whole.
            try JSONEncoder().encode(info).write(to: staging.appending(path: "info.json"))
            try? fileManager.removeItem(at: folder)
            try fileManager.moveItem(at: staging, to: folder)
        } catch {
            try? fileManager.removeItem(at: staging)
            NSLog("Lithium: failed to save %@ filters: %@", group, error.localizedDescription)
            return nil
        }
        return planned(info)
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
