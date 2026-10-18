import Foundation
import Testing
@testable import Lithium

@Suite struct PasswordCSVTests {
    typealias Entry = PasswordCSV.Entry
    private static let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func rowsFollowRFC4180() {
        #expect(PasswordCSV.rows("a,b\nc,d\n") == [["a", "b"], ["c", "d"]], "a trailing line end")
        #expect(PasswordCSV.rows("a,b\r\nc,d") == [["a", "b"], ["c", "d"]], "CRLF")
        #expect(PasswordCSV.rows("a\rb") == [["a"], ["b"]], "CR")
        #expect(PasswordCSV.rows("\u{FEFF}name,url\n") == [["name", "url"]], "a byte order mark")
        #expect(PasswordCSV.rows("\"a,b\",\"say \"\"hi\"\"\",\"\"") == [["a,b", "say \"hi\"", ""]], "quotes")
        #expect(PasswordCSV.rows("\"two\r\nlines\",x\n") == [["two\r\nlines", "x"]], "a line break inside quotes")
        #expect(PasswordCSV.rows("a,,\n\n\nb") == [["a", "", ""], ["b"]], "empty fields, blank lines")
        #expect(PasswordCSV.rows("a\"b,c") == [["a\"b", "c"]], "a quote inside an unquoted field")
        #expect(PasswordCSV.rows("").isEmpty)
    }

    @Test func aFieldIsQuotedOnlyWhenItMustBe() {
        #expect(PasswordCSV.field("plain value") == "plain value")
        #expect(PasswordCSV.field("a,b") == "\"a,b\"")
        #expect(PasswordCSV.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(PasswordCSV.field("two\nlines") == "\"two\nlines\"")
        #expect(PasswordCSV.field("two\r\nlines") == "\"two\r\nlines\"")
    }

    @Test func theFormatComesFromTheHeader() {
        #expect(PasswordCSV.detect(header: ["name", "url", "username", "password", "note"]) == .chrome)
        #expect(PasswordCSV.detect(header: ["name", "url", "username", "password"]) == .chrome, "Chrome before notes")
        #expect(PasswordCSV.detect(header: ["Title", "Url", "Username", "Password", "OTPAuth", "Favorite", "Archived", "Tags", "Notes"])
            == .onePassword)
        #expect(PasswordCSV.detect(header: ["TITLE", " url ", "Username", "Password", "Notes"]) == .onePassword, "any case")
        #expect(PasswordCSV.detect(header: PasswordCSV.Format.bitwarden.header) == .bitwarden)
        #expect(PasswordCSV.detect(header: ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"]) == .apple)
        #expect(PasswordCSV.detect(header: ["url", "username", "password"]) == nil)
        #expect(PasswordCSV.detect(header: ["date", "amount"]) == nil)
        #expect(PasswordCSV.parse("date,amount\n1,2\n")?.format == nil)
    }

    @Test(arguments: [
        ("chrome", PasswordCSV.Format.chrome, [
            Entry(host: "accounts.example.com", username: "alice@example.com", password: "pass,word"),
            Entry(host: "example.org", username: "bob", password: "say \"hi\"", note: "two\nlines"),
        ], 2),
        ("onepassword", PasswordCSV.Format.onePassword, [
            Entry(host: "www.example.com", username: "alice", password: "s3cret!", note: "personal"),
            Entry(host: "login.example.net", username: "bob", password: "hunter2-but-longer"),
        ], 1),
        ("bitwarden", PasswordCSV.Format.bitwarden, [
            Entry(host: "example.com", username: "alice", password: "p\"q", note: "note, with comma"),
            Entry(host: "intranet.example.test", username: "bob", password: "correct horse"),
        ], 1),
        ("apple", PasswordCSV.Format.apple, [
            Entry(host: "example.com", username: "alice", password: "Tr0ub4dor&3"),
            Entry(host: "192.168.1.1", username: "admin", password: "router-pass", note: "home router"),
        ], 1),
    ])
    func eachFormatsExportIsRead(fixture: String, format: PasswordCSV.Format, entries: [Entry], skipped: Int) throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/passwords/\(fixture)", withExtension: "csv"))
        let parsed = try #require(PasswordCSV.parse(try String(contentsOf: url, encoding: .utf8)))
        #expect(parsed.format == format)
        #expect(parsed.entries == entries)
        #expect(parsed.skipped == skipped, "rows with no password or no web address")
    }

    @Test(arguments: PasswordCSV.Format.allCases)
    func anExportReadsBackAsItWas(format: PasswordCSV.Format) throws {
        let credentials = [
            Credential(host: "accounts.example.com", username: "alice", password: "a,b\"c\nd", note: "line one\nline two",
                       created: Self.date, modified: Self.date),
            Credential(host: "example.org", username: "", password: " spaced ", created: Self.date, modified: Self.date),
        ]
        let text = PasswordCSV.export(credentials, as: format)
        let parsed = try #require(PasswordCSV.parse(text))
        #expect(parsed.format == format)
        #expect(parsed.skipped == 0)
        #expect(parsed.entries == credentials.map { Entry(host: $0.host, username: $0.username, password: $0.password, note: $0.note) })
    }

    @Test func anImportAddsNewAccountsAndUpdatesChangedOnes() {
        let kept = Credential(host: "accounts.example.com", username: "alice", password: "one", note: "kept",
                              created: Self.date, modified: Self.date)
        var vault = VaultContents(credentials: [kept])
        let later = Self.date.addingTimeInterval(60)
        let report = vault.merge([
            Entry(host: "www.example.com", username: "alice", password: "one"),
            Entry(host: "example.com", username: "bob", password: "two", note: "new"),
            Entry(host: "example.com", username: "bob", password: "two"),
            Entry(host: "login.example.com", username: "alice", password: "three"),
            Entry(host: "example.org", username: "alice", password: "one"),
        ], now: later)
        #expect(report == ImportReport(added: 2, updated: 1, skipped: 2))
        #expect(vault.credentials.map(\.host) == ["accounts.example.com", "example.com", "example.org"])
        #expect(vault.credentials[0].id == kept.id)
        #expect(vault.credentials[0].password == "three")
        #expect(vault.credentials[0].note == "kept")
        #expect(vault.credentials[0].created == Self.date && vault.credentials[0].modified == later)
        #expect(vault.credentials[1].note == "new")
    }
}
