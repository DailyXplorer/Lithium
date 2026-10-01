import SwiftUI

struct SidebarHeader: View {
    var body: some View {
        HStack {
            Spacer()
            SidebarToggle()
        }
        .padding(.leading, Layout.trafficLightsWidth)
        .padding(.trailing, 8)
    }
}

struct SidebarToggle: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        IconButton(icon: .sidebar, help: "Toggle Sidebar (⌘B)") {
            withAnimation(.snappy(duration: 0.2)) { browser.toggleSidebar() }
        }
    }
}

struct SidebarView: View {
    @Environment(Browser.self) private var browser
    @Environment(\.sidebarPalette) private var palette
    @AppStorage(Preference.miniPlayer) private var showsMiniPlayer = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PinGrid()
            Rectangle()
                .fill(palette.ink.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 4)
            SidebarRow(isSelected: browser.selectedTabID == nil, action: { browser.newTabFocusingAddress() }) {
                Icon(.plus, size: 14)
                    .frame(width: 16)
                Text("New Tab")
            }
            .opacity(browser.selectedTabID == nil ? 1 : 0.7)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(browser.regularTabs) { tab in
                        TabRow(tab: tab)
                    }
                }
            }
            .scrollIndicators(.never)
            if showsMiniPlayer, let tab = playingTab, let media = browser.nowPlaying.media {
                MiniPlayer(nowPlaying: browser.nowPlaying, tab: tab, media: media)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: playingTab?.id)
        .padding(.top, 2)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var playingTab: Tab? {
        browser.nowPlaying.shownTab(besides: browser.videoPopout.tab)
    }
}

private struct PinGrid: View {
    @Environment(Browser.self) private var browser
    @Environment(\.sidebarPalette) private var palette
    @State private var isTargeted = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        Group {
            if browser.pins.isEmpty {
                Text("Drag a tab here to pin it")
                    .font(Theme.font(11))
                    .multilineTextAlignment(.center)
                    .opacity(0.55)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(palette.ink.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(browser.pins.enumerated()), id: \.element.id) { index, pin in
                        PinTile(pin: pin, index: index)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isTargeted ? palette.ink.opacity(0.08) : .clear)
                .padding(-4)
        )
        // Space around the tiles: a tab is pinned at the end, a favorite moves to the end.
        .dropDestination(for: String.self) { items, _ in
            browser.dropOnFavorites(items, at: nil)
        } isTargeted: { isTargeted = $0 }
    }
}

/// A favorite drags as `pin:<id>` and a tab as its bare id, both UUID strings: the prefix tells them apart.
private let pinDragPrefix = "pin:"

private extension Browser {
    /// A favorite moves into the slot, a tab is pinned there; `nil` is the end of the grid.
    func dropOnFavorites(_ items: [String], at index: Int?) -> Bool {
        guard let item = items.first else { return false }
        withAnimation(.snappy(duration: 0.2)) {
            if item.hasPrefix(pinDragPrefix) {
                if let id = UUID(uuidString: String(item.dropFirst(pinDragPrefix.count))) {
                    movePin(id: id, to: index ?? pins.count)
                }
            } else {
                pinTab(withID: item, at: index)
            }
        }
        return true
    }
}

private struct PinTile: View {
    let pin: Pin
    let index: Int
    @Environment(Browser.self) private var browser
    @Environment(\.sidebarPalette) private var palette
    @State private var isHovered = false
    @State private var isTargeted = false

    var body: some View {
        let live = browser.liveTab(for: pin)
        let isSelected = live != nil && live?.id == browser.selectedTabID
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isSelected ? palette.selection : palette.tile)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isHovered && !isSelected ? palette.hover : .clear))
            .frame(height: 48)
            .overlay {
                Favicon(image: browser.icon(for: pin), fallback: pin.url.host() ?? pin.title, size: 20)
            }
            // The slot a drop lands in: whatever is dragged takes this place and the tile shifts along.
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.ink.opacity(isTargeted ? 0.45 : 0), lineWidth: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture { browser.activate(pin) }
            .onHover { isHovered = $0 }
            .draggable(pinDragPrefix + pin.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                browser.dropOnFavorites(items, at: index)
            } isTargeted: { isTargeted = $0 }
            .help(pin.title)
            .contextMenu {
                if let live {
                    Button("Close Page") { browser.close(live) }
                }
                Button("Unpin") { browser.unpin(pin) }
            }
    }
}

private struct TabRow: View {
    let tab: Tab
    @Environment(Browser.self) private var browser
    @State private var isHovered = false

    var body: some View {
        let isSelected = browser.selectedTabID == tab.id
        SidebarRow(isSelected: isSelected, action: { browser.select(tab) }) {
            Group {
                if tab.favicon == nil && tab.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Favicon(image: tab.favicon, fallback: tab.url?.host() ?? "", size: 16)
                }
            }
            .frame(width: 16, height: 16)
            if browser.renamingTabID == tab.id {
                TabNameField(tab: tab)
            } else {
                Text(tab.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(tab.displayTitle == tab.title ? "" : tab.title)
            }
            Spacer(minLength: 0)
            if (isHovered || isSelected) && browser.renamingTabID != tab.id {
                Button { browser.close(tab) } label: {
                    Icon(.close, size: 12)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .help("Close Tab (⌘W)")
            }
        }
        .onHover { isHovered = $0 }
        // Simultaneous, so a single click still selects instantly instead of waiting for a second one.
        .simultaneousGesture(TapGesture(count: 2).onEnded { browser.renamingTabID = tab.id })
        .draggable(tab.id.uuidString)
        .contextMenu {
            Button("Rename Tab…") { browser.renamingTabID = tab.id }
            if tab.customTitle != nil {
                Button("Use Page Title") { browser.rename(tab, to: "") }
            }
            Divider()
            Button("Pin Tab") { browser.pin(tab) }
                .disabled(tab.url == nil)
            Button("Close Tab") { browser.close(tab) }
        }
    }
}

private struct TabNameField: View {
    let tab: Tab
    @Environment(Browser.self) private var browser
    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(tab.title.isEmpty ? "Tab name" : tab.title, text: $name)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit { browser.rename(tab, to: name) }
            .onAppear {
                name = tab.displayTitle
                claimFocus($isFocused)
            }
            .onChange(of: isFocused) { _, focused in
                // Clicking elsewhere keeps the new name, like renaming in Finder.
                if !focused, browser.renamingTabID == tab.id { browser.rename(tab, to: name) }
            }
    }
}

private struct SidebarRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.sidebarPalette) private var palette
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? palette.selection : (isHovered ? palette.hover : .clear))
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { isHovered = $0 }
    }
}

struct Favicon: View {
    let image: NSImage?
    let fallback: String
    let size: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        } else {
            Text(fallback.replacingOccurrences(of: "www.", with: "").prefix(1).uppercased())
                .font(Theme.font(size * 0.6, .semibold))
                .frame(width: size, height: size)
                .background(Circle().fill(.primary.opacity(0.1)))
        }
    }
}

struct IconButton: View {
    let icon: Phosphor
    let help: String
    var isEnabled = true
    let action: () -> Void
    @Environment(\.sidebarPalette) private var palette
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 16)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered && isEnabled ? palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 0.85 : 0.3)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
