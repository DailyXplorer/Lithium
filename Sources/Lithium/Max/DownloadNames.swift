import Foundation

/// What is known about a download when WebKit asks where to write it: nothing of the file itself yet.
struct DownloadSource {
    var filename: String
    /// The title of the page showing when the download started.
    var title: String?
    var page: URL?
    var file: URL?
}

/// Rule-based naming of downloads. Only a name that says nothing ("document(3).pdf", a UUID) is replaced.
enum DownloadNames {
    private static let vague: Set<String> = [
        "attachment", "audio", "blob", "content", "data", "default", "doc", "document", "documents",
        "download", "downloads", "dsc", "dscf", "dscn", "export", "fetch", "file", "files", "generated",
        "get", "getfile", "image", "img", "index", "media", "noname", "open", "output", "pdf", "photo",
        "pic", "picture", "print", "pxl", "scan", "screenshot", "show", "temp", "tmp", "unknown",
        "unnamed", "untitled", "video", "view", "viewer",
    ]

    /// True for a name made only of vague words, numbers, codes and hex: "IMG_2041.JPG", "D092331.jpg".
    static func isGeneric(_ filename: String) -> Bool {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        let words = stem.split { !$0.isLetter && !$0.isNumber }
        return words.allSatisfy { word in
            // A lone letter, but not a short word: "CV.pdf" says what it is.
            if word.allSatisfy(\.isNumber) || word.count == 1 { return true }
            // Hex with a digit in it: hashes and UUIDs, not words like "cafe".
            if word.allSatisfy(\.isHexDigit), word.contains(where: \.isNumber) { return true }
            // A camera's or scanner's prefix and counter: "img2041", "scan0001", "p7".
            let letters = word.prefix { $0.isLetter }
            guard word.dropFirst(letters.count).allSatisfy(\.isNumber) else { return false }
            return vague.contains(String(letters)) || (letters.count <= 2 && letters.count < word.count)
        }
    }

    /// A clear name from the page, without extension: its title less the site's name, else a
    /// slug in its address or the file's ("/invoices/october-2026" gives "October 2026").
    static func ruleName(_ source: DownloadSource) -> String? {
        if let title = source.title,
           let cleaned = sanitized(TitleCleaner.clean(title, host: source.page?.host() ?? "")), !isGeneric(cleaned) {
            return cleaned
        }
        let addresses = [source.page, source.file].compactMap { $0 }.filter { ["http", "https"].contains($0.scheme?.lowercased()) }
        for url in addresses {
            for segment in url.pathComponents.reversed().prefix(2) {
                if let slug = slug(segment) { return slug }
            }
        }
        return nil
    }

    /// Words joined by dashes or underscores, at least two of them, that say something.
    private static func slug(_ segment: String) -> String? {
        let stem = (segment as NSString).deletingPathExtension
        let words = stem.split { $0 == "-" || $0 == "_" || $0 == "+" || $0 == " " }
        guard words.count >= 2, stem.filter(\.isLetter).count >= 3, !isGeneric(stem) else { return nil }
        let joined = words.joined(separator: " ")
        return sanitized(joined.prefix(1).uppercased() + joined.dropFirst())
    }

    /// Safe as a file name: no "/" or ":", no line breaks, no leading dot that would hide the file.
    static func sanitized(_ name: String) -> String? {
        var text = name.replacingOccurrences(of: ": ", with: " - ").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        text = text.components(separatedBy: .controlCharacters.union(.newlines)).joined(separator: " ")
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if text.count > maxLength {
            let cut = text.prefix(maxLength)
            text = String(cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut).trimmingCharacters(in: CharacterSet(charactersIn: ".,;- "))
        }
        return text.isEmpty ? nil : text
    }

    /// Longer names get cut in the downloads list and in Finder.
    static let maxLength = 80

    /// The model's answer, if it is a short name about what the page and file said that says more
    /// than the site's name: not the same words recased, nor one that lost an order number or "n°1".
    static func acceptable(_ answer: String, for source: DownloadSource) -> String? {
        let said = [source.title ?? "", source.filename, source.page?.path() ?? "", source.file?.path() ?? ""].joined(separator: " ")
        guard let accepted = TitleCleaner.acceptable(answer, original: said, host: source.page?.host() ?? source.file?.host() ?? "", maxLength: maxLength),
              let name = sanitized(accepted), !isGeneric(name) else { return nil }
        let original = ((source.filename.removingPercentEncoding ?? source.filename) as NSString).deletingPathExtension
        guard folded(name) != folded(original) else { return nil }
        // A vague name's numbers are counters ("IMG_2041"), but not its dates ("scan-2026-10-12")
        // nor a code that only looks like hex ("FAC2026100045").
        let (dated, dates) = datesWithoutMonths(in: original)
        let labelled = dated.lowercased().split { !$0.isLetter && !$0.isNumber }.filter(isLabelledNumber)
        let kept = isGeneric(original) ? codes(in: dates + " " + labelled.joined(separator: " ")) : codes(in: dated)
        guard kept.isSubset(of: codes(in: name)) else { return nil }
        return name
    }

    /// A label then a number, as an invoice's or an order's: "fac2026100045", "dec2026"; not a
    /// camera's prefix and counter ("img2041", "p7").
    private static func isLabelledNumber(_ word: Substring) -> Bool {
        let letters = word.prefix { $0.isLetter }
        return letters.count > 2 && letters.count < word.count && word.dropFirst(letters.count).allSatisfy(\.isNumber)
            && !vague.contains(String(letters))
    }

    /// "2025-06-12", "12.06.2025" or "2026-10", not "2026-28": a year, then a month and maybe a
    /// day, or the reverse. Captures the year and the day, the first number unless it can't be a day.
    private static let numericDate = try! NSRegularExpression(pattern: #"(?<!\d)(?:((?:19|20)\d\d)[-_.](?:0?[1-9]|1[0-2])(?:[-_.](0?[1-9]|[12]\d|3[01]))?|(?:(0?[1-9]|[12]\d|3[01])[-_.](?:0?[1-9]|1[0-2])|(?:0?[1-9]|1[0-2])[-_.](0?[1-9]|[12]\d|3[01]))[-_.]((?:19|20)\d\d))(?!\d)"#)

    /// `text` with its numeric dates cut to their years and days, and those years and days: a date
    /// the model writes out ("12 June 2025") keeps only them in digits.
    private static func datesWithoutMonths(in text: String) -> (text: String, dates: String) {
        let all = NSRange(text.startIndex..., in: text)
        let parts = numericDate.matches(in: text, range: all).flatMap { match in
            (1...5).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
        return (numericDate.stringByReplacingMatches(in: text, range: all, withTemplate: " $1$5 $2$3$4 "), parts.joined(separator: " "))
    }

    /// Case and separators aside: "quarterly_report" and "Quarterly report" say the same.
    private static func folded(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The numbers, dates and codes in a name ("n°1", "2026-28", "INV4821"), less the hashes and
    /// random tokens a server adds ("iqhqpvt6ri5vna2zlwwgggaqwa", "3f9a2c7e").
    private static func codes(in text: String) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(words.flatMap { word -> [String] in
            // A token's letters and digits take turns; a code's come in a run or two
            // ("invoice48213", "FAC2026100045", "dec2026").
            let turns = zip(word, word.dropFirst()).filter { $0.isNumber != $1.isNumber }.count
            // Five, not three: an order number such as "ORD12345X9" takes three.
            if word.count >= 6, turns >= 5 { return [] }
            // Its numbers, as a clear name may write them: "invoice48213" as "invoice 48213",
            // "07" as "7".
            return word.split { !$0.isNumber }.map { run in
                let number = run.drop { $0 == "0" }
                return number.isEmpty ? "0" : String(number)
            }
        })
    }

    /// `name` with the site's extension. An extension `name` ends in itself goes: Finder hides the
    /// real one, so "Invoice.pdf.pkg" would pass for a PDF.
    static func fileName(_ name: String, keepingExtensionOf original: String) -> String {
        // Trailing dots and spaces go before every check, not once at the end: "Invoice.pdf..x" or
        // "Invoice.pdf .x" would stop at the empty or spaced suffix, then end in ".pdf" once trimmed.
        func trimmingEnd(_ text: Substring) -> Substring {
            var text = text
            while text.last == "." || text.last?.isWhitespace == true { text.removeLast() }
            return text
        }
        let pathExtension = (original as NSString).pathExtension
        let tail = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        // Cut to the 255-byte limit before the checks, not after: 80 emoji are 320 bytes, and a
        // later cut could stop right after a ".pdf" the checks left because of what followed it.
        var stem = Substring(name)
        while stem.utf8.count + tail.utf8.count > 255, !stem.isEmpty { stem.removeLast() }
        stem = trimmingEnd(stem)
        while let dot = stem.lastIndex(of: "."), case let suffix = stem[stem.index(after: dot)...],
              suffix.contains(where: \.isLetter), suffix.allSatisfy({ $0.isLetter || $0.isNumber }) {
            stem = trimmingEnd(stem[..<dot])
        }
        let base = stem.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        guard !base.isEmpty else { return original }
        return Downloads.fileName(base, tail)
    }
}
