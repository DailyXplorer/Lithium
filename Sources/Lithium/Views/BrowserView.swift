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
    @AppStorage(Preference.sidebarColor) private var settingsColorHex = Theme.defaultSidebarHex
    @State private var tabHover = TabHover()
    @State private var showsZenLights = false

    private var colorHex: String { browser.currentSpace.color ?? settingsColorHex }

    var body: some View {
        let palette = SidebarPalette(style: style, colorHex: colorHex, scheme: colorScheme)
        let zen = browser.isZenMode
        VStack(spacing: 0) {
            if !zen {
                HStack(spacing: 0) {
                    if browser.showsSidebar {
                        SidebarHeader().frame(width: Layout.sidebarWidth)
                    } else {
                        Color.clear.frame(width: Layout.trafficLightsWidth)
                    }
                    ToolbarView()
                }
                .frame(height: Layout.topBarHeight)
                .background(WindowDragArea())
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            HStack(spacing: 0) {
                if browser.showsSidebar {
                    SidebarView()
                        .frame(width: Layout.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ContentCard()
                    .padding(.leading, browser.showsSidebar ? 0 : Layout.margin)
                    .padding(.top, zen ? Layout.margin : 0)
                    .padding([.trailing, .bottom], Layout.margin)
            }
            .overlay(alignment: .leading) {
                if !browser.showsSidebar {
                    SidebarPeek(style: style, colorHex: colorHex, isZen: zen)
                }
            }
        }
        // With the top bar gone, the frame around the page is what moves the window.
        .background { if zen { WindowDragArea() } }
        .overlay(alignment: .top) {
            if zen {
                ZenTopBarPeek(style: style, colorHex: colorHex, showsLights: $showsZenLights)
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
        .overlay { TabCycleLayer() }
        .foregroundStyle(palette.ink)
        .environment(\.sidebarPalette, palette)
        .environment(tabHover)
        .font(Theme.font(13))
        .background { SidebarBackground(style: style, color: Color(hex: colorHex)) }
        .background(WindowConfigurator(browser: browser, hidesLights: zen && !showsZenLights))
        .background { TranslationHost(translator: browser.translator) }
        .ignoresSafeArea()
        .overlay {
            if browser.capture.isSelecting {
                CaptureSelectionOverlay().ignoresSafeArea()
            }
        }
        .sheet(item: Binding(get: { browser.capture.shot }, set: { if $0 == nil { browser.capture.finish() } })) { shot in
            CapturePreview(shot: shot).environment(browser)
        }
        .onOpenURL { browser.openFromOtherApp($0) }
        .onAppear { browser.windowDidAppear() }
    }
}

struct ContentCard: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let tab = browser.selectedTab
        VStack(spacing: 0) {
            if let confirmations = browser.agent?.confirmations, let confirmation = confirmations.front(selected: tab?.id) {
                AgentConfirmationBanner(
                    confirmation: confirmation,
                    confirmations: confirmations,
                    otherTab: confirmation.tabID == tab?.id ? nil : browser.tabs.first { $0.id == confirmation.tabID },
                    queued: confirmations.pending.count - 1
                )
                .id(confirmation.id)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let request = browser.shownPermissionRequest {
                PermissionPrompt(request: request)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let request = browser.shownAppLinkRequest {
                AppLinkPrompt(request: request)
                    .id(request.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Group {
                if let tab, let split = browser.split(of: tab) {
                    SplitPages(split: split)
                } else if let tab, browser.videoPopout.tab === tab {
                    PoppedOutPlaceholder(popout: browser.videoPopout)
                } else if let tab {
                    PageContainer(view: tab.webView)
                        .overlay {
                            if let pdf = tab.pdf {
                                PDFReaderView(reader: pdf).id(ObjectIdentifier(pdf))
                            }
                        }
                        .overlay { BlockedPageLayer(tab: tab) }
                        .overlay {
                            if let acting = browser.agent?.tabs[tab.id]?.acting {
                                AgentActingOverlay(acting: acting)
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
            .overlay(alignment: .topTrailing) {
                // In split view, `SplitPane` shows it over the focused page.
                if let tab, browser.showsFindBar(over: tab), browser.split(of: tab) == nil {
                    FindBar(tab: tab)
                        .padding(.top, tab.pdf == nil ? 10 : 50)
                        .padding(.horizontal, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay { SplitDropLayer() }
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
        .animation(.snappy(duration: 0.2), value: browser.appLinks.pending)
        .animation(.snappy(duration: 0.2), value: browser.agent?.confirmations.pending)
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

/// Hosts the tab's WKWebView or PDF viewer. Swapping the subview (instead of rebuilding) keeps
/// every tab's page alive, and detached web views get throttled by WebKit.
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
final class WebContainerView: NSView {
    override func keyDown(with event: NSEvent) {}
}

/// With the sidebar hidden, resting the pointer on the left edge slides it out over the page;
/// it slides back once the pointer stays away, or a tab is picked.
private struct SidebarPeek: View {
    let style: SidebarStyle
    let colorHex: String
    let isZen: Bool
    @Environment(Browser.self) private var browser
    @AppStorage(Preference.sidebarReveal) private var reveal = SidebarReveal.normal
    @State private var zone = PeekZone.outside
    @State private var isShown = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        let edgeTop = reveal.margin + (isZen ? Layout.topBarHeight : 0)
        ZStack(alignment: .leading) {
            PeekTracker(locate: { PeekZone.left(of: $0, below: edgeTop) }) { zone = $0 }
                .frame(width: Layout.margin + Layout.sidebarWidth + reveal.margin)
                .padding(.top, -reveal.margin)
                .allowsHitTesting(false)
            if isShown {
                SidebarView()
                    .padding(.top, isZen ? Layout.topBarHeight - Layout.margin : 8)
                    .frame(width: Layout.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background { SidebarBackground(style: style, color: Color(hex: colorHex), blending: .withinWindow) }
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 12, x: 2)
                    .padding(.top, isZen ? Layout.margin : 0)
                    .padding([.leading, .bottom], Layout.margin)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .onChange(of: zone) { update() }
        .onChange(of: browser.isRenaming) { update() }
        .onChange(of: browser.tabPickToken) {
            guard !browser.isRenaming else { return }
            pending?.cancel()
            setShown(false)
        }
        .onDisappear { pending?.cancel() }
    }

    /// Opening waits for the pointer to rest on the edge, closing for it to stay away. A rename
    /// selects its tab first, which hides the panel, so renaming brings it back and keeps it.
    private func update() {
        pending?.cancel()
        let renaming = browser.isRenaming
        let wanted = renaming || (isShown ? zone != .outside : zone == .edge)
        guard wanted != isShown else { return }
        if renaming {
            setShown(true)
            return
        }
        let delay = wanted ? reveal.openDelay : reveal.closeDelay
        pending = Task {
            try? await Task.sleep(for: delay)
            while !wanted, !Task.isCancelled, browser.holdsPeek { try? await Task.sleep(for: delay) }
            if !Task.isCancelled { setShown(wanted) }
        }
    }

    private func setShown(_ shown: Bool) {
        withAnimation(.snappy(duration: 0.2)) { isShown = shown }
    }
}

/// Zen mode's top bar, slid down over the page by the pointer resting on the top edge.
/// ⌘L and ⌘T bring it at once and keep it until the address bar is done.
private struct ZenTopBarPeek: View {
    let style: SidebarStyle
    let colorHex: String
    @Binding var showsLights: Bool
    @Environment(Browser.self) private var browser
    @AppStorage(Preference.sidebarReveal) private var reveal = SidebarReveal.normal
    @State private var zone = PeekZone.outside
    @State private var isShown = false
    /// ⌘L came while the bar was away: its field takes the keyboard once it is there.
    @State private var focusOnAppear = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            PeekTracker(locate: PeekZone.top(of:)) { zone = $0 }
                .frame(height: Layout.topBarHeight + reveal.margin)
                .allowsHitTesting(false)
            if isShown {
                ZenTopBar(style: style, colorHex: colorHex)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        guard focusOnAppear else { return }
                        // On the next turn the field is in the window and sees the request.
                        DispatchQueue.main.async {
                            focusOnAppear = false
                            browser.requestAddressFocus()
                        }
                    }
            }
        }
        .onChange(of: zone) { update() }
        .onChange(of: browser.addressFocusToken) {
            guard !isShown else { return }
            focusOnAppear = true
            update()
        }
        .onChange(of: browser.isEditingAddress) { _, editing in
            // Return or Escape leaves the keyboard on the window, where keys beep; the bar is going.
            if !editing { browser.returnKeyboardToPage(fieldHadKeyboard: false) }
            update()
        }
        .onChange(of: browser.summaries.isPanelPresented) { update() }
        .onDisappear {
            pending?.cancel()
            showsLights = false
        }
    }

    private func update() {
        pending?.cancel()
        showsLights = isShown || zone == .corner
        // ⇧⌘S too: the summary's popover hangs from the bar's button.
        let typing = focusOnAppear || browser.isEditingAddress || browser.summaries.isPanelPresented
        let wanted = typing || (isShown ? zone != .outside : zone == .edge)
        guard wanted != isShown else { return }
        if typing {
            setShown(true)
            return
        }
        let delay = wanted ? reveal.openDelay : reveal.closeDelay
        pending = Task {
            try? await Task.sleep(for: delay)
            // A popover of the bar's (site information, downloads) would go with it.
            while !wanted, !Task.isCancelled, browser.holdsPeek { try? await Task.sleep(for: delay) }
            if !Task.isCancelled { setShown(wanted) }
        }
    }

    private func setShown(_ shown: Bool) {
        withAnimation(.snappy(duration: 0.2)) { isShown = shown }
        showsLights = shown || zone == .corner
    }
}

struct ZenTopBar: View {
    let style: SidebarStyle
    let colorHex: String

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Layout.trafficLightsWidth)
            ToolbarView()
        }
        .frame(height: Layout.topBarHeight)
        .background(WindowDragArea())
        .background { SidebarBackground(style: style, color: Color(hex: colorHex), blending: .withinWindow) }
        // Cast by a shape: a visual effect view (the translucent style) casts none.
        .background { Rectangle().fill(.background).shadow(color: .black.opacity(0.18), radius: 10, y: 2) }
    }
}

enum PeekZone {
    case outside, near, edge, corner

    /// A little wider than the window margin, so an edge is easy to hit.
    static let edgeSize: CGFloat = 10

    /// For the hidden sidebar: the left edge, from `top` down.
    static func left(of point: CGPoint, below top: CGFloat) -> PeekZone {
        point.x < edgeSize && point.y >= top ? .edge : .near
    }

    /// For Zen mode's top bar: the traffic lights' corner, and the top edge past it.
    static func top(of point: CGPoint) -> PeekZone {
        if point.x < Layout.trafficLightsWidth && point.y < Layout.topBarHeight { return .corner }
        return point.y < edgeSize ? .edge : .near
    }
}

/// Where the pointer is, for a hidden sidebar or top bar, judged by geometry alone: hover on the
/// panel itself flickered as it slid in under the pointer. Clicks go through to the page.
private struct PeekTracker: NSViewRepresentable {
    let locate: (CGPoint) -> PeekZone
    let onChange: (PeekZone) -> Void

    func makeNSView(context: Context) -> TrackerView { TrackerView() }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.locate = locate
        view.onChange = onChange
    }

    final class TrackerView: NSView {
        var locate: (CGPoint) -> PeekZone = { _ in .near }
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

        override func mouseEntered(with event: NSEvent) { track(event) }
        override func mouseMoved(with event: NSEvent) { track(event) }
        override func mouseExited(with event: NSEvent) { report(.outside) }

        private func track(_ event: NSEvent) {
            report(locate(convert(event.locationInWindow, from: nil)))
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

/// Centers the traffic lights in Lithium's taller top bar, and tells the browser its window.
private struct WindowConfigurator: NSViewRepresentable {
    let browser: Browser
    let hidesLights: Bool

    func makeNSView(context: Context) -> TrafficLightsView { TrafficLightsView(browser: browser) }

    func updateNSView(_ view: TrafficLightsView, context: Context) {
        view.hidesLights = hidesLights
    }

    final class TrafficLightsView: NSView {
        private weak var browser: Browser?
        private var observers: [NSObjectProtocol] = []
        private var isFullScreen = false
        var hidesLights = false {
            didSet { if hidesLights != oldValue { showOrHideLights() } }
        }

        init(browser: Browser) {
            self.browser = browser
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { return }
            browser?.window = window
            window.isMovableByWindowBackground = false
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.willEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.windowChanged(name) }
                }
            }
            isFullScreen = window.styleMask.contains(.fullScreen)
            showOrHideLights()
            layoutTrafficLights()
        }

        private func windowChanged(_ name: Notification.Name) {
            // Noted as the transitions start and end: layout runs in between, before the style mask says.
            if name == NSWindow.willEnterFullScreenNotification || name == NSWindow.didExitFullScreenNotification {
                isFullScreen = name == NSWindow.willEnterFullScreenNotification
                showOrHideLights()
            }
            if name == NSWindow.didBecomeKeyNotification { browser?.windowDidBecomeKey() }
            layoutTrafficLights()
        }

        override func layout() {
            super.layout()
            layoutTrafficLights()
        }

        /// Hidden rather than faded, so they take no clicks.
        private func showOrHideLights() {
            guard let window else { return }
            let hidden = hidesLights && !isFullScreen
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type), button.isHidden != hidden else { continue }
                button.isHidden = hidden
            }
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
