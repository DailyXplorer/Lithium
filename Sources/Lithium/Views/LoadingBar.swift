import SwiftUI

/// What the loading bar shows of a tab's load. Progress only moves forward within a load; at
/// the end it runs to 100 %, and the bar stays until its exit animation is over.
struct LoadingProgress: Equatable {
    enum Phase { case idle, loading, finishing }

    private(set) var phase = Phase.idle
    private(set) var value = 0.0
    /// Counts loads, so the exit of one never ends the next.
    private(set) var generation = 0

    static let minimumVisible = 0.05

    var isVisible: Bool { phase != .idle }

    mutating func update(isLoading: Bool, progress: Double) {
        if isLoading {
            if phase != .loading {
                phase = .loading
                generation += 1
                value = max(progress, Self.minimumVisible)
            } else if progress > value {
                value = progress
            }
        } else if phase == .loading {
            phase = .finishing
            value = 1
        }
    }

    /// The exit animation of load `generation` is over; a load that started meanwhile keeps
    /// the bar, even if it is already finishing too.
    mutating func finish(generation: Int) {
        guard phase == .finishing, generation == self.generation else { return }
        phase = .idle
        value = 0
    }
}

/// Page-load progress along the bottom edge of the address bar, after Helium's design
/// (imputnet/helium#2463): a thin line with a pulsing glowing head, driven by the web view's
/// `estimatedProgress`. At the end it sweeps away left to right, or with Reduce Motion, fades.
struct LoadingBar: View {
    let tab: Tab

    var body: some View {
        LoadingLine(isLoading: tab.isLoading && tab.url?.scheme?.hasPrefix("http") == true, progress: tab.progress)
    }
}

/// The loading bar from plain values, so a test can play a page's loads to it.
struct LoadingLine: View {
    let isLoading: Bool
    let progress: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var load = LoadingProgress()
    @State private var fade = 1.0
    @State private var pulseStart = Date()

    private static let step = Animation.easeOut(duration: 0.18)
    private static let fadeOut = Animation.easeOut(duration: 0.32)
    private static let headWidth: CGFloat = 280
    private static let exitFeather: CGFloat = 40

    /// Only a load pulses. The pulse is a timeline paused the rest of the time, not a
    /// `repeatForever` animation: that one ran on at the display's rate, invisible, whenever no
    /// later animated change of the pulse reached it.
    private var isPulsing: Bool { load.phase == .loading && !reduceMotion }

    var body: some View {
        TimelineView(.animation(paused: !isPulsing)) { context in
            line(pulse: isPulsing ? Self.pulse(after: context.date.timeIntervalSince(pulseStart)) : 0.5)
        }
        .opacity(load.isVisible ? (reduceMotion ? fade : 1) : 0)
        .allowsHitTesting(false)
        .onAppear { sync() }
        .onChange(of: isLoading) { sync() }
        .onChange(of: progress) { sync() }
    }

    /// From 0 to 1 and back every 1.4 s, eased in and out, as the autoreversing
    /// `easeInOut(duration: 0.7)` was.
    static func pulse(after elapsed: TimeInterval) -> Double {
        (1 - cos(.pi * max(0, elapsed) / 0.7)) / 2
    }

    private func line(pulse: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let head = width * load.value
            let exit = reduceMotion ? 0 : 1 - fade
            let glowHead = head + exit * Self.headWidth
            let glowStart = max(0, glowHead - Self.headWidth)
            let glowOpacity = fade * (0.5 + 0.38 * pulse)

            ZStack(alignment: .bottomLeading) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.45 + 0.19 * fade))
                    .frame(width: head, height: 1.5)
                    .mask(alignment: .leading) {
                        // The line dissolves from the left as the bar exits.
                        let fadeStart = -Self.exitFeather + exit * (head + Self.exitFeather)
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0), .init(color: .black, location: 1)],
                            startPoint: .init(x: fadeStart / max(head, 1), y: 0),
                            endPoint: .init(x: (fadeStart + Self.exitFeather) / max(head, 1), y: 0)
                        )
                    }

                glow(width: min(width, glowHead) - glowStart, opacity: glowOpacity)
                    .frame(height: 4)
                    .blur(radius: 3)
                    .offset(x: glowStart)

                glow(width: min(width, glowHead) - glowStart, opacity: glowOpacity)
                    .frame(height: 1.5)
                    .offset(x: glowStart)

                Circle()
                    .fill(Color.white.opacity(0.85 * glowOpacity))
                    .frame(width: 4, height: 4)
                    .blur(radius: 0.8)
                    .offset(x: min(width, glowHead) - 2, y: 1.25)
            }
            .frame(width: width, height: proxy.size.height, alignment: .bottomLeading)
        }
    }

    private func glow(width: CGFloat, opacity: Double) -> some View {
        LinearGradient(
            stops: [
                .init(color: Color.accentColor.opacity(0), location: 0),
                .init(color: Color.accentColor.opacity(opacity * 0.18), location: 0.45),
                .init(color: Color.accentColor.opacity(opacity * 0.68), location: 0.82),
                .init(color: Color.accentColor.opacity(opacity), location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(width: max(0, width))
        .clipShape(Capsule())
    }

    private func sync() {
        var next = load
        next.update(isLoading: isLoading, progress: progress)
        guard next != load else { return }
        let starting = load.phase != .loading && next.phase == .loading
        if starting {
            load = LoadingProgress()
            fade = 1
            pulseStart = Date()
        }
        if next.phase == .finishing {
            // The exit chains off the run to 100 %, so no timer outlives the load.
            withAnimation(Self.step) { load = next } completion: {
                if load.phase == .finishing, load.generation == next.generation { exit(next.generation) }
            }
        } else {
            withAnimation(Self.step) { load = next }
        }
    }

    private func exit(_ generation: Int) {
        withAnimation(Self.fadeOut) { fade = 0 } completion: {
            load.finish(generation: generation)
        }
    }
}
