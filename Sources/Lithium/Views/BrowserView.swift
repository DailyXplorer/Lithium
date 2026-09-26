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
        let tab = browser.selectedTab ?? browser.home
        // Strips sit above the page and push it down, so they never hide its top.
        VStack(spacing: 0) {
            if let request = browser.permissions.pending.first(where: { $0.tabID == tab.id }) {
                PermissionPrompt(request: request)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if browser.find.isVisible {
                FindBar(webView: tab.webView)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            WebContainer(webView: tab.webView)
        }
        .animation(.snappy(duration: 0.2), value: browser.permissions.pending)
        .animation(.snappy(duration: 0.2), value: browser.find.isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 1.5, y: 0.5)
    }
}

/// Hosts the selected tab's WKWebView. Swapping the subview (instead of rebuilding) keeps
/// every tab's page alive, and detached web views get throttled by WebKit.
struct WebContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

private struct SidebarBackground: View {
    let style: SidebarStyle
    let color: Color

    var body: some View {
        switch style {
        case .solid: color
        case .translucent: VisualEffectBackground()
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
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
