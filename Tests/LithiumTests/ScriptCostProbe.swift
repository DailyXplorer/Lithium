import AppKit
import CryptoKit
import Darwin
import Foundation
import Testing
import WebKit
@testable import Lithium

/// Not a test: what the scripts Lithium adds to every page cost a page, as the CPU time its process
/// spends loading one, with and without each script. The page is off screen and loads from a
/// string, so nothing but the scripts changes between two lines. Runs only when asked:
/// `LITHIUM_SCRIPT_COST=1 scripts/test --filter ScriptCostProbe`.
/// With `LITHIUM_SCRIPT_COST_BASELINE` naming a folder that holds another commit's `page-font.js`
/// and `farbling.js`, those are measured in the same run, in turn with the working copy's.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LITHIUM_SCRIPT_COST"] == "1"))
struct ScriptCostProbe {
    private final class Sink: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
    }

    private struct Variant {
        let name: String
        var scripts: [WKUserScript] = []
    }

    private static let loads = 20
    private static let rounds = 4
    private static let frames = 300

    private static let paragraphs = (0..<400)
        .map { "<p class=\"p\($0 % 7)\">Paragraph \($0) with <a href=\"#\">a link</a>, <b>bold</b> and <span>a span</span>.</p>" }.joined()
    private static let style = "<style>body{font-family:Georgia,serif}.p3{font-family:Menlo,monospace}</style>"
    private static let pages = [
        ("1,600 elements", "<!doctype html><title>page</title>\(style)<body><h1>Title</h1>\(paragraphs)</body>"),
        ("1,600 elements and 20 frames", "<!doctype html><title>page</title>\(style)<body><h1>Title</h1>\(paragraphs)"
            + (0..<20).map { "<iframe srcdoc=\"<p>frame \($0)</p>\"></iframe>" }.joined() + "</body>"),
    ]

    /// Each script alone, then all of them, for every page of `pages`: CPU milliseconds a load.
    @Test func eachPageLoad() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let variants = try Self.variants()
        for (pageName, page) in Self.pages {
            var samples: [String: [Double]] = [:]
            // In turn, starting one further each round: what else the Mac does, and how long the
            // run has lasted, weigh on all alike. Measured one after the other, the last was 5% slower.
            for round in 0..<Self.rounds {
                for index in variants.indices {
                    let variant = variants[(index + round) % variants.count]
                    samples[variant.name, default: []].append(try await cpu(loading: page, with: variant.scripts))
                }
            }
            for variant in variants {
                let runs = try #require(samples[variant.name])
                print(String(format: "SCRIPTCOST %@ | %@: %.1f ms (%@)", pageName, variant.name, Self.median(runs),
                             runs.map { String(format: "%.1f", $0) }.joined(separator: " ")))
            }
        }
    }

    /// Frames a script adds once the page has loaded, one after the other: milliseconds for all of them.
    @Test func eachFrame() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let variants = try Self.variants()
        var samples: [String: [Double]] = [:]
        for round in 0..<Self.rounds {
            for index in variants.indices {
                let variant = variants[(index + round) % variants.count]
                samples[variant.name, default: []].append(try await time(addingFramesWith: variant.scripts))
            }
        }
        for variant in variants {
            let runs = try #require(samples[variant.name])
            print(String(format: "SCRIPTCOST %d frames | %@: %.0f ms (%@)", Self.frames, variant.name, Self.median(runs),
                         runs.map { String(format: "%.0f", $0) }.joined(separator: " ")))
        }
    }

    private static func variants() throws -> [Variant] {
        let key = SymmetricKey(size: .bits256)
        func farbling(_ template: String) -> [WKUserScript] {
            [WKUserScript(source: Privacy.farbling(template, key: key, site: "example.com"), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)]
        }
        // With a family the Mac has, so the font's own bytes aren't what is measured; `embedded` adds them.
        func font(_ source: String, embedded: Bool = false) -> [WKUserScript] {
            let text = source.replacingOccurrences(of: "__LITHIUM_FONT__", with: embedded ? PageStyle.scriptFontBase64 : "")
                .replacingOccurrences(of: "__LITHIUM_FAMILY__", with: embedded ? "\"Lithium DM Sans\"" : "\"Helvetica Neue\"")
            return [WKUserScript(source: text, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)]
        }
        func shipped(_ name: String) throws -> String {
            try String(contentsOf: try #require(Resources.bundle.url(forResource: name, withExtension: "js")), encoding: .utf8)
        }
        // A loopback address keeps its own font: only the style every page gets.
        let base = PageStyle.scripts(for: URL(string: "http://127.0.0.1/")!)
        let others = [NowPlaying.script, UnsavedInput.script]
        var variants = [Variant(name: "no script")]
        var sets = [("", try shipped("page-font"), try shipped("farbling"))]
        if let folder = ProcessInfo.processInfo.environment["LITHIUM_SCRIPT_COST_BASELINE"].map(URL.init(fileURLWithPath:)) {
            sets.insert((", baseline", try String(contentsOf: folder.appending(path: "page-font.js"), encoding: .utf8),
                         try String(contentsOf: folder.appending(path: "farbling.js"), encoding: .utf8)), at: 0)
        }
        for (label, fontSource, farblingSource) in sets {
            variants.append(Variant(name: "font script\(label)", scripts: base + font(fontSource)))
            variants.append(Variant(name: "farbling\(label)", scripts: farbling(farblingSource)))
            variants.append(Variant(name: "every script, DM Sans carried\(label)", scripts: base + font(fontSource, embedded: true) + farbling(farblingSource) + others))
        }
        return variants
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
    }

    /// In a window no screen shows, which WebKit takes for visible: a page out of any window gets no frame callback.
    private func webView(with scripts: [WKUserScript]) throws -> (WKWebView, NSWindow) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let sink = Sink()
        for name in [NowPlaying.name, UnsavedInput.name] {
            configuration.userContentController.add(sink, contentWorld: .page, name: name)
        }
        scripts.forEach(configuration.userContentController.addUserScript)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        let occlusion = Selector(("_setWindowOcclusionDetectionEnabled:"))
        if webView.responds(to: occlusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: occlusion), to: Setter.self)(webView, occlusion, false)
        }
        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        return (webView, window)
    }

    private func load(_ page: String, in webView: WKWebView) async throws {
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.loadHTMLString(page, baseURL: URL(string: "https://example.com/"))
        try await loaded.wait()
        // The font's decoding and the first style pass end after `load`.
        _ = try await webView.callAsyncJavaScript("await document.fonts.ready; return document.body.offsetHeight", contentWorld: .defaultClient)
    }

    private func cpu(loading page: String, with scripts: [WKUserScript]) async throws -> Double {
        let (webView, window) = try webView(with: scripts)
        defer { window.orderOut(nil) }
        for _ in 0..<3 { try await load(page, in: webView) }
        let pid = try #require((webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value)
        let before = Self.cpuTime(of: pid)
        for _ in 0..<Self.loads { try await load(page, in: webView) }
        #expect((webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value == pid, "the page changed process mid-run")
        return (Self.cpuTime(of: pid) - before) / Double(Self.loads)
    }

    private func time(addingFramesWith scripts: [WKUserScript]) async throws -> Double {
        let (webView, window) = try webView(with: scripts)
        defer { window.orderOut(nil) }
        try await load("<!doctype html><title>frames</title><body></body>", in: webView)
        let elapsed = try await webView.callAsyncJavaScript("""
            const start = performance.now();
            for (let i = 0; i < count; i++) {
              await new Promise((resolve) => {
                const frame = document.createElement('iframe');
                frame.onload = resolve;
                frame.srcdoc = '<p>frame</p>';
                document.body.append(frame);
              });
            }
            return performance.now() - start;
            """, arguments: ["count": Self.frames], contentWorld: .defaultClient) as? Double
        return try #require(elapsed)
    }

    /// Milliseconds of CPU the process has used, on every thread: compiling and collecting count too.
    private static func cpuTime(of pid: pid_t) -> Double {
        var info = rusage_info_v4()
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e6
    }
}
