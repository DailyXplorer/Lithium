import Foundation
import NaturalLanguage
import WebKit

enum SummarySource: Equatable {
    case page
    case selection
}

struct SummaryContent: Equatable {
    /// One sentence saying what the text is about.
    let overview: String
    let points: [String]
}

/// Model-free parts of page summaries: what to summarize, how to cut it, how to read the answer.
enum SummaryText {
    /// Shorter selections summarize the page instead, so a stray click-drag doesn't produce a
    /// summary of four words.
    static let minimumSelectionWords = 30
    /// About two minutes of model time: the on-device model takes roughly 0.55 s per 1,000
    /// characters on an M4 Pro (measured), one request at a time.
    static let maximumLength = 200_000
    private static let maximumPoints = 6

    static func wordCount(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }

    /// Pieces of at most `limit` characters, of similar sizes, cut between paragraphs where
    /// possible, then between sentences, then between words.
    static func chunks(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        let parts = (text.count + limit - 1) / limit
        return pack(pieces(of: text, fitting: limit), target: text.count / parts, limit: limit)
    }

    private static func pieces(of text: String, fitting target: Int) -> [String] {
        text.components(separatedBy: "\n").flatMap { paragraph -> [String] in
            guard paragraph.count > target else { return [paragraph] }
            return sentences(paragraph).flatMap { sentence -> [String] in
                guard sentence.count > target else { return [sentence] }
                return words(sentence, fitting: target)
            }
        }
    }

    /// Fills each chunk up to `target`, never past `limit`.
    private static func pack(_ pieces: [String], target: Int, limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for piece in pieces where !piece.isEmpty {
            if !current.isEmpty, current.count >= target || current.count + 1 + piece.count > limit {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? piece : "\n" + piece
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
    }

    private static func words(_ text: String, fitting target: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if !current.isEmpty, current.count + 1 + word.count > target {
                parts.append(current)
                current = ""
            }
            current += current.isEmpty ? String(word) : " " + word
            // A "word" longer than a whole piece (a URL, a run of digits) is cut where it stands.
            while current.count > target {
                parts.append(String(current.prefix(target)))
                current = String(current.dropFirst(target))
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Reads answers shaped like "One sentence.\n- A point\n- Another point". Tolerates the
    /// usual drift: "•" or "1." bullets, doubled markers ("- - "), bold, headings, labels such
    /// as "Summary:" or "Key points:" and points wrapped over several lines.
    /// Lines with a link are dropped: a summary never needs one, and a page steering the model
    /// would want one there.
    static func parse(_ answer: String) -> SummaryContent? {
        var overview: [String] = []
        var points: [String] = []
        for rawLine in answer.components(separatedBy: .newlines) {
            var line = rawLine.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.contains("://") else { continue }
            if line.prefixMatch(of: bullet) != nil {
                while let match = line.prefixMatch(of: bullet) { line.removeSubrange(match.range) }
                if !line.isEmpty { points.append(line) }
            } else if points.isEmpty {
                line = line.replacing(label, with: "")
                // "Key points:" leads into the list rather than saying anything.
                if !line.isEmpty, !line.hasSuffix(":") { overview.append(line) }
            } else {
                points[points.count - 1] += " " + line
            }
        }
        guard !overview.isEmpty || !points.isEmpty else { return nil }
        return SummaryContent(overview: overview.joined(separator: " "), points: Array(points.prefix(maximumPoints)))
    }

    nonisolated(unsafe) private static let bullet = /^(?:[-•*–—▪◦]|\d{1,2}[.)])\s+/
    nonisolated(unsafe) private static let label = /^(?i:summary|overview|tl;?dr|résumé|resumen|zusammenfassung|riassunto)\s*:\s*/
}

/// What a page offers to summarize, read from the page itself.
struct PageContent {
    let title: String
    let text: String
    let selection: String
    /// The page is longer than `SummaryText.maximumLength`; `text` is its beginning.
    let isTruncated: Bool
}

@MainActor
enum PageReader {
    private static let script = Resources.bundle.url(forResource: "page-text", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    /// Runs in Lithium's own content world, so page scripts can't replace the functions it uses.
    static func read(_ webView: WKWebView) async -> PageContent? {
        let result = try? await webView.callAsyncJavaScript(
            script,
            arguments: ["limit": SummaryText.maximumLength],
            contentWorld: .defaultClient
        )
        guard let values = result as? [String: Any] else { return nil }
        return PageContent(
            title: values["title"] as? String ?? "",
            text: values["text"] as? String ?? "",
            selection: values["selection"] as? String ?? "",
            isTruncated: values["truncated"] as? Bool ?? false
        )
    }
}
