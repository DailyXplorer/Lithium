import SwiftUI

enum HoverTarget: Hashable {
    case tab(Tab.ID)
    case pin(Pin.ID)
}

/// Which card is shown, for every row. Opening waits for the pointer to rest; closing waits a
/// moment, so the gap between two rows doesn't close it.
@MainActor
@Observable
final class TabHover {
    static let openDelay: Duration = .milliseconds(500)
    static let closeDelay: Duration = .milliseconds(150)

    private(set) var shown: HoverTarget?
    @ObservationIgnored private var pointer: HoverTarget?
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// Entering the next row may come before or after leaving the last: leaving only counts for
    /// the row the pointer is still on.
    func pointer(_ target: HoverTarget, isInside: Bool) {
        if isInside {
            pointer = target
        } else if pointer == target {
            pointer = nil
        } else {
            return
        }
        update()
    }

    func dismiss() {
        pending?.cancel()
        pointer = nil
        shown = nil
    }

    private func update() {
        pending?.cancel()
        guard pointer != shown else { return }
        if let pointer, shown != nil {
            shown = pointer
            return
        }
        let next = pointer
        pending = Task { [weak self] in
            try? await Task.sleep(for: next == nil ? Self.closeDelay : Self.openDelay)
            if !Task.isCancelled { self?.shown = next }
        }
    }
}

struct TabHoverAnchors: PreferenceKey {
    struct Value {
        var sidebar: Anchor<CGRect>?
        var row: [HoverTarget: Anchor<CGRect>] = [:]
    }

    static let defaultValue = Value()

    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        value.sidebar = value.sidebar ?? next.sidebar
        value.row.merge(next.row) { old, _ in old }
    }
}

extension View {
    /// Reports the pointer on this row to the hover card, and where the row is while its card is shown.
    func tabHoverTarget(_ target: HoverTarget, isHovered: Binding<Bool>) -> some View {
        modifier(TabHoverTargetModifier(target: target, isHovered: isHovered))
    }
}

private struct TabHoverTargetModifier: ViewModifier {
    let target: HoverTarget
    @Binding var isHovered: Bool
    @Environment(TabHover.self) private var hover

    func body(content: Content) -> some View {
        // Only the shown row reports, so scrolling the list doesn't redraw the window's overlay.
        let isShown = hover.shown == target
        content
            .onHover {
                isHovered = $0
                hover.pointer(target, isInside: $0)
            }
            // A row closed or scrolled away under the pointer never hears it leave.
            .onDisappear { hover.pointer(target, isInside: false) }
            // Simultaneous, so the row's own tap, double-click and drag still get theirs.
            .simultaneousGesture(TapGesture().onEnded { hover.dismiss() })
            .transformAnchorPreference(key: TabHoverAnchors.self, value: .bounds) { value, anchor in
                if isShown { value.row[target] = anchor }
            }
    }
}

/// The card over the window, beside the sidebar. It never takes a click.
struct TabHoverLayer: View {
    let anchors: TabHoverAnchors.Value
    @Environment(TabHover.self) private var hover
    @Environment(Browser.self) private var browser
    @Environment(BrowserWindow.self) private var window

    var body: some View {
        GeometryReader { proxy in
            if let target = hover.shown, let row = anchors.row[target], let sidebar = anchors.sidebar {
                let row = proxy[row]
                let isLow = row.midY > proxy.size.height / 2
                LiveTabHoverCard(target: target)
                    .id(target)
                    .offset(x: proxy[sidebar].maxX + 6, y: isLow ? row.maxY - proxy.size.height : row.minY)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isLow ? .bottomLeading : .topLeading)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: hover.shown == nil)
        .onChange(of: window.selectedTabID) { hover.dismiss() }
        .onChange(of: window.renamingTabID) { hover.dismiss() }
    }
}

/// Measured once a second while shown. The sampler lives in the task, so closing the card stops it.
private struct LiveTabHoverCard: View {
    let target: HoverTarget
    @Environment(Browser.self) private var browser
    @Environment(BrowserWindow.self) private var window
    @AppStorage(Preference.tabUsage) private var showsUsage = true
    @State private var usage: TabUsage?

    var body: some View {
        if let page {
            TabHoverCard(title: page.title, host: page.host, usage: showsUsage ? usage : nil, agent: page.tab.flatMap { agentNote(for: $0) })
                .task(id: showsUsage) {
                    usage = nil
                    guard showsUsage else { return }
                    var sampler = ResourceSampler()
                    while !Task.isCancelled {
                        usage = measure(with: &sampler)
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
        }
    }

    /// The full page title, which the row may shorten or replace with the user's own name.
    private var page: (tab: Tab?, title: String, host: String)? {
        switch target {
        case let .tab(id):
            guard let tab = browser.tabs.first(where: { $0.id == id }) else { return nil }
            return (tab, tab.title.isEmpty ? tab.displayTitle : tab.title, Self.host(of: tab.url))
        case let .pin(id):
            guard let pin = browser.pins.first(where: { $0.id == id }) else { return nil }
            let tab = browser.liveTab(for: pin, in: window.id)
            let title = tab.map { $0.title.isEmpty ? $0.displayTitle : $0.title } ?? pin.title
            return (tab, title, Self.host(of: tab?.url ?? pin.url))
        }
    }

    private func agentNote(for tab: Tab) -> String? {
        if tab.openedByAgent != nil { return "Opened by an agent" }
        return browser.agent?.isInUse(tab) == true ? "Used by an agent" : nil
    }

    private static func host(of url: URL?) -> String {
        let host = url?.host() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// nil hides the usage lines: no process to ask, or it didn't answer.
    private func measure(with sampler: inout ResourceSampler) -> TabUsage? {
        guard let tab = page?.tab, !tab.isAsleep, tab.loadedWebView != nil else { return .asleep }
        guard let pid = tab.webProcessIdentifier, let sample = sampler.sample(pid) else { return nil }
        let others = browser.tabs.filter { $0 !== tab }.map(\.webProcessIdentifier)
        return .live(footprint: sample.footprint, cpu: sample.cpu, sharedWith: TabUsage.sharing(pid, among: others))
    }
}

/// Plain values in, so it renders without a browser.
struct TabHoverCard: View {
    let title: String
    let host: String
    let usage: TabUsage?
    var agent: String?
    @Environment(\.sidebarPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Theme.font(12.5, .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !host.isEmpty {
                Text(host)
                    .font(Theme.font(11.5))
                    .lineLimit(1)
                    .opacity(0.6)
                    .padding(.top, 2)
            }
            if let agent {
                HStack(spacing: 5) {
                    Icon(.robot, size: 12)
                    Text(agent)
                }
                .font(Theme.font(11.5))
                .opacity(0.6)
                .padding(.top, 6)
            }
            if let usage {
                Rectangle()
                    .fill(palette.ink.opacity(0.1))
                    .frame(height: 1)
                    .padding(.vertical, 8)
                switch usage {
                case .asleep:
                    note("Asleep — not using memory")
                case let .live(footprint, cpu, sharedWith):
                    VStack(alignment: .leading, spacing: 3) {
                        line("Memory", UsageFormat.memory(footprint))
                        line("CPU", cpu.map(UsageFormat.cpu) ?? "—")
                        if sharedWith > 0 { note(UsageFormat.shared(with: sharedWith)).padding(.top, 2) }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        .foregroundStyle(palette.ink)
        .background(card.fill(palette.isDark ? Color(white: 0.17) : .white))
        .overlay(card.strokeBorder(palette.ink.opacity(palette.isDark ? 0.12 : 0.08)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }

    private var card: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).opacity(0.6)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .font(Theme.font(11.5))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(11.5))
            .opacity(0.6)
    }
}
