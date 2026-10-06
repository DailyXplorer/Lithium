import AppKit
import SwiftUI

/// The selected tab's split: both pages, each with what the lone page has over it.
struct SplitPages: View {
    let split: TabSplit
    @Environment(Browser.self) private var browser
    /// While the divider moves; the split itself (and the saved session) changes once, on release.
    @State private var liveFraction: Double?

    var body: some View {
        if let first = browser.tabs.first(where: { $0.id == split.first }),
           let second = browser.tabs.first(where: { $0.id == split.second }) {
            SplitLayout(
                isStacked: split.isStacked,
                fraction: liveFraction ?? split.fraction,
                focused: split.side(of: browser.selectedTabID ?? first.id) ?? .first,
                resize: { fraction, ended in
                    if ended {
                        browser.resizeSplit(of: first, to: fraction)
                        liveFraction = nil
                    } else {
                        liveFraction = min(max(fraction, TabSplit.fractions.lowerBound), TabSplit.fractions.upperBound)
                    }
                },
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

/// Two pages and the divider between them. The pages come from the caller, so a snapshot can
/// lay out still images where the app has web views.
struct SplitLayout<Menu: View, First: View, Second: View>: View {
    let isStacked: Bool
    /// The first page's share.
    let fraction: Double
    let focused: TabSplit.Side
    let resize: (_ fraction: Double, _ ended: Bool) -> Void
    @ViewBuilder let menu: Menu
    @ViewBuilder let first: First
    @ViewBuilder let second: Second

    static var gap: CGFloat { 8 }

    var body: some View {
        GeometryReader { proxy in
            let length = isStacked ? proxy.size.height : proxy.size.width
            let firstLength = ((length - Self.gap) * fraction).rounded()
            let layout = isStacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                SplitPaneFrame(isFocused: focused == .first) { first }
                    .frame(width: isStacked ? nil : firstLength, height: isStacked ? firstLength : nil)
                SplitDivider(isStacked: isStacked)
                    .frame(width: isStacked ? nil : Self.gap, height: isStacked ? Self.gap : nil)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                            .onChanged { resize(share(at: $0.location, in: length), false) }
                            .onEnded { resize(share(at: $0.location, in: length), true) }
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

/// Rounded like the page card, with an accent ring on the side the keyboard and toolbar act on.
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
                            PDFReaderView(reader: pdf).id(ObjectIdentifier(pdf))
                        }
                    }
                    .overlay {
                        if let acting = browser.agent?.tabs[tab.id]?.acting {
                            AgentActingOverlay(acting: acting)
                        }
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            if browser.find.isVisible, browser.selectedTabID == tab.id {
                FindBar(tab: tab)
                    .padding(.top, tab.pdf == nil ? 10 : 50)
                    .padding(.horizontal, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Both sides wake as one of them is selected (`Browser.select`); this covers a split
        // shown some other way, as the window opens.
        .onAppear { tab.markActive() }
    }
}

/// The tab list's row for a pair: each half shows its tab and selects it.
struct SplitTabRow: View {
    let split: TabSplit
    @Environment(Browser.self) private var browser

    var body: some View {
        if let first = browser.tabs.first(where: { $0.id == split.first }),
           let second = browser.tabs.first(where: { $0.id == split.second }) {
            let isShown = browser.selectedTabID.map(split.contains) ?? false
            SidebarRow(isSelected: isShown, action: { browser.select(first) }) {
                half(first, dimmed: isShown && browser.selectedTabID != first.id)
                Rectangle()
                    .fill(.primary.opacity(0.15))
                    .frame(width: 1, height: 16)
                half(second, dimmed: isShown && browser.selectedTabID != second.id)
            }
            .contextMenu {
                SplitMenu(tab: first, isStacked: split.isStacked)
                Divider()
                Button("Close Both Tabs") {
                    browser.close(second)
                    browser.close(first)
                }
            }
            .help("\(first.displayTitle) | \(second.displayTitle)")
        }
    }

    /// The side not focused is dimmed, so the row tells which one the toolbar acts on.
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

/// Over the page while a tab is dragged from the sidebar: dropped on the left or right of the
/// page, the tab opens there beside the selected one. Only in the window during such a drag.
struct SplitDropLayer: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        if let dragged = browser.splits.draggedTabID, let selected = browser.selectedTab,
           selected.id != dragged, selected.isInTabList {
            SplitDropZone(isDragging: { browser.splits.draggedTabID != nil }) { item, side in
                withAnimation(.snappy(duration: 0.2)) { browser.dropForSplit(item, on: side) }
            }
        }
    }
}

/// AppKit, not SwiftUI's drop modifiers: the web view under it takes text drops itself, and
/// only a view above it in hit-testing order sees the drag first.
struct SplitDropZone: NSViewRepresentable {
    let isDragging: () -> Bool
    let drop: (String, TabSplit.Side) -> Bool

    func makeNSView(context: Context) -> DropView { DropView() }

    func updateNSView(_ view: DropView, context: Context) {
        view.isDragging = isDragging
        view.drop = drop
    }

    final class DropView: NSView {
        /// Read as the mouse goes down: a drag that ended off the page (in the sidebar, or with
        /// Escape) is over once the click monitor has seen the next click, though SwiftUI has
        /// yet to take this view away.
        var isDragging: () -> Bool = { false }
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

        /// Clicks go on to the page; only a drag, with the button down, lands here.
        override func hitTest(_ point: NSPoint) -> NSView? {
            takesMouse(buttons: NSEvent.pressedMouseButtons) ? super.hitTest(point) : nil
        }

        func takesMouse(buttons: Int) -> Bool {
            buttons & 1 != 0 && isDragging()
        }

        /// The outer two fifths of each side; the middle drops nothing.
        private func side(at location: NSPoint) -> TabSplit.Side? {
            let x = convert(location, from: nil).x
            return x < bounds.width * 0.4 ? .first : x > bounds.width * 0.6 ? .second : nil
        }

        private func show(_ side: TabSplit.Side?) -> NSDragOperation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlight.isHidden = side == nil
            let half = bounds.width / 2
            highlight.frame = NSRect(x: side == .second ? half : 0, y: 0, width: half, height: bounds.height).insetBy(dx: 4, dy: 4)
            CATransaction.commit()
            return side == nil ? [] : .move
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            show(side(at: sender.draggingLocation))
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            show(side(at: sender.draggingLocation))
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            _ = show(nil)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            _ = show(nil)
            guard let side = side(at: sender.draggingLocation),
                  let item = sender.draggingPasteboard.string(forType: .string) else { return false }
            return drop(item, side)
        }
    }
}
