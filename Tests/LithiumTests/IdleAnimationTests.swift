import AppKit
import Observation
import SwiftUI
import Testing
@testable import Lithium

/// Nothing in the window keeps animating once there is nothing to show: an endless animation left
/// running wakes the app's main thread at the display's rate, on an idle page too.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IdleAnimationTests {
    @Test func agentPulseDimsAndComesBack() {
        #expect(ActingPulse.opacity(after: 0) == 1)
        #expect(abs(ActingPulse.opacity(after: 0.3) - 0.725) < 1e-9)
        #expect(abs(ActingPulse.opacity(after: 0.6) - 0.45) < 1e-9)
        #expect(abs(ActingPulse.opacity(after: 1.2) - 1) < 1e-9)
        #expect(ActingPulse.opacity(after: -1) == 1)
    }

    /// The toolbar's agent button pulses while a call runs, then stops drawing: the
    /// `repeatForever` it had ran on after every call, as long as the agent stayed connected.
    @Test func agentPulseStopsWhenTheCallEnds() async throws {
        let agent = Acting()
        let hosting = NSHostingView(rootView: PulseHost(agent: agent))
        hosting.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        // Off screen and never shown, but in a window, where SwiftUI animates.
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 20, height: 20), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        let wakeups = MainThreadWakeups()
        defer { wakeups.stop() }
        try await Task.sleep(for: .milliseconds(200))

        agent.isActing = true
        let acting = try await wakeups.count(over: .seconds(1))
        agent.isActing = false
        try await Task.sleep(for: .milliseconds(300))
        let after = try await wakeups.count(over: .seconds(1))
        #expect(acting >= 30, "the pulse draws while the agent acts (\(acting) wakeups)")
        #expect(after * 4 < acting, "\(after) wakeups a second after the call, \(acting) during it")
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
