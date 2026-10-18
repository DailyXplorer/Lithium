import SwiftUI

/// The window of a link from another app (`QuickLinks`): the page under a slim bar.
final class QuickLinkWindow: NSWindow, NSWindowDelegate {
    /// Not `tab`, which NSWindow has for window tabs.
    private let page: Tab
    private weak var browser: Browser?
    private static var lastTopLeft: NSPoint?
    private var sheetKeyObserver: NSObjectProtocol?

    static func open(_ tab: Tab, browser: Browser) -> NSWindow? {
        let window = QuickLinkWindow(tab: tab, browser: browser)
        // macOS may decline to activate Lithium (cooperative activation), leaving the window behind
        // the app in front: order it front first, then ask to become active for the keyboard.
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate()
        // Lithium becoming active can bring a browser window over this one: bring this one back on
        // the next run-loop turns and when Lithium becomes active (which can come later).
        for delay in [0.0, 0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in window?.bringForward() }
        }
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak window] _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            MainActor.assumeIsolated { window?.bringForward() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
        return window
    }

    private func bringForward() {
        guard isVisible else { return }
        orderFrontRegardless()
        makeKey()
    }

    private init(tab: Tab, browser: Browser) {
        page = tab
        self.browser = browser
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        tabbingMode = .disallowed
        minSize = NSSize(width: 420, height: 320)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        delegate = self
        contentView = NSHostingView(rootView: QuickLinkView(tab: tab) { [weak self] in self?.title = $0 }.environment(browser))
        let isFirst = !NSApp.windows.contains { $0 is QuickLinkWindow && $0 !== self && $0.isVisible }
        if let last = Self.lastTopLeft, !isFirst {
            Self.lastTopLeft = cascadeTopLeft(from: last)
        } else {
            center()
            Self.lastTopLeft = NSPoint(x: frame.minX, y: frame.maxY)
        }
    }

    /// ⌘W: with its close button hidden, the window would take itself for one that can't close.
    override func performClose(_ sender: Any?) {
        close()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        browser?.quickLinks.windowBecameKey(page)
    }

    func windowDidResignKey(_ notification: Notification) {
        browser?.quickLinks.windowResignedKey(page, toSheet: attachedSheet != nil)
    }

    /// Clicking back to this window while its sheet is up makes the sheet key, not this window: the
    /// link is in front again all the same. Watched only while a sheet is up.
    func windowWillBeginSheet(_ notification: Notification) {
        guard sheetKeyObserver == nil else { return }
        sheetKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSApp.keyWindow?.sheetParent === self else { return }
                self.browser?.quickLinks.windowBecameKey(self.page)
            }
        }
    }

    func windowDidEndSheet(_ notification: Notification) {
        guard attachedSheet == nil, let sheetKeyObserver else { return }
        NotificationCenter.default.removeObserver(sheetKeyObserver)
        self.sheetKeyObserver = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let sheetKeyObserver { NotificationCenter.default.removeObserver(sheetKeyObserver) }
        sheetKeyObserver = nil
        browser?.quickLinks.windowClosed(page)
        // A late update of the closed view would take the web view back from the main window.
        contentView = nil
    }
}

struct QuickLinkView: View {
    let tab: Tab
    /// The page's title, for the Window menu and Mission Control.
    let onTitle: (String) -> Void
    @Environment(Browser.self) private var browser

    var body: some View {
        VStack(spacing: 0) {
            QuickLinkBar(url: tab.url, isSecure: tab.connection == .secure) {
                browser.quickLinks.close(tab)
            } onMove: {
                browser.quickLinks.moveToBrowserWindow(tab)
            }
            .overlay { LoadingBar(tab: tab) }
            .background(WindowDragArea())
            // The main window's prompts show for its selected tab only; this page's show here.
            if let request = browser.permissions.pending.first(where: { $0.tabID == tab.id }) {
                PermissionPrompt(request: request)
            }
            if let request = browser.appLinks.pending.first(where: { $0.tabID == tab.id }) {
                AppLinkPrompt(request: request).id(request.id)
            }
            if let request = browser.passwords.pending.first(where: { $0.tabID == tab.id }) {
                PasswordSaveBar(request: request) { browser.passwords.answer(request, $0) }.id(request.id)
            }
            PageContainer(view: tab.webView)
                .overlay {
                    if let pdf = tab.pdf {
                        PDFReaderView(reader: pdf).id(ObjectIdentifier(pdf))
                    }
                }
                .overlay { BlockedPageLayer(tab: tab) }
                .overlay { PasswordDropdownLayer(tab: tab) }
                .overlay(alignment: .topTrailing) {
                    if browser.quickLinks.showsFindBar(over: tab) {
                        FindBar(find: browser.quickLinks.find, tab: tab)
                            .padding(.top, tab.pdf == nil ? 10 : 50)
                            .padding(.horizontal, 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.2), value: browser.quickLinks.find.isVisible)
        }
        .font(Theme.font(13))
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .onChange(of: tab.displayTitle, initial: true) { onTitle(tab.displayTitle) }
    }
}

struct QuickLinkBar: View {
    let url: URL?
    let isSecure: Bool
    let onClose: () -> Void
    let onMove: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            IconButton(icon: .close, help: "Close (⌘W)", action: onClose)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                if let url, QuickLinks.takes(url) {
                    Icon(isSecure ? .lock : .lockOpen, size: 13)
                        .foregroundStyle(isSecure ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
                Text(Self.site(of: url))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            .help(url?.absoluteString ?? "")
            Spacer(minLength: 8)
            IconButton(icon: .returnToTab, help: "Move to window (⌘O)", action: onMove)
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
        // Hover as on the window's own background, not the sidebar's color.
        .environment(\.sidebarPalette, SidebarPalette(style: .translucent, colorHex: Theme.defaultSidebarHex, scheme: colorScheme))
    }

    static func site(of url: URL?) -> String {
        guard let url else { return "" }
        guard let host = url.host(), !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
