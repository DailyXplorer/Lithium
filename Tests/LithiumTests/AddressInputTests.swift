import AppKit
import Foundation
import Network
import Testing
@testable import Lithium

struct AddressInputTests {
    @Test(arguments: [
        ("apple.com", "https://apple.com"),
        ("  news.ycombinator.com/item?id=1  ", "https://news.ycombinator.com/item?id=1"),
        ("http://example.org", "http://example.org"),
        ("localhost:3000", "http://localhost:3000"),
        ("192.168.1.10", "http://192.168.1.10"),
        ("about:blank", "about:blank"),
        ("météo paris", "https://search.brave.com/search?q=m%C3%A9t%C3%A9o%20paris"),
        ("c++ tutorial", "https://search.brave.com/search?q=c%2B%2B%20tutorial"),
        ("swift", "https://search.brave.com/search?q=swift"),
        ("1.5", "https://search.brave.com/search?q=1.5"),
        ("mailto:alice@example.com", "mailto:alice@example.com"),
        ("alice@example.com", "https://search.brave.com/search?q=alice@example.com"),
        ("alice:secret@example.com/inbox", "https://search.brave.com/search?q=alice:secret@example.com/inbox"),
        ("admin@192.168.1.1", "https://search.brave.com/search?q=admin@192.168.1.1"),
        ("[::1]", "http://[::1]"),
        ("[2001:db8::1]/admin", "http://[2001:db8::1]/admin"),
        ("[::1]:8080", "http://[::1]:8080"),
        ("node.js", "https://search.brave.com/search?q=node.js"),
        ("config.json", "https://search.brave.com/search?q=config.json"),
        ("16:9", "https://search.brave.com/search?q=16:9"),
        ("10:30", "https://search.brave.com/search?q=10:30"),
        ("john3:16", "https://search.brave.com/search?q=john3:16"),
        ("example.com:8080/admin", "http://example.com:8080/admin"),
        ("docs.github.io", "https://docs.github.io"),
        ("www.bbc.co.uk", "https://www.bbc.co.uk"),
        ("mac-mini.local", "http://mac-mini.local"),
        ("nas.local/admin", "http://nas.local/admin"),
        ("Router.LAN", "http://Router.LAN"),
        ("router.lan:8080", "http://router.lan:8080"),
        ("nas:5000", "http://nas:5000"),
        ("router:8080/admin", "http://router:8080/admin"),
        ("psalm23:4", "https://search.brave.com/search?q=psalm23:4"),
    ])
    func resolves(input: String, expected: String) {
        #expect(AddressInput.url(for: input, engine: .brave)?.absoluteString == expected)
    }

    @Test func emptyInputOpensNothing() {
        #expect(AddressInput.url(for: "   ") == nil)
    }
}

struct TrackingParametersTests {
    @Test func stripsTrackersAndKeepsTheRest() {
        let url = URL(string: "https://shop.example/p?id=42&utm_source=mail&fbclid=abc&color=red")!
        #expect(TrackingParameters.stripped(url)?.absoluteString == "https://shop.example/p?id=42&color=red")
    }

    @Test func dropsEmptyQuery() {
        let url = URL(string: "https://example.com/?gclid=xyz")!
        #expect(TrackingParameters.stripped(url)?.absoluteString == "https://example.com/")
    }

    @Test func leavesCleanURLsAlone() {
        #expect(TrackingParameters.stripped(URL(string: "https://example.com/?q=1")!) == nil)
    }

    @Test func keepsTheOtherParametersExactlyAsSent() {
        let url = URL(string: "https://example.com/login?token=a%2Bb%2Fc%3D&utm_source=mail&q=c%2B%2B")!
        #expect(TrackingParameters.stripped(url)?.absoluteString == "https://example.com/login?token=a%2Bb%2Fc%3D&q=c%2B%2B")
    }

    /// Values Foundation's query items may refuse when set back (a literal "=" in a token, a
    /// bare flag, an empty pair, an address in a value) are kept as sent, without stopping the app.
    @Test func keepsOddValuesAsSent() {
        let url = URL(string: "https://example.com/?token=abc==&utm_source=x&flag&&next=/a?b=c&UTM_Medium=y")!
        #expect(TrackingParameters.stripped(url)?.absoluteString == "https://example.com/?token=abc==&flag&&next=/a?b=c")
    }
}

struct FilterPreprocessorTests {
    @Test(arguments: [
        ("env_safari", true),
        ("!env_safari", false),
        ("env_chromium || env_safari", true),
        ("env_safari && !cap_html_filtering", true),
        ("env_safari && cap_html_filtering", false),
        ("!(env_firefox || env_chromium)", true),
    ])
    func evaluatesConditions(expression: String, expected: Bool) {
        #expect(FilterUpdater.evaluate(expression, trueTokens: ["env_safari", "adguard"]) == expected)
    }
}

@MainActor
struct FaviconTests {
    @Test func rejectsSVGsStyledOnlyWithCSSAndKeepsRealIcons() throws {
        let cssStyled = #"<svg xmlns="http://www.w3.org/2000/svg" width="180" height="180" fill="none"><style>:root{fill:#000}</style><path d="M10 10h160v160H10z"/></svg>"#
        #expect(Favicons.normalized(Data(cssStyled.utf8)) == nil)

        let plain = ##"<svg xmlns="http://www.w3.org/2000/svg" width="180" height="180"><path fill="#10a37f" d="M10 10h160v160H10z"/></svg>"##
        let png = try #require(Favicons.normalized(Data(plain.utf8)))
        #expect(NSImage(data: png)?.size == NSSize(width: 64, height: 64))
    }

    /// Hosts without an icon are remembered for the session, but only so many of them.
    @Test func remembersABoundedNumberOfHostsWithoutIcons() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "favicons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let favicons = Favicons(folder: folder, missingLimit: 2)
        // Each server answers every path with an empty page: no icon anywhere.
        var hosts: [String] = []
        for _ in 1...3 {
            let (server, base) = try await LocalHTTP.serve([String: (headers: String, body: Data)]())
            defer { server.cancel() }
            let host = "127.0.0.1:\(try #require(base.port))"
            _ = await favicons.icon(forHost: host, scheme: "http")
            hosts.append(host)
        }
        #expect(favicons.missing == [hosts[2]])
    }

    /// A fetch that found no server (offline, timed out) isn't an answer: the host is asked again.
    @Test func anUnreachableHostIsAskedAgain() async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "favicons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let favicons = Favicons(folder: folder)
        // Nothing listens on this port: each fetch fails at once.
        #expect(await favicons.icon(forHost: "127.0.0.1:1", scheme: "http") == nil)
        #expect(favicons.missing.isEmpty)
    }
}

struct DeclaredIconTests {
    @Test func findsIconLinksAndPrefersRaster() {
        let html = """
            <link rel="stylesheet" href="/app.css">
            <link rel="icon" type="image/svg+xml" href="https://cdn.example.net/favicon.svg"/>
            <LINK REL='shortcut icon' HREF='/favicon.ico'>
            <link href="/touch.png" rel="apple-touch-icon" sizes="180x180">
            """
        let urls = Favicons.declaredIcons(in: html, base: URL(string: "https://example.com/")!).map(\.absoluteString)
        #expect(urls == ["https://example.com/favicon.ico", "https://example.com/touch.png", "https://cdn.example.net/favicon.svg"])
    }
}

@MainActor
struct SiteGroupingTests {
    @Test(arguments: [
        ("gist.github.com", "github.com"),
        ("www.bbc.co.uk", "bbc.co.uk"),
        ("GitHub.com", "github.com"),
        ("localhost", "localhost"),
    ])
    func groupsSubdomainsUnderTheRegistrableDomain(host: String, site: String) {
        #expect(SiteInfo.registrable(host) == site)
    }

    /// An IP host is its own site: grouping by the last labels made "Clear site data" on
    /// 192.168.0.1 clear 10.0.0.1 too ("0.1" for both).
    @Test(arguments: [
        ("192.168.0.1", "192.168.0.1"),
        ("10.0.0.1", "10.0.0.1"),
        ("[::1]", "::1"),
        ("::1", "::1"),
        ("[FE80::1]", "fe80::1"),
    ])
    func ipAddressesAreTheirOwnSite(host: String, site: String) {
        #expect(SiteInfo.registrable(host) == site)
    }
}
