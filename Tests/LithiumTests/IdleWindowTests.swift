import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Lithium

/// The whole window, off screen, on amazon.fr, the page measured at ~10 % CPU idle. It builds a
/// Browser, which keeps its data in the home folder, and needs the network, so it only runs in a
/// throwaway home when asked:
/// `CFFIXED_USER_HOME=$(mktemp -d) LITHIUM_LIVE_TESTS=1 swift test --filter IdleWindowTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil
    && ProcessInfo.processInfo.environment["LITHIUM_LIVE_TESTS"] == "1"))
struct IdleWindowTests {
    /// With amazon.fr idle, Lithium's main thread runs no SwiftUI repeating animation, and rests once
    /// the page's own endless animations are paused. A diagnostic: it passes on main too, and only
    /// shows the wakeups follow the page's animations, not what they cost on screen.
    @Test func amazonIdleRunsNoRepeatingAnimation() async throws {
        let wakeups = WindowWakeups()
        defer { wakeups.stop() }

        // The control: `sample` sees a `repeatForever` that runs in a window never shown.
        let control = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 20, height: 20), styleMask: [.borderless], backing: .buffered, defer: false)
        control.isReleasedWhenClosed = false
        control.contentView = NSHostingView(rootView: Repeating())
        control.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(300))
        let repeating = try await sample(wakeups)
        control.orderOut(nil)
        control.contentView = nil
        print("IDLE control: \(repeating)")
        #expect(repeating.repeatAnimations > 0, "sample sees a repeatForever (\(repeating))")

        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "https://www.amazon.fr/")!)
        // As in front on screen: the page counts as visible, so it renders its animations.
        let occlusion = Selector(("_setWindowOcclusionDetectionEnabled:"))
        if tab.webView.responds(to: occlusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(tab.webView.method(for: occlusion), to: Setter.self)(tab.webView, occlusion, false)
        }
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 820),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserView().environment(browser))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        var waited = 0
        while tab.isLoading || tab.url == nil, waited < 300 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        try await Task.sleep(for: .seconds(4))
        #expect(!tab.isLoading)

        let idle = try await sample(wakeups)
        print("IDLE amazon.fr idle: \(idle)")
        #expect(idle.repeatAnimations == 0, "a SwiftUI repeating animation runs with amazon.fr idle (\(idle))")

        let animations = try await tab.webView.callAsyncJavaScript("""
            const all = document.getAnimations();
            all.forEach(a => a.pause());
            return all.map(a => (a.animationName || a.constructor.name) + ' ' + a.effect?.getTiming().iterations + ' on .'
              + String(a.effect?.target?.className ?? '').split(' ')[0] + (a.effect?.target?.checkVisibility() ? ' shown' : ' hidden')).join(', ');
            """, contentWorld: .page)
        try await Task.sleep(for: .seconds(1))
        let still = try await sample(wakeups)
        print("IDLE page animations paused (\(String(describing: animations).prefix(220))): \(still)")
        #expect(still.wakeups < 200, "Lithium keeps waking with the page still (\(still))")
    }
}

/// A `repeatForever` that nothing stops, as the agent button had.
private struct Repeating: View {
    @State private var on = false

    var body: some View {
        Rectangle().frame(width: 20, height: 20)
            .opacity(on ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.6).repeatForever(), value: on)
            .onAppear { on = true }
    }
}

private struct Sampled: CustomStringConvertible {
    var wakeups: Int
    var repeatAnimations: Int
    var busy: Int
    var samples: Int

    var description: String {
        "\(wakeups) wakeups in 3 s, main thread busy in \(busy) of \(samples) samples, \(repeatAnimations) RepeatAnimation frames"
    }
}

/// Samples this process for 3 s with `/usr/bin/sample` and counts wakeups meanwhile.
@MainActor
private func sample(_ wakeups: WindowWakeups) async throws -> Sampled {
    let start = wakeups.total.value
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("lithium-idle-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    process.arguments = [String(getpid()), "3", "-mayDie", "-file", file.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    while process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
    let count = wakeups.total.value - start
    let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").components(separatedBy: "\n")
    // The main thread's samples, and those of them spent waiting in the run loop.
    let header = lines.firstIndex { $0.contains("com.apple.main-thread") } ?? lines.endIndex
    let thread = lines[header...].dropFirst().prefix { !$0.contains("Thread_") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let main = lines[header...].first.flatMap { Int($0.drop { $0 == " " }.prefix { $0.isNumber }) } ?? 0
    let waiting = thread.filter { $0.contains("__CFRunLoopServiceMachPort") }
        .compactMap { Int($0.drop { " +!:|".contains($0) }.prefix { $0.isNumber }) }.max() ?? 0
    return Sampled(wakeups: count, repeatAnimations: lines.filter { $0.contains("RepeatAnimation") }.count,
                   busy: max(main - waiting, 0), samples: main)
}

/// Counts the times the main run loop wakes up: once a frame while anything animates.
@MainActor
private final class WindowWakeups {
    final class Count: @unchecked Sendable { var value = 0 }
    let total = Count()
    private let observer: CFRunLoopObserver

    init() {
        let total = total
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, _ in total.value += 1 }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func stop() {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
