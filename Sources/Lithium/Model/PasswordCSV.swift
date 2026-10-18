import Foundation

/// Other password managers' CSV files, read and written in memory only: the panels hand the
/// user's chosen file straight to and from here, so no copy in clear is left on disk.
enum PasswordCSV {
    enum Format: String, CaseIterable, Sendable {
        case chrome, onePassword, bitwarden, apple

        /// The header each one exports.
        var header: [String] {
            switch self {
            case .chrome: ["name", "url", "username", "password", "note"]
            case .onePassword: ["Title", "Url", "Username", "Password", "Notes"]
            case .bitwarden: ["folder", "favorite", "type", "name", "notes", "fields", "reprompt",
                              "login_uri", "login_username", "login_password", "login_totp"]
            case .apple: ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"]
            }
        }

        /// Lowercased header names. A file needs every column but the note.
        var columns: (title: String, url: String, username: String, password: String, note: String) {
            switch self {
            case .chrome: ("name", "url", "username", "password", "note")
            case .onePassword, .apple: ("title", "url", "username", "password", "notes")
            case .bitwarden: ("name", "login_uri", "login_username", "login_password", "notes")
            }
        }
    }

    struct Entry: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        var host: String
        var username: String
        var password: String
        var note = ""

        var description: String { "Entry(\(username) on \(host))" }
        var debugDescription: String { description }
    }

    /// RFC 4180: quoted fields with "" for a quote, CR, LF or CRLF line ends, line breaks inside
    /// quotes, a leading byte order mark. Blank lines are left out.
    static func rows(_ text: String) -> [[String]] {
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false
        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
        }
        func endRow() {
            endField()
            if row != [""] { rows.append(row) }
            row = []
        }
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            if quoted {
                if scalar != "\"" {
                    field.append(scalar)
                } else if next == "\"" {
                    field.append(scalar)
                    index += 1
                } else {
                    quoted = false
                }
            } else {
                switch scalar {
                case "\"" where field.isEmpty: quoted = true
                case ",": endField()
                case "\r":
                    endRow()
                    if next == "\n" { index += 1 }
                case "\n": endRow()
                default: field.append(scalar)
                }
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Quoted when it holds a comma, a quote or a line break.
    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The format whose own header this is, else the first with every column it needs. Apple's
    /// and 1Password's columns read the same, so a file taken for one gives the same entries.
    static func detect(header: [String]) -> Format? {
        let names = Set(header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return Format.allCases.first { Set($0.header.map { $0.lowercased() }) == names }
            ?? Format.allCases.first { format in
                let columns = format.columns
                return [columns.title, columns.url, columns.username, columns.password].allSatisfy(names.contains)
            }
    }

    /// Nil when the header is no format's. Rows without a password or a web address are skipped.
    static func parse(_ text: String) -> (format: Format, entries: [Entry], skipped: Int)? {
        let rows = rows(text)
        guard let header = rows.first, let format = detect(header: header) else { return nil }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let columns = format.columns
        let (url, username, password, note) = (names.firstIndex(of: columns.url), names.firstIndex(of: columns.username),
                                                names.firstIndex(of: columns.password), names.firstIndex(of: columns.note))
        func value(_ row: [String], _ column: Int?) -> String {
            guard let column, column < row.count else { return "" }
            return row[column]
        }
        var entries: [Entry] = []
        var skipped = 0
        for row in rows.dropFirst() {
            let secret = value(row, password)
            guard let host = host(of: value(row, url)), !secret.isEmpty else {
                skipped += 1
                continue
            }
            entries.append(Entry(host: host, username: value(row, username), password: secret, note: value(row, note)))
        }
        return (format, entries, skipped)
    }

    /// Bitwarden puts every address of a login in one field, comma-separated; some are bare hosts.
    private static func host(of address: String) -> String? {
        let first = address.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !first.isEmpty, let url = URL(string: first.contains("://") ? first : "https://" + first),
              url.scheme == "https" || url.scheme == "http", let host = url.host(), !host.isEmpty
        else { return nil }
        return host.lowercased()
    }

    static func export(_ credentials: [Credential], as format: Format) -> String {
        let columns = format.columns
        let lines = credentials.map { credential in
            let values = [columns.title: credential.host, columns.url: "https://\(credential.host)/", columns.username: credential.username,
                          columns.password: credential.password, columns.note: credential.note, "type": format == .bitwarden ? "login" : ""]
            return format.header.map { field(values[$0.lowercased()] ?? "") }.joined(separator: ",")
        }
        return ([format.header.joined(separator: ",")] + lines).map { $0 + "\r\n" }.joined()
    }
}

struct ImportReport: Equatable, Sendable {
    var added = 0, updated = 0, skipped = 0
}

extension VaultContents {
    /// One account per site and username: the same password is skipped, another one updates it.
    /// `skipped` counts only those; the rows the file couldn't give are the parser's.
    mutating func merge(_ entries: [PasswordCSV.Entry], now: Date) -> ImportReport {
        var report = ImportReport()
        struct Account: Hashable {
            let site: String, username: String
        }
        var accounts: [Account: Int] = [:]
        // Backwards, so the first of two alike is the one kept.
        for (index, credential) in credentials.enumerated().reversed() {
            accounts[Account(site: credential.site, username: credential.username)] = index
        }
        for entry in entries {
            let account = Account(site: SiteInfo.registrable(entry.host), username: entry.username)
            guard let index = accounts[account] else {
                accounts[account] = credentials.count
                credentials.append(Credential(host: entry.host, username: entry.username, password: entry.password, note: entry.note,
                                              created: now, modified: now))
                report.added += 1
                continue
            }
            guard credentials[index].password != entry.password else {
                report.skipped += 1
                continue
            }
            credentials[index].password = entry.password
            if !entry.note.isEmpty { credentials[index].note = entry.note }
            credentials[index].modified = now
            report.updated += 1
        }
        return report
    }
}
