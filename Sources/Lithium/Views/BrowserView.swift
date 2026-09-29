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
        .foregroundStyle(palette.ink)
        .environment(\.sidebarPalette, palette)
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

/// With the sidebar hidden, the pointer on the window's left edge slides it out over the page.
/// It slides back once the pointer leaves it or a tab is picked.
private struct SidebarPeek: View {
    let style: SidebarStyle
    let colorHex: String
    @Environment(Browser.self) private var browser
    @State private var isEdgeHovered = false
    @State private var isPanelHovered = false
    @State private var isShown = false
    @State private var pendingHide: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: Layout.margin)
                .contentShape(Rectangle())
                .onHover { isEdgeHovered = $0 }
            if isShown {
                SidebarView()
                    .padding(.top, 8)
                    .frame(width: Layout.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background { SidebarBackground(style: style, color: Color(hex: colorHex), blending: .withinWindow) }
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 12, x: 2)
                    .padding([.leading, .bottom], Layout.margin)
                    .onHover { isPanelHovered = $0 }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        // Each event, not a combined flag: a rename left pending would otherwise hold the flag
        // true, and pointing at the edge would no longer open the panel.
        .onChange(of: isEdgeHovered) { update() }
        .onChange(of: isPanelHovered) { update() }
        .onChange(of: browser.renamingTabID) { update() }
        .onChange(of: browser.selectedTabID) {
            if browser.renamingTabID == nil { setShown(false) }
        }
        .onDisappear { pendingHide?.cancel() }
    }

    /// A double click that renames a background tab selects it first, which hides the panel;
    /// the rename brings it back and keeps it until the name is in.
    private func update() {
        pendingHide?.cancel()
        if isEdgeHovered || isPanelHovered || browser.renamingTabID != nil {
            setShown(true)
        } else {
            // Moving from the edge onto the panel may report the exit before the entry.
            pendingHide = Task {
                try? await Task.sleep(for: .milliseconds(200))
                if !Task.isCancelled { setShown(false) }
            }
        }
    }

    private func setShown(_ shown: Bool) {
        // A view removed from under the pointer never reports the exit.
        if !shown { isPanelHovered = false }
        withAnimation(.snappy(duration: 0.2)) { isShown = shown }
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
