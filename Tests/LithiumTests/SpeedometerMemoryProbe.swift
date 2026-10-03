import AppKit
import Darwin
import Foundation
import Testing
import WebKit
@testable import Lithium

/// Not a test: where a heavy page's memory goes (Lithium, the page's process, the GPU process)
/// during and after Speedometer, and what putting its tab to sleep gives back. The window is off
/// screen. Runs only when asked, in a throwaway home, and writes to /tmp/lithium-memory-probe.log
/// (outside the home, which scripts/test deletes):
/// `LITHIUM_MEMORY_PROBE=1 scripts/test --filter SpeedometerMemoryProbe`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LITHIUM_MEMORY_PROBE"] == "1"
    && ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct SpeedometerMemoryProbe {
    @Test func probe() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let browser = Browser()
        log("PROBE start")
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let blank = browser.newTab(url: URL(string: "data:text/html,blank")!)
        try await Task.sleep(for: .seconds(3))
        let tab = browser.newTab(url: URL(string: "https://browserbench.org/Speedometer3.1/?iterationCount=4&startAutomatically")!)
        show(tab, in: window)
        _ = await poll(60) { tab.webProcessIdentifier != nil && !tab.isLoading }
        try await Task.sleep(for: .seconds(5))
        report("loaded", browser: browser, tab: tab)
        for second in stride(from: 20, through: 220, by: 20) {
            try await Task.sleep(for: .seconds(20))
            log("PROBE t=\(second)s url=\(tab.webView.url?.absoluteString ?? "nil")")
            report("t=\(second)s", browser: browser, tab: tab)
        }
        report("after run", browser: browser, tab: tab)
        try await Task.sleep(for: .seconds(20))
        report("after run +20s", browser: browser, tab: tab)

        let gpu = gpuPID(tab)
        let content = tab.webProcessIdentifier
        browser.select(blank)
        window.contentView = blank.webView
        try await Task.sleep(for: .seconds(10))
        report("hidden 10s", browser: browser, tab: tab)
        browser.relieveMemoryPressure(critical: true)
        try await Task.sleep(for: .seconds(10))
        log("PROBE asleep=\(tab.isAsleep) contentAlive=\(content.map { kill($0, 0) == 0 } ?? false)")
        report("after critical pressure sleep +10s", browser: browser, tab: blank, extraGPU: gpu)
        try await Task.sleep(for: .seconds(30))
        report("+40s", browser: browser, tab: blank, extraGPU: gpu)
    }

    private func show(_ tab: Tab, in window: NSWindow) {
        let occlusion = Selector(("_setWindowOcclusionDetectionEnabled:"))
        if tab.webView.responds(to: occlusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(tab.webView.method(for: occlusion), to: Setter.self)(tab.webView, occlusion, false)
        }
        window.contentView = tab.webView
        window.orderFrontRegardless()
    }

    private func log(_ line: String) {
        print(line)
        let url = URL(fileURLWithPath: "/tmp/lithium-memory-probe.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: url)
        }
    }

    private func gpuPID(_ tab: Tab) -> pid_t? {
        let selector = Selector(("_gpuProcessIdentifier"))
        guard tab.webView.responds(to: selector) else { return nil }
        return (tab.webView.value(forKey: "_gpuProcessIdentifier") as? NSNumber)?.int32Value
    }

    private func footprint(_ pid: pid_t) -> String {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return "n/a" }
        return "\(info.ri_phys_footprint / 1_048_576) MB"
    }

    private func report(_ label: String, browser: Browser, tab: Tab, extraGPU: pid_t? = nil) {
        var line = "PROBE [\(label)] app=\(footprint(getpid()))"
        if let content = tab.webProcessIdentifier { line += " content(\(content))=\(footprint(content))" }
        if let gpu = gpuPID(tab) ?? extraGPU { line += " gpu(\(gpu))=\(footprint(gpu))" }
        for other in browser.tabs where other !== tab {
            if let pid = other.webProcessIdentifier { line += " other(\(pid))=\(footprint(pid))" }
        }
        log(line)
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        let mine = (extraGPU ?? gpuPID(tab) ?? tab.webProcessIdentifier ?? 0) - 20
        for row in text.split(separator: "\n") where row.contains("com.apple.WebKit") {
            let fields = row.split(separator: " ", omittingEmptySubsequences: true)
            guard let pid = Int32(fields[0]), pid > mine else { continue }
            log("PROBE   \(fields.last ?? "") \(pid) \(footprint(pid))")
        }
    }

    private func poll(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return await condition()
    }
}
