import AppKit
import Observation
import SwiftUI
import Testing
@testable import Lithium

/// The toolbar's agent button stops drawing once an agent's call ends: an endless animation left
/// running wakes the app's main thread at the display's rate, on an idle page too, for as long as
/// the agent stays connected.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AgentPulseTests {
    @Test func pulseDimsAndComesBack() {
        #expect(ActingPulse.opacity(after: 0) == 1)
        #expect(abs(ActingPulse.opacity(after: 0.3) - 0.725) < 1e-9)
        #expect(abs(ActingPulse.opacity(after: 0.6) - 0.45) < 1e-9)
        #expect(abs(ActingPulse.opacity(after: 1.2) - 1) < 1e-9)
        #expect(ActingPulse.opacity(after: -1) == 1)
    }

    @Test func pulseStopsWhenTheCallEnds() async throws {
        let agent = Acting()
        let (window, wakeups) = host(PulseHost(agent: agent))
        defer {
            wakeups.stop()
            window.orderOut(nil)
            window.contentView = nil
        }
        try await Task.sleep(for: .milliseconds(200))

        agent.isActing = true
        let acting = try await wakeups.count(over: .seconds(1))
        agent.isActing = false
        try await Task.sleep(for: .milliseconds(300))
        let after = try await wakeups.count(over: .seconds(1))
        #expect(acting >= 30, "the pulse draws while the agent acts (\(acting) wakeups)")
        #expect(after * 4 < acting, "\(after) wakeups a second after the call, \(acting) during it")
    }

    /// The control for the test above: the button's pulse as it was runs on after the call, and
    /// the count sees it in a window no screen shows. Without it, a pulse that "stops" could only
    /// mean the count sees nothing there.
    @Test func wakeupsSeeARepeatingAnimationThatRunsOn() async throws {
        let agent = Acting()
        let (window, wakeups) = host(RepeatingPulseHost(agent: agent))
        defer {
            wakeups.stop()
            window.orderOut(nil)
            window.contentView = nil
        }
        try await Task.sleep(for: .milliseconds(200))

        agent.isActing = true
        try await Task.sleep(for: .milliseconds(300))
        agent.isActing = false
        try await Task.sleep(for: .milliseconds(300))
        let after = try await wakeups.count(over: .milliseconds(600))
        #expect(after >= 30, "the pulse as it was still draws after the call (\(after) wakeups in 0.6 s)")
    }

    /// In a window, where SwiftUI animates, far off screen.
    private func host(_ view: some View) -> (NSWindow, MainThreadWakeups) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 20, height: 20), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        return (window, MainThreadWakeups())
    }
}

@MainActor @Observable
private final class Acting {
    var isActing = false
}

private struct PulseHost: View {
    let agent: Acting

    var body: some View {
        Rectangle().frame(width: 20, height: 20).modifier(ActingPulse(isOn: agent.isActing))
    }
}

/// `AgentButton`'s pulse before the fix: a `repeatForever` that nothing replaces once the call ends.
private struct RepeatingPulseHost: View {
    let agent: Acting
    @State private var pulse = false

    var body: some View {
        Rectangle().frame(width: 20, height: 20)
            .opacity(agent.isActing && pulse ? 0.45 : 1)
            .animation(agent.isActing ? .easeInOut(duration: 0.6).repeatForever() : .default, value: pulse)
            .onChange(of: agent.isActing, initial: true) { _, acting in pulse = acting }
    }
}

/// Counts the times the main run loop wakes up: once a frame while anything animates.
@MainActor
private final class MainThreadWakeups {
    private final class Count: @unchecked Sendable { var value = 0 }
    private let total = Count()
    private let observer: CFRunLoopObserver

    init() {
        let total = total
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, _ in total.value += 1 }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func count(over duration: Duration) async throws -> Int {
        let start = total.value
        try await Task.sleep(for: duration)
        return total.value - start
    }

    func stop() {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
