import Foundation
import NaturalLanguage

/// A change to make in the field's text, in UTF-16 offsets since the page's script counts in
/// JavaScript string indices.
struct TextEdit: Equatable {
    let from: Int
    let to: Int
    let text: String
}

enum CorrectionOutcome: Equatable {
    case corrected(String)
    /// Refused (unsupported language, refusal): asking again won't help.
    case declined
    /// Something transient: fine to try again.
    case failed
}

/// Model-free parts of text correction: how to cut the text for the model, whether an answer is
/// a correction at all, and the word-level changes between the two.
enum CorrectionText {
    /// About 30 s of model time: it writes roughly 250 characters a second on an M4 Pro (measured).
    static let maximumLength = 8_000
    /// Short pieces keep the model close to the text: given a paragraph repeated twelve times in
    /// one request, it answered with the paragraph once (measured).
    static let pieceLength = 1_200

    /// A part of the text: one to correct, or one kept as it is (line breaks, lines without letters).
    struct Piece: Equatable {
        let text: String
        let corrects: Bool
    }

    /// The text cut for the model, back to back: runs of lines of at most `pieceLength`
    /// characters, and a longer line cut between sentences. Lines without letters (blank,
    /// numbers, symbols) are kept as they are.
    static func pieces(of text: String) -> [Piece] {
        var pieces: [Piece] = []
        func keep(_ text: String) {
            guard !text.isEmpty else { return }
            if let last = pieces.last, !last.corrects {
                pieces[pieces.count - 1] = Piece(text: last.text + text, corrects: false)
            } else {
                pieces.append(Piece(text: text, corrects: false))
            }
        }
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let separator = index > 0 ? "\n" : ""
            if !line.contains(where: \.isLetter) {
                keep(separator + line)
            } else if line.count > pieceLength {
                keep(separator)
                pieces += sentences(line).map { Piece(text: $0, corrects: true) }
            } else if let last = pieces.last, last.corrects, last.text.count + 1 + line.count <= pieceLength {
                pieces[pieces.count - 1] = Piece(text: last.text + "\n" + line, corrects: true)
            } else {
                keep(separator)
                pieces.append(Piece(text: line, corrects: true))
            }
        }
        return pieces
    }

    /// A line cut into runs of whole sentences of at most `pieceLength` characters (one longer
    /// sentence stays whole), each keeping its trailing spaces, so they join back exactly.
    private static func sentences(_ line: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = line
        var runs: [String] = []
        var current = ""
        tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
            let sentence = String(line[range])
            if !current.isEmpty, current.count + sentence.count > pieceLength {
                runs.append(current)
                current = ""
            }
            current += sentence
            return true
        }
        if !current.isEmpty { runs.append(current) }
        return runs.joined() == line ? runs : [line]
    }

    /// The model's answer for `original`, or nil when it isn't a correction of it: a different
    /// number of lines, much shorter or longer, or most of it rewritten (a translation, an answer
    /// to the text, a summary).
    static func accept(_ answer: String, for original: String) -> String? {
        var answer = answer.trimmingCharacters(in: .newlines)
        for (open, close) in [("<text>", "</text>"), ("```", "```")] where answer.hasPrefix(open) && answer.hasSuffix(close) && answer.count > open.count + close.count {
            answer = String(answer.dropFirst(open.count).dropLast(close.count)).trimmingCharacters(in: .newlines)
        }
        // Keep the line's own leading and trailing spaces: the model drops them.
        let lines = original.components(separatedBy: "\n")
        let answers = answer.components(separatedBy: "\n")
        guard lines.count == answers.count else { return nil }
        answer = zip(lines, answers).map { line, answer in
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            let trail = String(line.reversed().prefix { $0 == " " || $0 == "\t" })
            return lead + answer.trimmingCharacters(in: .whitespaces) + trail
        }.joined(separator: "\n")

        let length = original.count
        guard answer.count >= length * 7 / 10 - 10, answer.count <= length * 14 / 10 + 10 else { return nil }
        let letters = original.filter { !$0.isWhitespace }.count
        let changed = edits(from: original, to: answer).reduce(0) { total, edit in
            total + distance(original.utf16Slice(edit.from, edit.to) ?? "", edit.text)
        }
        guard changed * 3 <= max(letters, 9) else { return nil }
        guard !turnsNegation(from: original, to: answer) else { return nil }
        return answer
    }

    /// Words that make a sentence negative. Told to add the "ne" French negations miss, the model
    /// also made affirmative sentences negative ("C'est un bon plan" became "Ce n'est pas un bon
    /// plan", measured).
    private static let negationWords: Set<String> = ["pas", "jamais", "rien", "aucun", "aucune", "not", "never", "nothing"]

    /// Whether the answer adds or removes a negation word, rather than fix one: a misspelled "pa"
    /// or "jamias", a "pas" typed twice, "can not" written "cannot". Compares the words that go
    /// with the words that come, wherever they are: the word-level edits don't pair them up.
    private static func turnsNegation(from original: String, to answer: String) -> Bool {
        let old = words(original)
        var gone = old
        var come: [String] = []
        for word in words(answer) {
            if let index = gone.firstIndex(of: word) { gone.remove(at: index) } else { come.append(word) }
        }
        var typos = gone
        for word in come where negationWords.contains(word) {
            guard let index = typos.firstIndex(where: { close($0, word) }) else { return true }
            typos.remove(at: index)
        }
        let typedTwice = Set(zip(old, old.dropFirst()).filter { $0 == $1 }.map(\.0))
        return gone.contains { word in
            negationWords.contains(word) && !typedTwice.contains(word) && !come.contains { close($0, word) }
        }
    }

    /// The same word with a typo: one letter wrong, letters swapped, or written together with the
    /// word before it.
    private static func close(_ a: String, _ b: String) -> Bool {
        if distance(a, b) <= 1 && min(a.count, b.count) >= 2 { return true }
        if a.count == b.count && a.sorted() == b.sorted() { return true }
        return min(a.count, b.count) >= 3 && (a.hasSuffix(b) || b.hasSuffix(a))
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init)
    }

    /// Characters to change to turn one into the other (Levenshtein), so a fixed word counts for
    /// its wrong letters: "aller" to "allé" is 2. Long rewrites count in full.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty, a.count <= 200, b.count <= 200 else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : 1 + min(previous, row[j], row[j - 1])
                previous = current
            }
        }
        return row[b.count]
    }

    /// Word-level changes from `original` to `corrected`. Changes of spacing alone, or of one
    /// apostrophe or space character for another, are left out: they aren't mistakes, and in
    /// a rich text editor a replaced space can collapse.
    static func edits(from original: String, to corrected: String) -> [TextEdit] {
        let old = tokens(original)
        let new = tokens(corrected)
        let difference = new.map(\.key).difference(from: old.map(\.key))
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var edits: [TextEdit] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            guard removed.contains(i) || inserted.contains(j) else {
                i += 1
                j += 1
                continue
            }
            let start = i < old.count ? old[i].from : (old.last?.to ?? 0)
            var end = start
            var text = ""
            while removed.contains(i) {
                end = old[i].to
                i += 1
            }
            while inserted.contains(j) {
                text += new[j].text
                j += 1
            }
            let before = original.utf16Slice(start, end) ?? ""
            if !(before.allSatisfy(\.isWhitespace) && text.allSatisfy(\.isWhitespace)) {
                edits.append(TextEdit(from: start, to: end, text: text))
            }
        }
        return edits
    }

    private struct Token {
        let text: String
        /// What the diff compares: typographic variants count as the same token.
        let key: String
        let from: Int
        let to: Int
    }

    /// Words (letters and digits), runs of spaces, and every other character on its own.
    private static func tokens(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var offset = 0
        var current = ""
        var kind: Character.Kind?
        func flush() {
            guard !current.isEmpty else { return }
            let length = current.utf16.count
            tokens.append(Token(text: current, key: key(current, kind), from: offset, to: offset + length))
            offset += length
            current = ""
        }
        for character in text {
            let next = character.kind
            if next != kind || next == .other { flush() }
            kind = next
            current.append(character)
        }
        flush()
        return tokens
    }

    private static func key(_ token: String, _ kind: Character.Kind?) -> String {
        switch kind {
        case .space: " "
        case .other where "’‘ʼ`´".contains(token): "'"
        default: token
        }
    }
}

private extension Character {
    enum Kind { case word, space, other }

    var kind: Kind {
        if isLetter || isNumber { return .word }
        if isWhitespace { return .space }
        return .other
    }
}

extension String {
    /// The text between two UTF-16 offsets, or nil when they don't fall on character boundaries.
    func utf16Slice(_ from: Int, _ to: Int) -> String? {
        guard from >= 0, from <= to, to <= utf16.count else { return nil }
        let start = utf16.index(utf16.startIndex, offsetBy: from)
        let end = utf16.index(utf16.startIndex, offsetBy: to)
        guard let lower = start.samePosition(in: self), let upper = end.samePosition(in: self) else { return nil }
        return String(self[lower..<upper])
    }
}
