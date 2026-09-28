import AppKit
import Foundation
import SQLite3
import Testing
import WebKit
@testable import Lithium

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LITHIUM_PERF_OUTPUT"] != nil))
struct HeadlessPerformanceTests {
    private var output: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["LITHIUM_PERF_OUTPUT"]!) }
    private var root: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["LITHIUM_PERF_ROOT"]!) }

    private func save(_ value: Any, _ name: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output.appending(path: name + ".json"))
        print("PERF saved \(name)")
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    private func page(_ configuration: WKWebViewConfiguration) async throws -> WKWebView {
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        view.loadHTMLString("<!doctype html><html><head><title>Isolated performance fixture</title></head><body></body></html>", baseURL: URL(string: "http://127.0.0.1/"))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { return view }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CocoaError(.fileReadUnknown)
    }

    @Test func webWorkloads() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let privacy = Privacy()
        let script = try source("scripts/bench/workloads.js")
        let variants = ProcessInfo.processInfo.environment["LITHIUM_PERF_VARIANTS"]?.split(separator: ",").map(String.init) ?? ["webkit", "previous", "current"]
        var records: [[String: Any]] = []
        for variant in variants {
            let configuration = variant == "webkit" ? WKWebViewConfiguration() : privacy.makeConfiguration()
            if variant == "current" {
                PageStyle.scripts(for: URL(string: "http://127.0.0.1/")!).forEach(configuration.userContentController.addUserScript)
                privacy.scripts(true, for: URL(string: "http://127.0.0.1/")!).forEach(configuration.userContentController.addUserScript)
                Privacy.setEngineProtections(true, on: configuration.defaultWebpagePreferences)
            } else if variant == "previous" {
                let font = try Data(contentsOf: root.appending(path: "Sources/Lithium/Resources/Fonts/DMSans.woff2")).base64EncodedString()
                for (name, world) in [("page-font", WKContentWorld.defaultClient), ("farbling", .page)] {
                    let raw = try String(contentsOf: output.appending(path: name + "-head.js"), encoding: .utf8)
                    let source = raw.replacingOccurrences(of: "__LITHIUM_FONT__", with: font).replacingOccurrences(of: "__LITHIUM_SESSION_KEY__", with: "1234567890abcdef1234567890abcdef")
                    configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: name == "page-font", in: world))
                }
                Privacy.setEngineProtections(true, on: configuration.defaultWebpagePreferences)
            }
            let view = try await page(configuration)
            defer { view.stopLoading() }
            _ = try await view.evaluateJavaScript(script)
            for name in ["json", "dom", "layout", "canvas"] {
                try await Task.sleep(for: .milliseconds(300))
                var record = try #require(try await view.evaluateJavaScript("perfCase('\(name)')") as? [String: Any])
                record["variant"] = variant
                record["installedScripts"] = configuration.userContentController.userScripts.count
                record["protectedRealm"] = try await view.evaluateJavaScript("Object.getOwnPropertyNames(window).some(k => /^__[a-z0-9]+$/.test(k))")
                records.append(record)
                try save(records, "webkit-workloads")
            }
        }
    }

    @Test func fontMutationCosts() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let instrument = """
            globalThis.perfFont = {milliseconds: 0, callbacks: 0, styleReads: 0};
            const readStyle = globalThis.getComputedStyle;
            globalThis.getComputedStyle = function(...args) { perfFont.styleReads++; return Reflect.apply(readStyle, this, args); };
            for (const name of ['requestAnimationFrame', 'setTimeout']) {
              const original = globalThis[name];
              globalThis[name] = function(callback, ...args) {
                return Reflect.apply(original, this, [function(...values) {
                  const start = performance.now();
                  try { return callback(...values); }
                  finally { perfFont.milliseconds += performance.now() - start; perfFont.callbacks++; }
                }, ...args]);
              };
            }
            """
        var records: [[String: Any]] = []
        for variant in ["previous", "current"] {
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.addUserScript(WKUserScript(source: instrument, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
            if variant == "current" { configuration.userContentController.addUserScript(PageStyle.fontScript) }
            else {
                let font = try Data(contentsOf: root.appending(path: "Sources/Lithium/Resources/Fonts/DMSans.woff2")).base64EncodedString()
                let raw = try String(contentsOf: output.appending(path: "page-font-head.js"), encoding: .utf8)
                configuration.userContentController.addUserScript(WKUserScript(source: raw.replacingOccurrences(of: "__LITHIUM_FONT__", with: font), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
            }
            let view = try await page(configuration)
            defer { view.stopLoading() }
            _ = try await view.evaluateJavaScript("document.body.innerHTML = '<style>.special .icon {font-family: Menlo, monospace}</style><main id=feed>' + '<div><span>Article content</span><i class=icon>x</i></div>'.repeat(1500) + '</main>'")
            try await Task.sleep(for: .milliseconds(700))
            for iteration in 0..<6 {
                _ = try await view.callAsyncJavaScript("perfFont = {milliseconds: 0, callbacks: 0, styleReads: 0}", contentWorld: .defaultClient)
                _ = try await view.evaluateJavaScript("document.getElementById('feed').className = '\(iteration % 2 == 0 ? "special" : "")'")
                try await Task.sleep(for: .milliseconds(450))
                var value = try #require(try await view.callAsyncJavaScript("return JSON.parse(JSON.stringify(perfFont))", contentWorld: .defaultClient) as? [String: Any])
                value["variant"] = variant
                value["iteration"] = iteration
                value["iconFont"] = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('.icon')).fontFamily")
                records.append(value)
            }
        }
        try save(records, "font-mutations")
    }

    @Test func nativeContentRules() async throws {
        guard let base = ProcessInfo.processInfo.environment["LITHIUM_PERF_SERVER"], let baseURL = URL(string: base) else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = WKContentRuleListStore(url: output.appending(path: "rule-cache"))!
        let folder = try #require(Resources.bundle.url(forResource: "Filters", withExtension: nil))
        var lists: [String: [WKContentRuleList]] = ["none": [], "raw": [], "prepared": []]
        var compileRecords: [[String: Any]] = []
        for variant in ["raw", "prepared"] {
            for group in ["ads", "privacy", "security"] {
                let file = folder.appending(path: group + ".json")
                let start = ProcessInfo.processInfo.systemUptime
                let json: String
                if variant == "raw" { json = try String(contentsOf: file, encoding: .utf8) }
                else { json = try #require(Privacy.prepared(file)) }
                let compiled = try #require(try await store.compileContentRuleList(forIdentifier: variant + group, encodedContentRuleList: json))
                lists[variant]!.append(compiled)
                compileRecords.append(["variant": variant, "group": group, "milliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000])
                try save(compileRecords, "rule-compilation")
            }
        }
        let cosmeticFile = output.appending(path: "cosmetic-fixture.json")
        let cosmetic = #"[{"trigger":{"url-filter":".*","if-domain":["127.0.0.1"]},"action":{"type":"css-display-none","selector":".audit-ad"}}]"#
        try Data(cosmetic.utf8).write(to: cosmeticFile)
        for variant in ["raw", "prepared"] {
            let json = variant == "raw" ? cosmetic : try #require(Privacy.prepared(cosmeticFile))
            lists[variant]!.append(try #require(try await store.compileContentRuleList(forIdentifier: variant + "cosmetic", encodedContentRuleList: json)))
        }
        var records: [[String: Any]] = []
        for round in 0..<5 {
            let order = round % 2 == 0 ? ["none", "raw", "prepared"] : ["prepared", "raw", "none"]
            for variant in order {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                lists[variant]!.forEach(configuration.userContentController.add)
                let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
                view.load(URLRequest(url: baseURL.appending(path: "page")))
                let deadline = Date().addingTimeInterval(30)
                var result: [String: Any]?
                while Date() < deadline {
                    if !view.isLoading, let value = try? await view.evaluateJavaScript("document.readyState === 'complete' && window.loadedScripts === 160 ? JSON.parse(JSON.stringify({load: performance.getEntriesByType('navigation')[0].loadEventEnd, resources: performance.getEntriesByType('resource').length, scripts: window.loadedScripts, adDisplay: getComputedStyle(document.querySelector('.audit-ad')).display})) : null") as? [String: Any] { result = value; break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                var record = try #require(result)
                #expect(record["scripts"] as? Int == 160)
                #expect(record["adDisplay"] as? String == (variant == "none" ? "block" : "none"))
                record["variant"] = variant
                record["round"] = round
                records.append(record)
                view.stopLoading()
                try save(records, "native-rules")
            }
        }
        try save(NSApplication.shared.windows.map { ["class": String(describing: type(of: $0)), "visible": $0.isVisible] }, "test-windows")
        #expect(NSApplication.shared.windows.allSatisfy { !$0.isVisible })
    }

    @Test func historySearch() async throws {
        var records: [[String: Any]] = []
        for count in [10_000, 200_000] {
            let file = output.appending(path: "history-\(count).sqlite")
            let history = HistoryStore(fileURL: file)
            var db: OpaquePointer?
            #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            let sql = """
                DELETE FROM visits;
                WITH RECURSIVE seq(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM seq WHERE x<\(count))
                INSERT INTO visits(url,title,visited_at) SELECT 'https://site' || (x%5000) || '.example/article/' || (x%20000), 'Article ' || x, x FROM seq;
                """
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
            for query in ["site", "article 123", "zzzznomatch"] {
                for mode in ["sync", "background"] {
                    var samples: [Double] = []
                    var resultCount = 0
                    for _ in 0..<5 {
                        let start = ProcessInfo.processInfo.systemUptime
                        if mode == "sync" { resultCount = history.topSites(matching: query, limit: 8).count }
                        else { resultCount = await history.topSitesInBackground(matching: query, limit: 8)?.count ?? -1 }
                        samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                    }
                    records.append(["visits": count, "query": query, "mode": mode, "samples": samples, "resultCount": resultCount])
                }
            }
        }
        try save(records, "history-search")
    }
}
