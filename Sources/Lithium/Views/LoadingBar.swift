import SwiftUI

/// Progress only moves forward within a load; the bar stays until its exit animation is over.
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

    /// A load that started meanwhile keeps the bar, even if it is already finishing too.
    mutating func finish(generation: Int) {
        guard phase == .finishing, generation == self.generation else { return }
        phase = .idle
        value = 0
    }
}

/// Page-load progress along the address bar's bottom edge, after Helium's design (imputnet/helium#2463).
struct LoadingBar: View {
    let tab: Tab

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var load = LoadingProgress()
    @State private var fade = 1.0
    @State private var pulse = 0.5

    private static let step = Animation.easeOut(duration: 0.18)
    private static let fadeOut = Animation.easeOut(duration: 0.32)
    private static let headWidth: CGFloat = 280
    private static let exitFeather: CGFloat = 40

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let head = width * load.value
            let exit = reduceMotion ? 0 : 1 - fade
            let glowHead = head + exit * Self.headWidth
            let glowStart = max(0, glowHead - Self.headWidth)
            let glowOpacity = fade * (0.5 + 0.38 * pulse)

            // Only while a load shows, one line per load: removing the views that read `pulse` is
            // what ends its `repeatForever`; a later animation on `pulse` doesn't cancel it.
            if load.isVisible {
                ZStack(alignment: .bottomLeading) {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.45 + 0.19 * fade))
                        .frame(width: head, height: 1.5)
                        .mask(alignment: .leading) {
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
                .id(load.generation)
            }
        }
        .opacity(load.isVisible ? (reduceMotion ? fade : 1) : 0)
        .allowsHitTesting(false)
        .onAppear { sync() }
        .onChange(of: tab.isLoading) { sync() }
        .onChange(of: tab.progress) { sync() }
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
        next.update(isLoading: tab.isLoading && tab.url?.scheme?.hasPrefix("http") == true, progress: tab.progress)
        guard next != load else { return }
        let starting = load.phase != .loading && next.phase == .loading
        if starting {
            load = LoadingProgress()
            fade = 1
            pulse = reduceMotion ? 0.5 : 0
        }
        if next.phase == .finishing {
            // The exit chains off the run to 100 %, so no timer outlives the load.
            withAnimation(Self.step) { load = next } completion: {
                if load.phase == .finishing, load.generation == next.generation { exit(next.generation) }
            }
        } else {
            withAnimation(Self.step) { load = next }
        }
        if starting, !reduceMotion {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = 1 }
        }
    }

    private func exit(_ generation: Int) {
        withAnimation(.easeOut(duration: 0.2)) { pulse = 0.5 }
        withAnimation(Self.fadeOut) { fade = 0 } completion: {
            load.finish(generation: generation)
        }
    }
}
