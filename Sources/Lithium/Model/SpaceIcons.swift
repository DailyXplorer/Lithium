import Foundation
import Synchronization

/// What the space icon picker offers: the Phosphor icons listed in SpaceIcons.tsv
/// (`scripts/update-space-icons.py`), searched by name and keywords, and the system's emoji,
/// searched by their Unicode names. Built off the main thread when the picker opens and dropped
/// when it closes: nothing of it exists before, and no emoji image is bundled.
final class SpaceIconCatalog: Sendable {
    struct Entry: Identifiable, Sendable {
        /// What `Space.icon` keeps: a Phosphor name or an emoji.
        let id: String
        /// For help tags and VoiceOver: "Graduation cap", "Grinning face".
        let label: String
        /// " word word …", lowercased ASCII: a search term matches where a word starts with it.
        fileprivate let words: [UInt8]
    }

    let icons: [Entry]
    let emoji: [Entry]

    /// Catalogs alive: none until a picker opens, none once it has closed.
    static var live: Int { count.withLock { $0 } }
    private static let count = Mutex(0)

    init(icons: [Entry], emoji: [Entry]) {
        self.icons = icons
        self.emoji = emoji
        Self.count.withLock { $0 += 1 }
    }

    deinit { Self.count.withLock { $0 -= 1 } }

    /// About 300 icons from a 20 KB file and about 1,400 emoji from the system's Unicode tables.
    static func load() -> SpaceIconCatalog {
        SpaceIconCatalog(icons: bundledIcons(), emoji: systemEmoji())
    }

    /// The entries whose words start with every term of the query, in catalog order. One `memmem`
    /// per entry and term: a few thousand short strings take well under a millisecond.
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

    static func emoji(_ value: String) -> Entry {
        emoji(value, name: value.unicodeScalars.first?.properties.name ?? "")
    }

    /// "MONEY-MOUTH FACE": "money mouth" finds it too.
    private static func emoji(_ value: String, name: String) -> Entry {
        let name = name.lowercased()
        return Entry(id: value, label: sentence(name), words: Array(" \(name.replacingOccurrences(of: "-", with: " "))".utf8))
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

    /// Unicode blocks in picker order, smileys first.
    private static let blocks: [ClosedRange<UInt32>] = [
        0x1F600...0x1F64F, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x1F300...0x1F5FF,
        0x1F680...0x1F6FF, 0x1F000...0x1F2FF, 0x2000...0x2BFF, 0x3000...0x32FF,
    ]

    /// The emoji that are one character, as the system knows them, so each draws in this macOS's
    /// emoji font. Skin tones, hair parts and flags (pairs of letters) are left out; emoji drawn
    /// as text by default get the emoji variation selector.
    private static func systemEmoji() -> [Entry] {
        var entries: [Entry] = []
        for block in blocks {
            for value in block {
                guard let scalar = Unicode.Scalar(value) else { continue }
                let properties = scalar.properties
                guard properties.isEmoji, !properties.isEmojiModifier, !(0x1F1E6...0x1F1FF).contains(value),
                      let name = properties.name, !name.hasPrefix("EMOJI COMPONENT") else { continue }
                entries.append(emoji(properties.isEmojiPresentation ? String(scalar) : "\(scalar)\u{FE0F}", name: name))
            }
        }
        return entries
    }

    private static func sentence(_ words: String) -> String {
        words.prefix(1).uppercased() + words.dropFirst()
    }
}
