import SwiftUI
import WebKit

enum Layout {
    static let topBarHeight: CGFloat = 40
    static let margin: CGFloat = 8
    static let trafficLightsWidth: CGFloat = 78
    static let sidebarWidth: CGFloat = 240
}

struct BrowserView: View {
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Preference.sidebarStyle) private var style = SidebarStyle.solid
    @AppStorage(Preference.sidebarColor) private var colorHex = Theme.defaultSidebarHex
    @State private var tabHover = TabHover()

    var body: some View {
        let palette = SidebarPalette(style: style, colorHex: colorHex, scheme: colorScheme)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if browser.isSidebarVisible {
                    SidebarHeader().frame(width: Layout.sidebarWidth)
                } else {
                    Color.clear.frame(width: Layout.trafficLightsWidth)
                }
                ToolbarView()
            }
            .frame(height: Layout.topBarHeight)
            .background(WindowDragArea())

            HStack(spacing: 0) {
                if browser.isSidebarVisible {
                    SidebarView()
                        .frame(width: Layout.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ContentCard()
                    .padding(.leading, browser.isSidebarVisible ? 0 : Layout.margin)
                    .padding([.trailing, .bottom], Layout.margin)
            }
            .overlay(alignment: .leading) {
                if !browser.isSidebarVisible {
                    SidebarPeek(style: style, colorHex: colorHex)
                }
            }
        }
        .overlayPreferenceValue(AddressBarBounds.self) { anchor in
            GeometryReader { proxy in
                if let anchor, !browser.suggestions.items.isEmpty {
                    let bar = proxy[anchor]
                    SuggestionList()
                        .frame(width: max(bar.width, 420))
                        .offset(x: bar.minX, y: bar.maxY + 6)
                }
            }
        }
        .overlayPreferenceValue(TabHoverAnchors.self) { TabHoverLayer(anchors: $0) }
        .foregroundStyle(palette.ink)
        .environment(\.sidebarPalette, palette)
        .environment(tabHover)
        .font(Theme.font(13))
        .background { SidebarBackground(style: style, color: Color(hex: colorHex)) }
        .background(WindowConfigurator())
        .ignoresSafeArea()
        .overlay {
            if browser.capture.isSelecting {
                CaptureSelectionOverlay().ignoresSafeArea()
            }
        }
        .sheet(item: Binding(get: { browser.capture.shot }, set: { if $0 == nil { browser.capture.finish() } })) { shot in
            CapturePreview(shot: shot).environment(browser)
        }
        .onOpenURL { browser.newTab(url: $0) }
        .onAppear { browser.windowDidAppear() }
    }
}

struct ContentCard: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let tab = browser.selectedTab
        // Strips sit above the page and push it down, so they never hide its top.
        VStack(spacing: 0) {
            if let request = browser.permissions.pending.first(where: { $0.tabID == tab?.id }) {
                PermissionPrompt(request: request)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Group {
                if let tab, browser.videoPopout.tab === tab {
                    PoppedOutPlaceholder(popout: browser.videoPopout)
                } else if let tab {
                    PageContainer(view: tab.webView)
                        .overlay {
                            if let pdf = tab.pdf {
                                PDFReaderView(reader: pdf).id(ObjectIdentifier(pdf))
                            }
                        }
                } else {
                    StartPageView()
                }
            }
            // Only the player animates: a page fading out would hold on to its web view, which
            // the player (or the page, on the way back) has just taken.
            .overlay {
                VideoPopoutLayer()
                    .animation(.snappy(duration: 0.25), value: browser.videoPopout.tab?.id)
            }
            // Floats in the top right corner, like Chrome's, below the PDF viewer's controls
            // and above the player.
            .overlay(alignment: .topTrailing) {
                if let tab, browser.find.isVisible {
                    FindBar(tab: tab)
                        .padding(.top, tab.pdf == nil ? 10 : 50)
                        .padding(.horizontal, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        // The outgoing page leaves with the keyboard, which falls back on the window: keys beep and
        // the first click only focuses the page. The next run-loop turn has the new page in place.
        .onChange(of: tab?.id) {
            DispatchQueue.main.async {
                guard let tab = browser.selectedTab, browser.videoPopout.tab !== tab else { return }
                focusPage(tab.contentView)
            }
        }
        .animation(.snappy(duration: 0.2), value: browser.permissions.pending)
        .animation(.snappy(duration: 0.2), value: browser.find.isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(card)
        // Cast by a shape behind the page, not by the page. On the web view's own layers the
        // shadow has no path, and a playing video flashed black whenever the pointer moved.
        .background { card.fill(Color(nsColor: .textBackgroundColor)).shadow(color: .black.opacity(0.14), radius: 1.5, y: 0.5) }
    }

    private var card: RoundedRectangle { RoundedRectangle(cornerRadius: 9, style: .continuous) }
}

/// Hosts a view the tab owns: its WKWebView or its PDF viewer. Swapping the subview (instead of
/// rebuilding) keeps every tab's page alive, and detached web views get throttled by WebKit.
struct PageContainer: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        WebContainerView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}

/// Keys a page reacts to without calling preventDefault (YouTube's ← and → seek) come back
/// from WebKit as unhandled; past this view they would reach the window, which beeps.
/// Lithium's shortcuts are menu key equivalents, so nothing above needs them.
final class WebContainerView: NSView {
    override func keyDown(with event: NSEvent) {}
}

/// With the sidebar hidden, the pointer resting on the window's left edge slides it out over the
/// page. It slides back once the pointer has stayed off it and its margin for a while, or a tab
/// is picked. The reveal setting picks the delays and the margin.
private struct SidebarPeek: View {
    let style: SidebarStyle
    let colorHex: String
    @Environment(Browser.self) private var browser
    @AppStorage(Preference.sidebarReveal) private var reveal = SidebarReveal.normal
    @State private var zone = PeekZone.outside
    @State private var isShown = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .leading) {
            // Spans the panel plus its margin, above it too, so its own frame is the keep-open zone.
            PeekTracker(topMargin: reveal.margin) { zone = $0 }
                .frame(width: Layout.margin + Layout.sidebarWidth + reveal.margin)
                .padding(.top, -reveal.margin)
                .allowsHitTesting(false)
            if isShown {
                SidebarView()
                    .padding(.top, 8)
                    .frame(width: Layout.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background { SidebarBackground(style: style, color: Color(hex: colorHex), blending: .withinWindow) }
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 12, x: 2)
                    .padding([.leading, .bottom], Layout.margin)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .onChange(of: zone) { update() }
        .onChange(of: browser.renamingTabID) { update() }
        .onChange(of: browser.tabPickToken) {
            guard browser.renamingTabID == nil else { return }
            pending?.cancel()
            setShown(false)
        }
        .onDisappear { pending?.cancel() }
    }

    /// Opening waits for the pointer to rest on the edge, closing for it to stay away, and any
    /// move in between calls the change off. A double click that renames a background tab selects
    /// it first, which hides the panel; the rename brings it back at once and keeps it until the
    /// name is in.
    private func update() {
        pending?.cancel()
        let renaming = browser.renamingTabID != nil
        let wanted = renaming || (isShown ? zone != .outside : zone == .edge)
        guard wanted != isShown else { return }
        if renaming {
            setShown(true)
            return
        }
        let delay = wanted ? reveal.openDelay : reveal.closeDelay
        pending = Task {
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { setShown(wanted) }
        }
    }

    private func setShown(_ shown: Bool) {
        withAnimation(.snappy(duration: 0.2)) { isShown = shown }
    }
}

private enum PeekZone { case outside, near, edge }

/// Where the pointer is, for the hidden sidebar. One tracking area judged by geometry alone: hover
/// on the panel itself got exits and entries as the panel slid in under the pointer, and flickered.
/// It never takes clicks, which go on to the page below, and only exists while the sidebar is hidden.
private struct PeekTracker: NSViewRepresentable {
    let topMargin: CGFloat
    let onChange: (PeekZone) -> Void

    func makeNSView(context: Context) -> TrackerView { TrackerView() }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.topMargin = topMargin
        view.onChange = onChange
    }

    final class TrackerView: NSView {
        /// A little wider than the window margin, so the edge is easy to hit without covering
        /// more than a sliver of the page.
        private static let edgeWidth: CGFloat = 10
        var topMargin: CGFloat = 0
        var onChange: (PeekZone) -> Void = { _ in }
        private var zone = PeekZone.outside

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard trackingAreas.isEmpty else { return }
            let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect]
            addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self))
        }

        override func mouseEntered(with event: NSEvent) { locate(event) }
        override func mouseMoved(with event: NSEvent) { locate(event) }
        override func mouseExited(with event: NSEvent) { report(.outside) }

        /// The edge starts below the top margin, where the page does.
        private func locate(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            report(point.x < Self.edgeWidth && point.y >= topMargin ? .edge : .near)
        }

        /// Only changes reach SwiftUI, so a moving pointer doesn't redraw anything.
        private func report(_ new: PeekZone) {
            guard new != zone else { return }
            zone = new
            onChange(new)
        }
    }
}

private struct SidebarBackground: View {
    let style: SidebarStyle
    let color: Color
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    var body: some View {
        switch style {
        case .solid: color
        case .translucent: VisualEffectBackground(blending: blending)
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
    }
}

/// Moves the traffic lights down so they sit centered in Lithium's taller top bar.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TrafficLightsView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class TrafficLightsView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { return }
            window.isMovableByWindowBackground = false
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layoutTrafficLights() }
                }
            }
            layoutTrafficLights()
        }

        override func layout() {
            super.layout()
            layoutTrafficLights()
        }

        private func layoutTrafficLights() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview else { return }
            let height = Layout.topBarHeight
            container.frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, type) in buttons.enumerated() {
                guard let button = window.standardWindowButton(type) else { continue }
                button.setFrameOrigin(NSPoint(x: 14 + CGFloat(index) * 20, y: (height - button.frame.height) / 2))
            }
        }
    }
}
