import Foundation

/// A page WebKit refused because a filter list blocks its address ("strict blocking", as uBlock
/// Origin calls it), and why: the list and the filter, looked up only once a page is refused.
struct BlockedPage: Equatable {
    let url: URL
    /// Nil while the lists are searched.
    var reason: Reason?

    struct Reason: Equatable, Sendable {
        /// The list's id in FilterSources.json, and the filter as written there; nil when no filter
        /// found in the lists' text blocks the address.
        var list: String?
        var filter: String?
        /// The groups whose rule lists hold it: left off the page's blockers when it is let through.
        var groups: Set<String>
    }

    /// WebKit's `WebKitErrorFrameLoadBlockedByContentBlocker`.
    static func isBlocked(_ error: NSError) -> Bool {
        error.domain == "WebKitErrorDomain" && error.code == 104
    }

    enum Kind {
        case badware, malware, resourceAbuse, ads, trackers, annoyances, unknown
    }

    static func kind(of list: String?) -> Kind {
        switch list {
        case "ubo-badware": .badware
        case "urlhaus": .malware
        case "ubo-resource-abuse": .resourceAbuse
        case "ubo-filters", "ubo-quick-fixes", "easylist", "peter-lowe": .ads
        case "ubo-privacy", "easyprivacy": .trackers
        case "ubo-cookies", "easylist-cookies": .annoyances
        default: .unknown
        }
    }

    /// The names the lists go by in uBlock Origin.
    static func title(of list: String) -> String {
        switch list {
        case "ubo-filters": "uBlock filters"
        case "ubo-quick-fixes": "uBlock filters – Quick fixes"
        case "ubo-privacy": "uBlock filters – Privacy"
        case "ubo-badware": "uBlock filters – Badware risks"
        case "ubo-resource-abuse": "uBlock filters – Resource abuse"
        case "ubo-cookies": "uBlock filters – Cookie notices"
        case "easylist": "EasyList"
        case "easyprivacy": "EasyPrivacy"
        case "easylist-cookies": "EasyList Cookie List"
        case "peter-lowe": "Peter Lowe’s Ad and tracking server list"
        case "urlhaus": "Online Malicious URL Blocklist"
        case FilterLists.myFiltersID: "your filters"
        // Added by address, with no name of their own.
        case _ where list.hasPrefix("url-"): "a list you added"
        default: FilterLists.catalog.first { $0.id == list }?.name ?? list
        }
    }

    static func explanation(of kind: Kind) -> String {
        switch kind {
        case .badware: "This site is known to put visitors at risk, with fake downloads, scams or unwanted software."
        case .malware: "This address is known to spread malware."
        case .resourceAbuse: "This site is known to use visitors’ computers for its own ends, such as mining cryptocurrency."
        case .ads: "This address is known to serve ads."
        case .trackers: "This address is known to track people across sites."
        case .annoyances: "This address is known to serve cookie notices."
        case .unknown: "A filter list in Site Protections blocks this address."
        }
    }

    /// Searches the lists of a filters folder for what blocks `url` as a page. In each list, lines
    /// naming the site, as written or escaped in a regular expression, are tried first; only if none
    /// blocks it is every line of that list tried (a capitalised domain, a broader expression): any
    /// list may be the one whose group still blocks the page. Lists that flag danger come first;
    /// nothing found at all leaves every group still loaded to let the page through. `extra` are the
    /// lists the user added and their own filters, each with its group; `off` the shipped lists
    /// turned off: a group none of whose lists is left isn't loaded.
    static func reason(for url: URL, in folder: URL, adding extra: [(list: String, group: String, file: URL)] = [],
                       leavingOut off: Set<String> = []) -> Reason {
        guard let manifest = Manifest.read(in: folder) else { return Reason(groups: []) }
        var groupsOfList: [String: Set<String>] = [:]
        var files: [String: URL] = [:]
        for (group, entry) in manifest.groups {
            for list in entry.lists ?? [] where !off.contains(list) {
                groupsOfList[list, default: []].insert(group)
                files[list] = folder.appending(path: "lists/\(list).txt")
            }
        }
        for list in extra {
            groupsOfList[list.list, default: []].insert(list.group)
            files[list.list] = list.file
        }
        let page = Page(url)
        let site = SiteInfo.registrable(page.host)
        var matches: [(list: String, filter: String)] = []
        if !site.isEmpty {
            let needles = [site, site.replacingOccurrences(of: ".", with: #"\."#)].map { Data($0.utf8) }
            for list in groupsOfList.keys.sorted() {
                // The tab went elsewhere: its caller drops the answer.
                if Task.isCancelled { return Reason(groups: []) }
                guard let file = files[list], let data = try? Data(contentsOf: file, options: .alwaysMapped) else { continue }
                var seen: Set<String> = []
                var found = needles.flatMap { lines(in: data, containing: $0) }.filter { seen.insert($0).inserted && blocksPage($0, page) }
                if found.isEmpty {
                    found = data.split(separator: 0x0A)
                        .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { blocksPage($0, page) }
                }
                matches += found.map { (list, $0) }
            }
        }
        let order: [Kind] = [.malware, .badware, .resourceAbuse, .trackers, .ads, .annoyances, .unknown]
        // A filter for the page itself first, then the narrowest.
        let best = matches.min { a, b in
            let (ka, kb) = (order.firstIndex(of: kind(of: a.list)) ?? 0, order.firstIndex(of: kind(of: b.list)) ?? 0)
            if ka != kb { return ka < kb }
            if isForPages(a.filter) != isForPages(b.filter) { return isForPages(a.filter) }
            return a.filter.count > b.filter.count
        }
        let loaded = manifest.groups.filter { _, entry in entry.lists.map { $0.isEmpty || !off.isSuperset(of: $0) } ?? true }
        let groups = matches.isEmpty ? Set(loaded.keys).union(extra.map(\.group))
            : Set(matches.flatMap { groupsOfList[$0.list] ?? [] })
        return Reason(list: best?.list, filter: best?.filter, groups: groups)
    }

    /// Whole lines holding `needle`, found by a byte search rather than splitting the whole file.
    static func lines(in data: Data, containing needle: Data) -> [String] {
        var found: [String] = []
        var start = data.startIndex
        while let match = data.range(of: needle, in: start..<data.endIndex) {
            let lineStart = data[..<match.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let lineEnd = data[match.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            found.append(String(decoding: data[lineStart..<lineEnd], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            start = lineEnd
        }
        return found
    }

    private static let pageTypes: Set<String> = ["doc", "document", "all"]
    /// Options that leave a filter blocking whole pages; any other one makes it something else
    /// (a redirect, a header, a parameter remover) or limits it to other kinds of loads.
    private static let pageOptions: Set<String> = ["important", "match-case", "1p", "first-party", "~third-party", "~3p"]

    static func isForPages(_ filter: String) -> Bool {
        split(filter).options.contains { pageTypes.contains($0) }
    }

    private static func split(_ filter: String) -> (pattern: String, options: [String]) {
        // A regular expression may hold a `$` of its own: options come only after its closing slash.
        let searched = filter.hasPrefix("/") ? filter[(filter.lastIndex(of: "/") ?? filter.startIndex)...] : filter[...]
        guard let dollar = searched.lastIndex(of: "$") else { return (filter, []) }
        let options = filter[filter.index(after: dollar)...]
        guard !options.contains("/") else { return (filter, []) }
        return (String(filter[..<dollar]), options.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// The address as every line of the lists is checked against it, worked out once.
    struct Page {
        let address: String
        let lowered: String
        let host: String

        init(_ url: URL) {
            address = url.absoluteString
            lowered = address.lowercased()
            host = url.host()?.lowercased() ?? ""
        }
    }

    /// Whether an Adblock-syntax network filter blocks `url` loaded as a page, from the address bar.
    static func blocksPage(_ filter: String, url: URL) -> Bool {
        blocksPage(filter, Page(url))
    }

    static func blocksPage(_ filter: String, _ page: Page) -> Bool {
        guard !filter.isEmpty, !filter.hasPrefix("!"), !filter.hasPrefix("@@"), !filter.hasPrefix("["),
              !["##", "#@#", "#?#", "#$#", "#%#", "$$", "#+js"].contains(where: filter.contains) else { return false }
        let (pattern, options) = split(filter)
        // Each plain run of the pattern must be in the address: most filters stop here, before their
        // options are read or a regular expression is built, which keeps trying every line short.
        if !(pattern.count > 2 && pattern.hasPrefix("/") && pattern.hasSuffix("/")) {
            guard pattern.lowercased().split(whereSeparator: { "*^|".contains($0) }).allSatisfy({ page.lowered.contains($0) }) else { return false }
        }
        let host = page.host
        var matchCase = false
        for option in options {
            if pageTypes.contains(option) || pageOptions.contains(option) {
                if option == "match-case" { matchCase = true }
            } else if let domains = option.wholeMatch(of: /(?:domain|from)=(.+)/)?.1 {
                // A page's own load counts as coming from its own site.
                let entries = domains.split(separator: "|").map(String.init)
                let excluded = entries.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) }
                let included = entries.filter { !$0.hasPrefix("~") }
                if excluded.contains(where: { Self.host(host, isIn: $0) }) { return false }
                if !included.isEmpty, !included.contains(where: { Self.host(host, isIn: $0) }) { return false }
            } else if option.hasPrefix("~"), !pageTypes.contains(String(option.dropFirst())) {
                // Leaving out other kinds of loads (`~script`) still blocks pages.
                continue
            } else {
                return false
            }
        }
        let address = page.address
        guard let regex = regex(for: pattern, matchCase: matchCase) else { return false }
        return regex.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil
    }

    private static func host(_ host: String, isIn domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    /// Adblock syntax: `||` anchors at the host or one of its parents, `|` at an end, `^` is a
    /// separator, `*` anything; `/…/` is a regular expression.
    static func regex(for pattern: String, matchCase: Bool = false) -> NSRegularExpression? {
        var source: String
        if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            source = String(pattern.dropFirst().dropLast())
        } else {
            var rest = Substring(pattern)
            source = ""
            if rest.hasPrefix("||") {
                source = #"^[a-z][a-z0-9+.\-]*://(?:[^/?#]*\.)?"#
                rest = rest.dropFirst(2)
            } else if rest.hasPrefix("|") {
                source = "^"
                rest = rest.dropFirst()
            }
            let anchoredEnd = rest.hasSuffix("|")
            if anchoredEnd { rest = rest.dropLast() }
            for character in rest {
                switch character {
                case "*": source += ".*"
                case "^": source += #"(?:[^\w.%\-]|$)"#
                default: source += NSRegularExpression.escapedPattern(for: String(character))
                }
            }
            if anchoredEnd { source += "$" }
        }
        return try? NSRegularExpression(pattern: source, options: matchCase ? [] : [.caseInsensitive])
    }
}
