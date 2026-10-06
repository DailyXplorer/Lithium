import AppKit
import Foundation
import Testing
@testable import Lithium

/// p50 and p95 of the agent operations in design section 6.7, on fixture pages, printed, never
/// asserted: `LITHIUM_AGENT_BENCH=1 scripts/test --filter AgentBenchmarks`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["LITHIUM_AGENT_BENCH"] == "1" && ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct AgentBenchmarks {
    private static let pages: [String: (headers: String, body: String)] = [
        "/bench": ("Content-Type: text/html", """
            <title>Bench</title><style>body { margin: 0 }</style>
            <button id="b" style="position:absolute;left:40px;top:40px;width:120px;height:40px" onclick="window.clickedAt = Date.now()">Press</button>
            <input id="field" aria-label="Field" style="position:absolute;left:40px;top:120px;width:300px">
            """),
    ]

    private static func report(_ name: String, _ samples: [Duration]) {
        let sorted = samples.map { $0 / .milliseconds(1) }.sorted()
        let at = { (fraction: Double) in sorted[min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.down)))] }
        print(String(format: "AgentBenchmarks %@: p50 %.1f ms, p95 %.1f ms (%d runs)", name, at(0.5), at(0.95), sorted.count))
    }

    @Test func clickTypeAndStaging() async throws {
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        let (listener, base) = try await LocalHTTP.serve(Self.pages)
        defer { listener.cancel() }
        let browser = Browser()
        await browser.privacy.waitUntilReady()
        await browser.extensions.waitUntilLoaded()
        await browser.setAgentAccess(true)
        defer {
            browser.tabs.forEach(browser.close)
            Task { await browser.setAgentAccess(false) }
        }
        let client = try await AgentTabsTests.Client(browser: browser)
        let clock = ContinuousClock()
        let opened = await client.call("tab_open", ["url": .string(base.appending(path: "bench").absoluteString), "wait": "load"])
        let id = try #require(opened["tab"]?.string)
        let snapshot = await client.call("snapshot", ["tab": .string(id), "format": "json"])
        guard case .array(let nodes)? = snapshot["nodes"] else { throw CancellationError() }
        let press = try #require(nodes.first { $0["name"] == "Press" }?["ref"]?.string)
        let field = try #require(nodes.first { $0["name"] == "Field" }?["ref"]?.string)

        let tab = try #require(client.tab(id))
        var seen: [Duration] = []
        var calls: [Duration] = []
        for _ in 0..<40 {
            let started = Date()
            calls.append(try await clock.measure {
                let result = await client.call("click", ["tab": .string(id), "ref": .string(press), "diff": false])
                #expect(!result.isError, "\(result.content)")
            })
            let clickedAt = try await tab.webView.callAsyncJavaScript("return window.clickedAt", contentWorld: .page) as? Double ?? 0
            seen.append(.milliseconds(Int(clickedAt - started.timeIntervalSince1970 * 1000)))
        }
        Self.report("click by ref, until the page saw click (checks included)", Array(seen.dropFirst(5)))
        Self.report("click by ref, whole call (settling included, diff off)", Array(calls.dropFirst(5)))
        var frames: [Duration] = []
        for _ in 0..<10 {
            let frame = try await tab.webView.callAsyncJavaScript("const t = performance.now(); return await new Promise((resolve) => requestAnimationFrame(() => resolve(performance.now() - t)))", contentWorld: .page) as? Double ?? -1
            frames.append(.microseconds(Int(frame * 1000)))
        }
        Self.report("requestAnimationFrame in a staged tab", frames)

        let text = String(repeating: "abcdefghij", count: 5)
        var typing: [Duration] = []
        for _ in 0..<12 {
            typing.append(try await clock.measure {
                let result = await client.call("type", ["tab": .string(id), "ref": .string(field), "text": .string(text), "clear": true, "diff": false])
                #expect(!result.isError, "\(result.content)")
            })
        }
        Self.report("type 50 ASCII characters", Array(typing.dropFirst(2)))

        // Loaded in the background, never staged, then put in the stage until its page is visible.
        var staging: [Duration] = []
        for _ in 0..<10 {
            let other = await client.call("tab_open", ["url": .string(base.appending(path: "bench").absoluteString), "wait": "load"])
            let tab = try #require(client.tab(other["tab"]?.string ?? ""))
            staging.append(try await clock.measure {
                let webView = client.hub.staged(tab)
                while try await webView.callAsyncJavaScript("return document.visibilityState", contentWorld: .page) as? String != "visible" {}
            })
            browser.close(tab)
        }
        Self.report("staging a background tab (already loaded)", staging)
    }
}
