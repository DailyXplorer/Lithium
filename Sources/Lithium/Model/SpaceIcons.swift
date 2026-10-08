import Foundation
import Synchronization

/// What the space icon picker offers: the Phosphor icons listed in SpaceIcons.tsv
/// (`scripts/update-space-icons.py`), searched by name and keywords. Built off the main thread
/// when the picker opens and dropped when it closes: nothing of it exists before.
final class SpaceIconCatalog: Sendable {
    struct Entry: Identifiable, Sendable {
        /// What `Space.icon` keeps: a Phosphor name.
        let id: String
        /// For help tags and VoiceOver: "Graduation cap".
        let label: String
        /// " word word …", lowercased ASCII: a search term matches where a word starts with it.
        fileprivate let words: [UInt8]
    }

    let icons: [Entry]

    /// Catalogs alive: none until a picker opens, none once it has closed.
    static var live: Int { count.withLock { $0 } }
    private static let count = Mutex(0)

    init(icons: [Entry]) {
        self.icons = icons
        Self.count.withLock { $0 += 1 }
    }

    deinit { Self.count.withLock { $0 -= 1 } }

    /// About 300 icons from a 20 KB file.
    static func load() -> SpaceIconCatalog {
        SpaceIconCatalog(icons: bundledIcons())
    }

    /// The entries whose words start with every term of the query, in catalog order. One `memmem`
    /// per entry and term: a few hundred short strings take well under a millisecond.
    static func search(_ query: String, in entries: [Entry]) -> [Entry] {
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { $0.isWhitespace || $0 == "-" }
            .map { Array(" \($0)".utf8) }
        guard !terms.isEmpty else { return entries }
        return entries.filter { entry in
            entry.words.withUnsafeBytes { words in
                terms.allSatisfy { term in
                    term.withUnsafeBytes { memmem(words.baseAddress, words.count, $0.baseAddress, $0.count) != nil }
                }
            }
        }
    }

    static func icon(_ name: String, keywords: Substring = "") -> Entry {
        let words = name.replacingOccurrences(of: "-", with: " ")
        return Entry(id: name, label: sentence(words), words: Array(" \(words) \(keywords)".utf8))
    }

    private static func bundledIcons() -> [Entry] {
        guard let url = Resources.bundle.url(forResource: "SpaceIcons", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard let name = fields.first else { return nil }
            return icon(String(name), keywords: fields.count > 1 ? fields[1] : "")
        }
    }

    private static func sentence(_ words: String) -> String {
        words.prefix(1).uppercased() + words.dropFirst()
    }
}
