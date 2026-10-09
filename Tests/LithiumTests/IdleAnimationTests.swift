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

    @Test func loadingPulseRisesAndFalls() {
        #expect(LoadingLine.pulse(after: 0) == 0)
        #expect(abs(LoadingLine.pulse(after: 0.35) - 0.5) < 1e-9)
        #expect(abs(LoadingLine.pulse(after: 0.7) - 1) < 1e-9)
        #expect(abs(LoadingLine.pulse(after: 1.4)) < 1e-9)
        #expect(LoadingLine.pulse(after: -1) == 0)
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

    /// The control for the tests above and below: the agent button's pulse as it was before the
    /// fix runs on after the call, and the wakeup count sees it off screen. Without it, a line
    /// that "stops" could only mean the count sees nothing in a window that is never shown.
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
        #expect(after >= 30, "the pre-fix pulse still draws after the call (\(after) wakeups in 0.6 s)")
    }

    /// amazon.fr loads twice, the second load about 190 ms after the first ends: while the line
    /// still runs to 100 % or sweeps away. Whenever the second load comes, and however the first
    /// ended, nothing animates once both are done.
    @Test(arguments: [
        BackToBack(gap: nil),
        BackToBack(gap: .zero),
        BackToBack(gap: .milliseconds(50)),
        BackToBack(gap: .milliseconds(150)),
        BackToBack(gap: .milliseconds(180)),
        BackToBack(gap: .milliseconds(190)),
        BackToBack(gap: .milliseconds(200)),
        BackToBack(gap: .milliseconds(300)),
        BackToBack(gap: .milliseconds(600)),
        BackToBack(gap: .milliseconds(190), firstEndsAt: 0.7),
        BackToBack(gap: .milliseconds(190), appearsLoading: true),
    ])
    func loadingLineStopsAfterBackToBackLoads(_ loads: BackToBack) async throws {
        let page = FakeLoad()
        page.shows = !loads.appearsLoading
        let (window, wakeups) = host(LineHost(page: page))
        defer {
            wakeups.stop()
            window.orderOut(nil)
            window.contentView = nil
        }
        try await Task.sleep(for: .milliseconds(200))

        page.progress = 0.1
        page.isLoading = true
        if loads.appearsLoading {
            try await Task.sleep(for: .milliseconds(100))
            page.shows = true
        }
        let loading = try await wakeups.count(over: .milliseconds(300))
        page.progress = loads.firstEndsAt
        page.isLoading = false
        if let gap = loads.gap {
            if gap > .zero { try await Task.sleep(for: gap) }
            page.progress = 0.1
            page.isLoading = true
            try await Task.sleep(for: .milliseconds(150))
            page.progress = 1
            page.isLoading = false
        }
        try await Task.sleep(for: .seconds(1))
        let after = try await wakeups.count(over: .milliseconds(600))
        #expect(loading >= 9, "the line draws while the page loads (\(loading) wakeups in 0.3 s)")
        #expect(after * 2 < loading, "\(after) wakeups in 0.6 s once idle, \(loading) in 0.3 s of load")
    }

    /// The same loads, with what goes on around the line in the address bar: the window opening on
    /// a load, the edit ending after Return, the reader buttons coming and going, a resize, tab
    /// switches. Nothing animates once the loads are done.
    @Test(arguments: AddressBarEvent.allCases)
    func loadingLineStopsInTheAddressBar(_ event: AddressBarEvent) async throws {
        let bar = FakeAddressBar()
        func load(_ progress: Double, _ isLoading: Bool, tab: Int = 0) {
            bar.progress[tab] = progress
            bar.isLoading[tab] = isLoading
        }
        if event == .opensLoading { load(0.1, true) }
        if event == .editEnds { bar.isEditing = true }
        let (window, wakeups) = host(AddressBarHost(bar: bar), width: 600)
        defer {
            wakeups.stop()
            window.orderOut(nil)
            window.contentView = nil
        }
        try await Task.sleep(for: .milliseconds(200))

        if event != .opensLoading { load(0.1, true) }
        if event == .editEnds {
            try await Task.sleep(for: .milliseconds(100))
            bar.isEditing = false
        }
        let loading = try await wakeups.count(over: .milliseconds(300))
        switch event {
        case .resizesMidLoad: bar.width = 480
        case .switchesTab: withAnimation(.snappy(duration: 0.25)) { bar.tab = 1 }
        case .switchesToALoadingTab:
            load(0.3, true, tab: 1)
            withAnimation(.snappy(duration: 0.25)) { bar.tab = 1 }
        default: break
        }
        if event == .progressEndsFirst {
            bar.progress[bar.tab] = 1
            try await Task.sleep(for: .milliseconds(30))
        }
        load(1, false, tab: bar.tab)
        if event == .readerButtonsComeAndGo { bar.hasReader = true }
        // amazon.fr's second load, about 190 ms after the first.
        try await Task.sleep(for: .milliseconds(190))
        load(0.1, true, tab: bar.tab)
        if event == .readerButtonsComeAndGo { bar.hasReader = false }
        try await Task.sleep(for: .milliseconds(150))
        load(1, false, tab: bar.tab)
        if event == .readerButtonsComeAndGo { bar.hasReader = true }
        try await Task.sleep(for: .seconds(1))
        let after = try await wakeups.count(over: .milliseconds(600))
        #expect(loading >= 9, "the line draws while the page loads (\(loading) wakeups in 0.3 s)")
        #expect(after * 2 < loading, "\(after) wakeups in 0.6 s once idle, \(loading) in 0.3 s of load")
    }

    private func host(_ view: some View, width: CGFloat = 300) -> (NSWindow, MainThreadWakeups) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        // Off screen and never shown, but in a window, where SwiftUI animates.
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: 28), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        return (window, MainThreadWakeups())
    }
}

/// A second load `gap` after the first ends (nil: none; zero: in the same turn), the first
/// ending at `firstEndsAt` progress (below 1 when the second one cuts it short). With
/// `appearsLoading`, the line comes in mid-load, as when the address bar's edit ends after Return.
struct BackToBack: Sendable, CustomTestStringConvertible {
    let gap: Duration?
    var firstEndsAt = 1.0
    var appearsLoading = false

    var testDescription: String {
        "\(gap.map { "second load after \($0)" } ?? "one load"), first ends at \(firstEndsAt)\(appearsLoading ? ", shown mid-load" : "")"
    }
}

/// What happens around the loading line in the address bar during amazon.fr's two loads.
enum AddressBarEvent: String, CaseIterable, Sendable {
    /// The window opens on a tab that is loading, so the line starts in the window's first layout.
    case opensLoading
    /// Return: the load starts while the field edits, and the line comes back mid-load as the lock
    /// replaces the search icon.
    case editEnds
    /// `estimatedProgress` reaches 1 a moment before `isLoading` turns false.
    case progressEndsFirst
    /// The reader buttons come in as a load ends and go as the next starts.
    case readerButtonsComeAndGo
    case resizesMidLoad
    /// To an idle tab mid-load, in an animation (spaces switch so).
    case switchesTab
    case switchesToALoadingTab
}

@MainActor @Observable
private final class FakeAddressBar {
    var tab = 0
    var isLoading = [false, false]
    var progress = [0.0, 0.0]
    var isEditing = false
    var hasReader = false
    var width: CGFloat = 560
}

/// The address bar's layout around the line (`AddressBar`).
private struct AddressBarHost: View {
    let bar: FakeAddressBar

    var body: some View {
        HStack(spacing: 4) {
            if bar.isEditing {
                Circle().frame(width: 22, height: 22)
            } else {
                Rectangle().frame(width: 22, height: 22)
            }
            Color.clear.frame(maxWidth: .infinity)
            if !bar.isEditing, bar.hasReader {
                Rectangle().frame(width: 22, height: 22)
            }
        }
        .frame(width: bar.width, height: 28)
        .overlay {
            if !bar.isEditing {
                LoadingLine(isLoading: bar.isLoading[bar.tab], progress: bar.progress[bar.tab])
                    .id(bar.tab)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

@MainActor @Observable
private final class Acting {
    var isActing = false
}

@MainActor @Observable
private final class FakeLoad {
    var isLoading = false
    var progress = 0.0
    var shows = true
}

private struct LineHost: View {
    let page: FakeLoad

    var body: some View {
        if page.shows {
            LoadingLine(isLoading: page.isLoading, progress: page.progress).frame(width: 300, height: 28)
        }
    }
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
