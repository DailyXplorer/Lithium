import Foundation
import NaturalLanguage

/// Rule-based tidying of page titles: removes notification counters and the site's own name.
enum TitleCleaner {
    /// Fits a 240 pt sidebar row in DM Sans 13 (measured); shorter titles are left to the rules.
    static let shortEnough = 22

    private static let separators = [" - ", " – ", " — ", " | ", " · ", " • ", " :: "]
    private static let colons = [" : ", ": "]
    private static let openingWords: Set = ["the", "a", "an", "of", "to", "in", "on", "for", "and", "with", "le", "la", "les", "un", "une", "des", "du", "de"]

    /// A notification counter at the start of a title, "(3) " or "[99+] ": the count and its "+".
    static var counter: Regex<(Substring, Substring, Substring)> { /^[\(\[](\d+)(\+?)[\)\]]\s*/ }

    static func clean(_ title: String, host: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacing(counter, with: "")
        let site = siteName(host)
        for separatorSet in [separators, colons] {
            let segments = split(text, by: separatorSet)
            guard segments.count > 1, segments.contains(where: { isSiteName($0, site: site) }) else { continue }
            if let first = segments.first(where: { !isSiteName($0, site: site) }) {
                text = first
            }
        }
        return text.isEmpty ? title : text
    }

    /// The label that names the site: "github" for gist.github.com, "lemonde" for www.lemonde.fr.
    static func siteName(_ host: String) -> String {
        let domain = SiteInfo.registrable(host)
        return String(domain.split(separator: ".").first ?? Substring(domain))
    }

    private static func isSiteName(_ segment: String, site: String) -> Bool {
        let normalized = segment.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !site.isEmpty, !normalized.isEmpty else { return false }
        // "YouTube", "Le Monde.fr", "Amazon.fr" count; "Sign in to GitHub" does not.
        return normalized == site || (normalized.contains(site) && normalized.count <= site.count + 4)
    }

    private static func split(_ text: String, by separators: [String]) -> [String] {
        var parts = [text]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func language(of title: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(title)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// Guards against page titles written to steer the model: the answer must be a short
    /// single line that still shares a real word with what the page said about itself.
    static func acceptable(_ candidate: String, original: String, host: String, maxLength: Int = 40) -> String? {
        let trimmed = candidate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”«».:"))
            .trimmingCharacters(in: .whitespaces)
        guard (2...maxLength).contains(trimmed.count),
              !isSiteName(trimmed, site: siteName(host)),
              !trimmed.contains(where: \.isNewline),
              !trimmed.lowercased().contains("http"),
              !trimmed.contains("://") else { return nil }
        let source = words(original + " " + host)
        return words(trimmed).isDisjoint(with: source) ? nil : trimmed
    }

    /// The model sometimes answers all lowercase; the title is the source of truth for proper nouns
    /// ("nasa" -> "NASA") and for a deliberate lowercase start ("iPhone"). Otherwise the label
    /// gets a capital first letter.
    static func capitalized(_ label: String, like title: String) -> String {
        // A counter ("(3) ") would hide the word that really opens the title.
        let parts = split(title.replacing(counter, with: ""), by: separators + colons).map { wordRuns($0).map(String.init) }
        let titleWords = parts.flatMap { $0 }
        // In Title Case every word has a capital, so only an inner capital ("iPhone") or an
        // acronym ("NASA") still marks a proper noun; a title mostly in caps marks none, except in
        // a part written normally ("MOON MISSION LIVE: NASA Artemis II launch"). Short words
        // ("A", "To") only count when the title has no longer ones.
        let letterWords = titleWords.filter { $0.first?.isLetter == true }
        let longWords = letterWords.filter { $0.count >= 4 }
        let counted = longWords.isEmpty ? letterWords : longWords
        let titleCase = counted.filter { $0.first?.isUppercase == true }.count * 4 > counted.count * 3
        let allCaps = mostlyCaps(titleWords)
        var properNouns: [String: String] = [:]
        for words in parts where !(allCaps && mostlyCaps(words)) {
            for (index, word) in words.enumerated()
            where word.contains(where: \.isUppercase)
                && !(titleCase && word.first?.isUppercase == true && !word.dropFirst().contains(where: \.isUppercase))
                // "The" opening the title or a part of it ("Review: The best…") is not a proper noun.
                && !(index == 0 && openingWords.contains(word.lowercased())) {
                properNouns[key(word)] = properNouns[key(word)] ?? word
            }
        }
        // A small word the title also writes lowercase after the same word stays as the label writes
        // it: "a" after "for" in "Vitamin A foods: a guide for a family". A name doesn't: "in paris"
        // in "Visit Paris: things to see in paris" still gives "Paris".
        let lowercasePairs = Set(parts.flatMap { words in
            zip(words, words.dropFirst()).filter { !$1.contains(where: \.isUppercase) && openingWords.contains(key($1)) }
                .map { key($0) + " " + key($1) }
        })
        var result = ""
        var rest = label.startIndex
        var previous = ""
        for word in wordRuns(label) {
            result += label[rest..<word.startIndex]
            let lowered = key(word)
            result += lowercasePairs.contains(previous + " " + lowered) ? String(word) : properNouns[lowered] ?? String(word)
            previous = lowered
            rest = word.endIndex
        }
        result += label[rest...]

        guard let first = result.first, first.isLowercase else { return result }
        if let firstWord = wordRuns(result).first, firstWord.contains(where: \.isUppercase), titleWords.contains(String(firstWord)) {
            return result
        }
        let locale = language(of: title).map { Locale(identifier: $0.minimalIdentifier) } ?? .current
        return String(first).capitalized(with: locale) + result.dropFirst()
    }

    /// More than half the words of four letters or more in caps. With no such word, every word in
    /// caps and one of them a small word like "TO": "GO TO BED" is shouting, "AI ML GPT RAG" a list
    /// of acronyms.
    private static func mostlyCaps(_ words: [String]) -> Bool {
        let letterWords = words.filter { $0.first?.isLetter == true }
        let longWords = letterWords.filter { $0.count >= 4 }
        guard !longWords.isEmpty else {
            return letterWords.allSatisfy { $0 == $0.uppercased() } && letterWords.contains { openingWords.contains($0.lowercased()) }
        }
        return longWords.filter { $0 == $0.uppercased() }.count * 2 > longWords.count
    }

    /// Lowercase without a locale, except that "İstanbul" gives "istanbul" rather than a dotted "i̇".
    private static func key(_ word: some StringProtocol) -> String {
        word.lowercased().replacing("i\u{307}", with: "i")
    }

    private static func words(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return Set(wordRuns(folded).map(String.init).filter { $0.count >= 3 })
    }

    /// Maximal runs of letters and digits, as slices of `text` so their indices point into it.
    private static func wordRuns(_ text: String) -> [Substring] {
        text.split { !$0.isLetter && !$0.isNumber }
    }
}
