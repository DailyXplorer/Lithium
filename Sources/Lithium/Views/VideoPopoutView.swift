import AppKit
import SwiftUI
import WebKit

/// The corner of the page the mini player sits in. Dropped anywhere, it glides to the nearest one.
enum PopoutCorner: String {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var isTrailing: Bool { self == .topTrailing || self == .bottomTrailing }
    var isBottom: Bool { self == .bottomLeading || self == .bottomTrailing }

    static func nearest(to point: CGPoint, in size: CGSize) -> PopoutCorner {
        switch (point.x > size.width / 2, point.y > size.height / 2) {
        case (false, false): .topLeading
        case (true, false): .topTrailing
        case (false, true): .bottomLeading
        case (true, true): .bottomTrailing
        }
    }
}

/// Where the player goes and how big it can be in a page of a given size.
struct PopoutLayout {
    static let inset: CGFloat = 12
    static let minimumWidth: CGFloat = 220
    static let defaultWidth: CGFloat = 400

    let container: CGSize
    let aspectRatio: CGFloat

    /// At most three quarters of the page either way, keeping the video's shape.
    func size(width: CGFloat) -> CGSize {
        let largest = max(Self.minimumWidth, min(container.width * 0.75, container.height * 0.75 * aspectRatio))
        let width = min(max(width, Self.minimumWidth), largest)
        return CGSize(width: width, height: width / aspectRatio)
    }

    func origin(of size: CGSize, in corner: PopoutCorner) -> CGPoint {
        CGPoint(
            x: corner.isTrailing ? container.width - Self.inset - size.width : Self.inset,
            y: corner.isBottom ? container.height - Self.inset - size.height : Self.inset
        )
    }
}

/// Floats over the page while a video is popped out.
struct VideoPopoutLayer: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let popout = browser.videoPopout
        GeometryReader { proxy in
            if let tab = popout.tab, let playback = popout.playback {
                VideoPopoutPlayer(popout: popout, tab: tab, playback: playback, container: proxy.size)
            }
        }
    }
}

private struct VideoPopoutPlayer: View {
    let popout: VideoPopout
    let tab: Tab
    let playback: VideoPopout.Playback
    let container: CGSize

    @AppStorage(Preference.videoPopoutCorner) private var corner = PopoutCorner.bottomTrailing
    @AppStorage(Preference.videoPopoutWidth) private var storedWidth = Double(PopoutLayout.defaultWidth)
    @State private var dragOffset: CGSize = .zero
    @State private var resizeStart: CGFloat?
    @State private var isHovered = false

    var body: some View {
        let layout = PopoutLayout(container: container, aspectRatio: playback.aspectRatio)
        let size = layout.size(width: storedWidth)
        let origin = layout.origin(of: size, in: corner)

        ZStack {
            Color.black
            PopoutWebView(webView: tab.webView, popout: popout)
                .id(ObjectIdentifier(tab))
                .allowsHitTesting(false)
            PopoutControls(popout: popout, tab: tab, playback: playback, isCompact: size.width < 300)
                .opacity(isHovered || playback.isPaused ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { popout.returnToTab() }
        .gesture(move(size: size, origin: origin, layout: layout))
        .overlay { resizeHandles(layout: layout, size: size) }
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
        .offset(x: origin.x + dragOffset.width, y: origin.y + dragOffset.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func move(size: CGSize, origin: CGPoint, layout: PopoutLayout) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { dragOffset = $0.translation }
            .onEnded { value in
                // A flick carries on the way it was thrown.
                let center = CGPoint(
                    x: origin.x + size.width / 2 + value.predictedEndTranslation.width,
                    y: origin.y + size.height / 2 + value.predictedEndTranslation.height
                )
                let target = PopoutCorner.nearest(to: center, in: container)
                let landing = layout.origin(of: size, in: target)
                // The offset is relative to the new corner, so the player doesn't jump before it glides.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    corner = target
                    dragOffset = CGSize(width: origin.x + value.translation.width - landing.x,
                                        height: origin.y + value.translation.height - landing.y)
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragOffset = .zero }
            }
    }

    /// The two edges facing the page, and the corner between them, resize; the corner the
    /// player is tucked into stays put.
    private func resizeHandles(layout: PopoutLayout, size: CGSize) -> some View {
        let horizontal: HorizontalEdge = corner.isTrailing ? .leading : .trailing
        let vertical: VerticalEdge = corner.isBottom ? .top : .bottom
        let thickness: CGFloat = 8
        return ZStack(alignment: Alignment(horizontal: horizontal == .leading ? .leading : .trailing,
                                           vertical: vertical == .top ? .top : .bottom)) {
            Color.clear
            Color.clear
                .frame(width: thickness)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .pointerStyle(.frameResize(position: horizontal == .leading ? .leading : .trailing))
                .gesture(resize(layout: layout, size: size, axis: .horizontal))
            Color.clear
                .frame(height: thickness)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .pointerStyle(.frameResize(position: vertical == .top ? .top : .bottom))
                .gesture(resize(layout: layout, size: size, axis: .vertical))
            Color.clear
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .pointerStyle(.frameResize(position: innerCorner))
                .gesture(resize(layout: layout, size: size, axis: nil))
        }
    }

    private var innerCorner: FrameResizePosition {
        switch corner {
        case .topLeading: .bottomTrailing
        case .topTrailing: .bottomLeading
        case .bottomLeading: .topTrailing
        case .bottomTrailing: .topLeading
        }
    }

    /// Pulling away from the tucked corner grows the player; along both axes, the larger pull wins.
    private func resize(layout: PopoutLayout, size: CGSize, axis: Axis?) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = resizeStart ?? size.width
                resizeStart = start
                let alongWidth = value.translation.width * (corner.isTrailing ? -1 : 1)
                let alongHeight = value.translation.height * (corner.isBottom ? -1 : 1) * layout.aspectRatio
                let growth = switch axis {
                case .horizontal: alongWidth
                case .vertical: alongHeight
                case nil: abs(alongWidth) > abs(alongHeight) ? alongWidth : alongHeight
                }
                storedWidth = layout.size(width: start + growth).width
            }
            .onEnded { _ in resizeStart = nil }
    }
}

private struct PopoutControls: View {
    let popout: VideoPopout
    let tab: Tab
    let playback: VideoPopout.Playback
    let isCompact: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack {
                    PopoutButton(icon: .returnToTab, size: 15, help: "Back to \(tab.displayTitle)") { popout.returnToTab() }
                    Spacer()
                    PopoutButton(icon: .close, size: 15, help: "Close") {
                        withAnimation(.easeOut(duration: 0.15)) { popout.close() }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: isCompact ? 14 : 22) {
                    if playback.duration != nil {
                        SkipButton(seconds: -10, popout: popout)
                    }
                    PopoutButton(icon: playback.isPaused ? .play : .pause, size: 26, help: playback.isPaused ? "Play" : "Pause") {
                        popout.togglePlay()
                    }
                    if playback.duration != nil {
                        SkipButton(seconds: 10, popout: popout)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if let duration = playback.duration {
                        Scrubber(popout: popout, time: playback.time, duration: duration)
                    } else {
                        Text("LIVE")
                            .font(Theme.font(10, .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.red))
                        Spacer()
                    }
                    PopoutButton(icon: playback.isMuted ? .speakerOff : .speaker, size: 15, help: playback.isMuted ? "Unmute" : "Mute") {
                        popout.toggleMute()
                    }
                }
            }
            .padding(6)
        }
        .foregroundStyle(.white)
    }
}

private struct PopoutButton: View {
    let icon: Phosphor
    let size: CGFloat
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Icon(icon, size: size)
                .frame(width: size + 14, height: size + 14)
                .background(Circle().fill(.white.opacity(isHovered ? 0.18 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// Phosphor's circular arrows, with the seconds they skip written inside.
private struct SkipButton: View {
    let seconds: Double
    let popout: VideoPopout
    @State private var isHovered = false

    var body: some View {
        Button { popout.skip(by: seconds) } label: {
            ZStack {
                Icon(seconds < 0 ? .retry : .reload, size: 24)
                Text("\(Int(abs(seconds)))")
                    .font(Theme.font(8, .bold))
                    .offset(y: 0.5)
            }
            .frame(width: 34, height: 34)
            .background(Circle().fill(.white.opacity(isHovered ? 0.18 : 0)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(seconds < 0 ? "Back \(Int(-seconds)) Seconds" : "Forward \(Int(seconds)) Seconds")
    }
}

/// The time bar. Dragging shows where the video will go, and seeks there on release.
private struct Scrubber: View {
    let popout: VideoPopout
    let time: Double
    let duration: Double
    @State private var scrubbing: Double?
    @State private var isHovered = false

    var body: some View {
        let shown = scrubbing ?? time
        HStack(spacing: 8) {
            Text(Self.format(shown))
                .monospacedDigit()
            GeometryReader { proxy in
                let fraction = duration > 0 ? min(max(shown / duration, 0), 1) : 0
                let height: CGFloat = isHovered || scrubbing != nil ? 5 : 3
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white).frame(width: proxy.size.width * fraction)
                }
                .frame(height: height)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            scrubbing = min(max(value.location.x / proxy.size.width, 0), 1) * duration
                        }
                        .onEnded { _ in
                            if let scrubbing { popout.seek(to: scrubbing) }
                            scrubbing = nil
                        }
                )
                .animation(.easeOut(duration: 0.12), value: height)
            }
            .frame(height: 16)
            .onHover { isHovered = $0 }
            Text(Self.format(duration))
                .monospacedDigit()
                .opacity(0.8)
        }
        .font(Theme.font(11, .medium))
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? max(seconds, 0) : 0)
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

/// Holds the popped out tab's web view. SwiftUI may make a container it never shows, or keep
/// one fading out after the page took its web view back: only a container in the window, for
/// the video the player shows now, takes it. Keyboard focus doesn't follow the page here.
private struct PopoutWebView: NSViewRepresentable {
    let webView: WKWebView
    let popout: VideoPopout

    func makeNSView(context: Context) -> PopoutContainerView {
        PopoutContainerView(webView: webView, popout: popout)
    }

    func updateNSView(_ container: PopoutContainerView, context: Context) {
        container.adopt()
    }
}

final class PopoutContainerView: NSView {
    private let webView: WKWebView
    private weak var popout: VideoPopout?

    init(webView: WKWebView, popout: VideoPopout) {
        self.webView = webView
        self.popout = popout
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        adopt()
    }

    /// Keys the page leaves unhandled stop here, as in the page's own container.
    override func keyDown(with event: NSEvent) {}

    func adopt() {
        guard let window, webView.superview !== self, popout?.tab?.webView === webView else { return }
        if (window.firstResponder as? NSView)?.isDescendant(of: webView) == true {
            window.makeFirstResponder(nil)
        }
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }
}

/// Where the page was, while its video plays in the player.
struct PoppedOutPlaceholder: View {
    let popout: VideoPopout

    var body: some View {
        VStack(spacing: 12) {
            Icon(.popout, size: 36)
                .opacity(0.35)
            Text("This video is playing in the mini player.")
                .font(Theme.font(14, .medium))
                .opacity(0.6)
            Button("Bring It Back") { popout.hide() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
