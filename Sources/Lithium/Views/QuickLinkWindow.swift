import SwiftUI

/// The window of a link from another app (`QuickLinks`): the page under a slim bar. Made when the
/// link comes, gone once it closes or its page moves into the main window.
final class QuickLinkWindow: NSWindow, NSWindowDelegate {
    /// Not `tab`, which NSWindow has for window tabs.
    private let page: Tab
    private weak var browser: Browser?
    /// Where the last one opened, so the next link's window doesn't cover it.
    private static var lastTopLeft: NSPoint?

    static func open(_ tab: Tab, browser: Browser) -> NSWindow? {
        let window = QuickLinkWindow(tab: tab, browser: browser)
        // The link comes while another app is in front, and macOS may decline to activate Lithium
        // for it (cooperative activation): the window would open behind that app, unseen. Put it in
        // front of every app's windows first, then ask to become active so it takes the keyboard.
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate()
        return window
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
        // The bar has its own Close; the traffic lights would only crowd it.
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
        browser?.quickLinks.windowResignedKey(page)
    }

    func windowWillClose(_ notification: Notification) {
        browser?.quickLinks.windowClosed(page)
        // Gone at once: a late update of the closed view would take the web view back from the
        // main window, which the page may just have moved to.
        contentView = nil
    }
}

struct QuickLinkView: View {
    let tab: Tab
    /// The page's title, for the Window menu and Mission Control.
    let onTitle: (String) -> Void
    @Environment(Browser.self) private var browser
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            QuickLinkBar(url: tab.url, isSecure: tab.connection == .secure) {
                browser.quickLinks.close(tab)
            } onMove: {
                browser.quickLinks.moveToMainWindow(tab)
                // Brings it back if the user closed it.
                openWindow(id: "browser")
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
            PageContainer(view: tab.webView)
                .overlay {
                    if let pdf = tab.pdf {
                        PDFReaderView(reader: pdf).id(ObjectIdentifier(pdf))
                    }
                }
        }
        .font(Theme.font(13))
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .onChange(of: tab.displayTitle, initial: true) { onTitle(tab.displayTitle) }
    }
}

/// Close, the page's site, and Move to main window.
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
            IconButton(icon: .returnToTab, help: "Move to main window (⌘O)", action: onMove)
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
        // Hover as on the window's own background, not the sidebar's color.
        .environment(\.sidebarPalette, SidebarPalette(style: .translucent, colorHex: Theme.defaultSidebarHex, scheme: colorScheme))
    }

    /// The site without its "www.", as Safari's compact address shows it.
    static func site(of url: URL?) -> String {
        guard let url else { return "" }
        guard let host = url.host(), !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
