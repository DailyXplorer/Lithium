import AppKit
import SwiftUI

/// The selected tab's split: both pages, each with what the lone page has over it.
struct SplitPages: View {
    let split: TabSplit
    @Environment(Browser.self) private var browser

    var body: some View {
        if let first = browser.tabs.first(where: { $0.id == split.first }),
           let second = browser.tabs.first(where: { $0.id == split.second }) {
            SplitLayout(
                isStacked: split.isStacked,
                fraction: split.fraction,
                focused: split.side(of: browser.selectedTabID ?? first.id) ?? .first,
                resize: { browser.resizeSplit(of: first, to: $0) },
                menu: { SplitMenu(tab: first, isStacked: split.isStacked) },
                first: { SplitPane(tab: first) },
                second: { SplitPane(tab: second) }
            )
        }
    }
}

/// The divider's menu, and the tab list's for a pair.
struct SplitMenu: View {
    let tab: Tab
    let isStacked: Bool
    @Environment(Browser.self) private var browser

    var body: some View {
        Button("Swap Sides") { browser.swapSides(of: tab) }
        Button(isStacked ? "Show Side by Side" : "Stack Top and Bottom") { browser.toggleStacked(of: tab) }
        Divider()
        Button("Exit Split View") { browser.exitSplit(of: tab) }
    }
}

/// Two pages and the divider. The pages come from the caller, so a snapshot can use still images.
struct SplitLayout<Menu: View, First: View, Second: View>: View {
    let isStacked: Bool
    let fraction: Double
    let focused: TabSplit.Side
    /// On release only: the split itself (and the saved session) changes once.
    let resize: (_ fraction: Double) -> Void
    @ViewBuilder let menu: Menu
    @ViewBuilder let first: First
    @ViewBuilder let second: Second
    /// Also resets when the drag is cancelled (⌘-Tab away mid-drag), which skips `onEnded`.
    @GestureState private var dragFraction: Double?

    static var gap: CGFloat { 8 }

    var body: some View {
        GeometryReader { proxy in
            let length = isStacked ? proxy.size.height : proxy.size.width
            let firstLength = ((length - Self.gap) * (dragFraction ?? fraction)).rounded()
            let layout = isStacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                SplitPaneFrame(isFocused: focused == .first) { first }
                    .frame(width: isStacked ? nil : firstLength, height: isStacked ? firstLength : nil)
                SplitDivider(isStacked: isStacked)
                    .frame(width: isStacked ? nil : Self.gap, height: isStacked ? Self.gap : nil)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                            .updating($dragFraction) { value, fraction, _ in
                                fraction = min(max(share(at: value.location, in: length), TabSplit.fractions.lowerBound), TabSplit.fractions.upperBound)
                            }
                            .onEnded { resize(share(at: $0.location, in: length)) }
                    )
                    .contextMenu { menu }
                SplitPaneFrame(isFocused: focused == .second) { second }
            }
        }
        .coordinateSpace(.named(Self.space))
    }

    private static var space: String { "split" }

    private func share(at point: CGPoint, in length: CGFloat) -> Double {
        let offset = (isStacked ? point.y : point.x) - Self.gap / 2
        return length > Self.gap ? offset / (length - Self.gap) : 0.5
    }
}

private struct SplitPaneFrame<Content: View>: View {
    let isFocused: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.accentColor.opacity(isFocused ? 0.75 : 0), lineWidth: 2) }
    }
}

private struct SplitDivider: View {
    let isStacked: Bool
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Capsule()
                .fill(Color.primary.opacity(isHovered ? 0.4 : 0.2))
                .frame(width: isStacked ? 36 : 3, height: isStacked ? 3 : 36)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .pointerStyle(isStacked ? .rowResize : .columnResize)
        .help("Drag to resize, right-click for more")
    }
}

private struct SplitPane: View {
    let tab: Tab
    @Environment(Browser.self) private var browser

    var body: some View {
        Group {
            if browser.videoPopout.tab === tab {
                PoppedOutPlaceholder(popout: browser.videoPopout)
            } else {
                PageContainer(view: tab.webView)
                    .overlay {
                        if let pdf = tab.pdf {
                            SplitPDFReader(reader: pdf, tabID: tab.id, takesKeyboard: browser.selectedTabID == tab.id).id(ObjectIdentifier(pdf))
                        }
                    }
                    .overlay { BlockedPageLayer(tab: tab) }
                    .overlay {
                        if let acting = browser.agent?.tabs[tab.id]?.acting {
                            AgentActingOverlay(acting: acting)
                        }
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            if browser.showsFindBar(over: tab) {
                FindBar(tab: tab)
                    .padding(.top, tab.pdf == nil ? 10 : 50)
                    .padding(.horizontal, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        // `Browser.select` wakes both sides; this covers a split shown as the window opens.
        .onAppear { tab.markActive() }
    }
}

/// A split side's PDF viewer in its own AppKit view, so the window's click monitor
/// (`Browser.noteClick`) can tell a click on its controls from one on the peeked sidebar.
struct SplitPDFReader: NSViewRepresentable {
    let reader: PDFReader
    let tabID: Tab.ID
    let takesKeyboard: Bool

    func makeNSView(context: Context) -> Host {
        let host = Host(rootView: PDFReaderView(reader: reader, takesKeyboard: takesKeyboard))
        host.tabID = tabID
        return host
    }

    func updateNSView(_ host: Host, context: Context) {
        host.rootView = PDFReaderView(reader: reader, takesKeyboard: takesKeyboard)
        host.tabID = tabID
    }

    final class Host: NSHostingView<PDFReaderView> {
        var tabID: Tab.ID?

        required init(rootView: PDFReaderView) {
            super.init(rootView: rootView)
            sizingOptions = []
            // In Zen mode the page runs under the title bar: keeps the toolbar at the top, not below a blank strip.
            safeAreaRegions = []
        }

        required init?(coder: NSCoder) { nil }
    }
}

struct SplitTabRow: View {
    let split: TabSplit
    @Environment(Browser.self) private var browser

    var body: some View {
        if let first = browser.tabs.first(where: { $0.id == split.first }),
           let second = browser.tabs.first(where: { $0.id == split.second }) {
            let isShown = browser.selectedTabID.map(split.contains) ?? false
            SidebarRow(isSelected: isShown, action: { browser.selectSplit(showing: first) }) {
                half(first, dimmed: isShown && browser.selectedTabID != first.id)
                Rectangle()
                    .fill(.primary.opacity(0.15))
                    .frame(width: 1, height: 16)
                half(second, dimmed: isShown && browser.selectedTabID != second.id)
            }
            // As its first side: moving one side to a folder brings the other along.
            .draggable(browser.startDragging(first))
            .contextMenu {
                SplitMenu(tab: first, isStacked: split.isStacked)
                MoveToFolderMenu(browser: browser, tab: first)
                Divider()
                Button("Close Both Tabs") {
                    browser.close(second)
                    browser.close(first)
                }
            }
            .help("\(first.displayTitle) | \(second.displayTitle)")
        }
    }

    private func half(_ tab: Tab, dimmed: Bool) -> some View {
        HStack(spacing: 6) {
            Favicon(image: tab.favicon, fallback: tab.url?.host() ?? "", size: 16)
                .frame(width: 16, height: 16)
            Text(tab.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .opacity(dimmed ? 0.65 : 1)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { browser.select(tab) }
    }
}

/// Over the page while a tab is dragged from the sidebar: dropped on either side, it opens there.
struct SplitDropLayer: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        if let dragged = browser.splits.draggedTabID, let selected = browser.selectedTab,
           selected.id != dragged, selected.isInTabList {
            // A stacked split stays stacked, so its sides are top and bottom.
            SplitDropZone(isStacked: browser.split(of: selected)?.isStacked == true,
                          isDragging: { browser.splits.draggedTabID != nil }, carries: { browser.carriesDraggedTab($0) }) { item, side in
                withAnimation(.snappy(duration: 0.2)) { browser.dropForSplit(item, on: side) }
            }
        }
    }
}

/// AppKit, not SwiftUI's drop modifiers: the web view under it takes text drops itself, and
/// only a view above it in hit-testing order sees the drag first.
struct SplitDropZone: NSViewRepresentable {
    let isStacked: Bool
    let isDragging: () -> Bool
    let carries: (String?) -> Bool
    let drop: (String, TabSplit.Side) -> Bool

    func makeNSView(context: Context) -> DropView { DropView() }

    func updateNSView(_ view: DropView, context: Context) {
        view.isStacked = isStacked
        view.isDragging = isDragging
        view.carries = carries
        view.drop = drop
    }

    final class DropView: NSView {
        /// Sides are top (first) and bottom (second), as the split shows them.
        var isStacked = false
        /// Read as the mouse goes down: a drag that ended off the page is over before SwiftUI
        /// takes this view away.
        var isDragging: () -> Bool = { false }
        /// Whether the drag's text is the dragged tab's; anything else goes through to the page.
        var carries: (String?) -> Bool = { _ in false }
        var drop: (String, TabSplit.Side) -> Bool = { _, _ in false }
        private let highlight = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            highlight.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            highlight.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
            highlight.borderWidth = 2
            highlight.cornerRadius = 9
            highlight.isHidden = true
            layer?.addSublayer(highlight)
            registerForDraggedTypes([.string])
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Only the dragged tab lands here. Decided here, not on drag enter: the view only registers
        /// for text, so a file from Finder would never reach it, nor the page.
        override func hitTest(_ point: NSPoint) -> NSView? {
            takesMouse(buttons: NSEvent.pressedMouseButtons) ? super.hitTest(point) : nil
        }

        func takesMouse(buttons: Int, drag: @autoclosure () -> String? = NSPasteboard(name: .drag).string(forType: .string)) -> Bool {
            buttons & 1 != 0 && isDragging() && carries(drag())
        }

        /// The outer two fifths of each side; the middle drops nothing. Stacked, the top comes first
        /// (the view isn't flipped: y grows upwards).
        func side(at location: NSPoint) -> TabSplit.Side? {
            let point = convert(location, from: nil)
            if isStacked {
                return point.y > bounds.height * 0.6 ? .first : point.y < bounds.height * 0.4 ? .second : nil
            }
            return point.x < bounds.width * 0.4 ? .first : point.x > bounds.width * 0.6 ? .second : nil
        }

        /// The half `side` stands for, where the highlight shows.
        func frame(of side: TabSplit.Side) -> NSRect {
            if isStacked {
                let half = bounds.height / 2
                return NSRect(x: 0, y: side == .first ? half : 0, width: bounds.width, height: half)
            }
            let half = bounds.width / 2
            return NSRect(x: side == .second ? half : 0, y: 0, width: half, height: bounds.height)
        }

        private func show(_ side: TabSplit.Side?) -> NSDragOperation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlight.isHidden = side == nil
            if let side { highlight.frame = frame(of: side).insetBy(dx: 4, dy: 4) }
            CATransaction.commit()
            return side == nil ? [] : .move
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            show(carries(sender.draggingPasteboard.string(forType: .string)) ? side(at: sender.draggingLocation) : nil)
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            show(isDragging() ? side(at: sender.draggingLocation) : nil)
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            _ = show(nil)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            _ = show(nil)
            let item = sender.draggingPasteboard.string(forType: .string)
            guard carries(item), let item, let side = side(at: sender.draggingLocation) else { return false }
            return drop(item, side)
        }
    }
}
