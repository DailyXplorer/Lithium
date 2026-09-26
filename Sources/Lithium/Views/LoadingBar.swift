import SwiftUI

/// Page-load progress along the bottom edge of the address bar, after Helium's design
/// (imputnet/helium#2463): a thin line with a pulsing glowing head. Progress only moves
/// forward within a load; at the end it runs to 100 %, then sweeps away left to right.
struct LoadingBar: View {
    let tab: Tab

    private enum Phase { case idle, loading, finishing }

    @State private var phase = Phase.idle
    @State private var displayed = 0.0
    @State private var fade = 1.0
    @State private var pulse = 0.5
    @State private var finishTask: Task<Void, Never>?

    private static let minimumVisible = 0.05
    private static let step = Animation.easeOut(duration: 0.18)
    private static let fadeOut = Animation.easeOut(duration: 0.32)
    private static let headWidth: CGFloat = 280
    private static let exitFeather: CGFloat = 40

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let head = width * displayed
            let exit = 1 - fade
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
        .opacity(phase == .idle ? 0 : 1)
        .allowsHitTesting(false)
        .onAppear { sync() }
        .onChange(of: tab.isLoading) { sync() }
        .onChange(of: tab.progress) {
            guard phase == .loading, tab.progress > displayed else { return }
            withAnimation(Self.step) { displayed = tab.progress }
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
        if tab.isLoading, tab.url?.scheme?.hasPrefix("http") == true {
            guard phase != .loading else { return }
            finishTask?.cancel()
            phase = .loading
            displayed = 0
            fade = 1
            pulse = 0
            withAnimation(Self.step) { displayed = max(tab.progress, Self.minimumVisible) }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = 1 }
        } else if phase == .loading {
            phase = .finishing
            withAnimation(Self.step) { displayed = 1 }
            finishTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { pulse = 0.5 }
                withAnimation(Self.fadeOut) { fade = 0 }
                try? await Task.sleep(for: .milliseconds(340))
                guard !Task.isCancelled, phase == .finishing else { return }
                phase = .idle
            }
        }
    }
}
