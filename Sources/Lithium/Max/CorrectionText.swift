import Foundation

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

    /// Runs of lines to correct together, each at most `pieceLength` characters, with the index
    /// of their first line. Lines without letters (blank, numbers, symbols) are left out.
    static func pieces(of text: String) -> [(first: Int, lines: [String])] {
        var pieces: [(first: Int, lines: [String])] = []
        var current: (first: Int, lines: [String], length: Int)?
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            guard line.contains(where: \.isLetter) else {
                if let piece = current { pieces.append((piece.first, piece.lines)) }
                current = nil
                continue
            }
            if let piece = current, piece.length + 1 + line.count <= pieceLength {
                current = (piece.first, piece.lines + [line], piece.length + 1 + line.count)
            } else {
                if let piece = current { pieces.append((piece.first, piece.lines)) }
                current = (index, [line], line.count)
            }
        }
        if let piece = current { pieces.append((piece.first, piece.lines)) }
        return pieces
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
        return answer
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
