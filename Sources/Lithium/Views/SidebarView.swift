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
    @State private var deletingFolder: TabFolder?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            spaceContent
                .id(browser.currentSpaceID)
                .transition(.push(from: browser.spaceStepsForward ? .trailing : .leading))
            if showsMiniPlayer, let tab = playingTab, let media = browser.nowPlaying.media {
                MiniPlayer(nowPlaying: browser.nowPlaying, tab: tab, media: media)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            SpaceBar()
        }
        .animation(.snappy(duration: 0.2), value: playingTab?.id)
        .padding(.top, 2)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .background {
            SpaceSwipeArea(isEnabled: browser.hasSpaces) { offset in
                withAnimation(.snappy(duration: 0.25)) { browser.switchSpace(by: offset) }
            }
        }
        .transformAnchorPreference(key: TabHoverAnchors.self, value: .bounds) { $0.sidebar = $1 }
    }

    private var spaceContent: some View {
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
            .contextMenu { ReopenClosedTabButton() }
            // The top of the tab list, which is there to drop on even when the list is empty.
            .dropDestination(for: String.self) { items, _ in dropTab(items, on: .tabList(0)) }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(browser.tabListRows) { row in
                        switch row {
                        case .folder(let folder):
                            FolderHeader(folder: folder) { askToDelete(folder) }
                        case .tab(let entry):
                            let index = entry.index
                            let folder = entry.tab.folderID
                            Group {
                                if let split = entry.split { SplitTabRow(split: split) } else { TabRow(tab: entry.tab) }
                            }
                            .padding(.leading, folder == nil ? 0 : folderIndent)
                            .dropDestination(for: String.self) { items, location in
                                let place = location.y < sidebarRowHeight / 2 ? index : index + 1
                                return dropTab(items, on: folder.map { Browser.TabDropTarget.folder($0, place) } ?? .tabList(place))
                            }
                        }
                    }
                    let agentTabs = browser.agentTabs
                    if !agentTabs.isEmpty {
                        VStack(spacing: 2) {
                            AgentGroupHeader()
                            ForEach(agentTabs) { tab in
                                TabRow(tab: tab)
                            }
                        }
                        .dropDestination(for: String.self) { items, _ in dropTab(items, on: .agentGroup) }
                    }
                }
            }
            .scrollIndicators(.never)
            // The empty space below the tabs too; a row's own menu wins over this one.
            .contentShape(Rectangle())
            .contextMenu {
                Button("New Folder") { withAnimation(.snappy(duration: 0.2)) { browser.newFolder() } }
                ReopenClosedTabButton()
            }
        }
        .alert(deletingFolder.map { "Delete “\($0.name)”?" } ?? "", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }), presenting: deletingFolder) { folder in
            Button("Keep Tabs") { deleteFolder(folder, closingTabs: false) }
            Button("Close Tabs", role: .destructive) { deleteFolder(folder, closingTabs: true) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its tabs can stay in the tab list or close.")
        }
    }

    private var playingTab: Tab? {
        browser.nowPlaying.shownTab(besides: browser.videoPopout.tab)
    }

    private func askToDelete(_ folder: TabFolder) {
        if browser.tabList(in: folder.space, folder: folder.id).isEmpty {
            deleteFolder(folder, closingTabs: false)
        } else {
            deletingFolder = folder
        }
    }

    private func deleteFolder(_ folder: TabFolder, closingTabs: Bool) {
        withAnimation(.snappy(duration: 0.2)) { browser.deleteFolder(folder.id, closingTabs: closingTabs) }
    }

    private func dropTab(_ items: [String], on target: Browser.TabDropTarget) -> Bool {
        withAnimation(.snappy(duration: 0.2)) { browser.dropTab(items, on: target) }
    }
}

private struct PinGrid: View {
    @Environment(Browser.self) private var browser
    @Environment(\.sidebarPalette) private var palette
    @State private var isTargeted = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        Group {
            if browser.spacePins.isEmpty {
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
                    ForEach(Array(browser.spacePins.enumerated()), id: \.element.id) { index, pin in
                        PinTile(pin: pin, index: index)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isTargeted ? palette.tile : .clear)
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
        endTabDrag()
        guard let item = items.first else { return false }
        withAnimation(.snappy(duration: 0.2)) {
            if item.hasPrefix(pinDragPrefix) {
                if let id = UUID(uuidString: String(item.dropFirst(pinDragPrefix.count))) {
                    movePin(id: id, to: index ?? spacePins.count)
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
            .fill(palette.tileFill(isSelected: isSelected, isHovered: isHovered))
            .frame(height: 48)
            .overlay {
                BadgedFavicon(image: browser.icon(for: pin), fallback: pin.url.host() ?? pin.title, badge: live?.unread.shown)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.ink.opacity(isTargeted ? 0.45 : 0), lineWidth: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture { browser.activate(pin) }
            .tabHoverTarget(.pin(pin.id), isHovered: $isHovered)
            .draggable(pinDragPrefix + pin.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                browser.dropOnFavorites(items, at: index)
            } isTargeted: { isTargeted = $0 }
            .contextMenu {
                if let live {
                    Button("Duplicate Tab") { browser.duplicate(live) }
                    MuteButton(tab: live)
                    Divider()
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
            .overlay(alignment: .bottomTrailing) {
                if browser.agent?.isTouched(tab) == true { AgentBadge(isActing: browser.agent?.isActing(in: tab) == true) }
            }
            if browser.renamingTabID == tab.id {
                TabNameField(tab: tab)
            } else {
                Text(tab.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if tab.isEphemeral { PrivateTabBadge() }
            if tab.isMuted {
                Button { tab.isMuted = false } label: {
                    Icon(.speakerOff, size: 12)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .help("Unmute Tab")
            }
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
        .tabHoverTarget(.tab(tab.id), isHovered: $isHovered)
        // Simultaneous, so a single click still selects instantly instead of waiting for a second one.
        .simultaneousGesture(TapGesture(count: 2).onEnded { browser.renamingTabID = tab.id })
        .draggable(browser.startDragging(tab))
        .contextMenu {
            Button("Reload Tab") { browser.navigate(tab, .reload) }
                .disabled(tab.url == nil)
            if tab.isInTabList {
                Button("Open in Split View") { browser.openInSplit(tab) }
                    .disabled(browser.splitPartner(for: tab) == nil)
            }
            Button("Duplicate Tab") { browser.duplicate(tab) }
                .disabled(tab.url == nil)
            MuteButton(tab: tab)
            Button("Sleep Other Tabs") { browser.sleepOtherTabs(than: tab) }
                .disabled(!browser.canSleepOtherTabs(than: tab))
            Divider()
            Button("Copy Link") { browser.copyLink(of: tab) }
                .disabled(tab.url == nil)
            Divider()
            Button("Rename Tab…") { browser.renamingTabID = tab.id }
            if tab.customTitle != nil {
                Button("Use Page Title") { browser.rename(tab, to: "") }
            }
            Button("Pin Tab") { browser.pin(tab) }
                .disabled(tab.url == nil || tab.isEphemeral)
            if tab.openedByAgent != nil {
                Button("Move to Tab List") { withAnimation(.snappy(duration: 0.2)) { browser.keep(tab) } }
            }
            MoveToFolderMenu(browser: browser, tab: tab)
            Divider()
            Button("Close Tab") { browser.close(tab) }
            Button("Close Other Tabs") { browser.closeOtherTabs(than: tab) }
                .disabled(browser.peers(of: tab).allSatisfy { $0 === tab })
            Button("Close Tabs Above") { browser.closeTabs(above: tab) }
                .disabled(browser.tabs(above: tab).isEmpty)
            Button("Close Tabs Below") { browser.closeTabs(below: tab) }
                .disabled(browser.tabs(below: tab).isEmpty)
            Divider()
            ReopenClosedTabButton()
        }
    }
}

private struct AgentGroupHeader: View {
    var body: some View {
        HStack(spacing: 6) {
            Icon(.robot, size: 12)
            Text("Agent tabs")
        }
        .font(Theme.font(11.5, .medium))
        .opacity(0.55)
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// On the favicon of a tab an agent acted in, until the tab closes.
struct AgentBadge: View {
    var isActing = false
    @Environment(\.sidebarPalette) private var palette

    var body: some View {
        Icon(.robotFill, size: 8)
            .frame(width: 11, height: 11)
            .background(Circle().fill(palette.isDark ? Color(white: 0.17) : .white))
            .overlay { if isActing { Circle().strokeBorder(Color.accentColor, lineWidth: 1.5).padding(-1.5) } }
            .offset(x: 4, y: 4)
            .help("Used by an agent")
    }
}

struct PrivateTabBadge: View {
    var body: some View {
        Icon(.privateTab, size: 12)
            .frame(width: 18, height: 18)
            .opacity(0.6)
            .help("Private tab: not saved in history, and its cookies go when it closes")
    }
}

/// Hidden where WebKit has no per-page mute.
private struct MuteButton: View {
    let tab: Tab

    var body: some View {
        if Tab.canMute {
            Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { tab.isMuted.toggle() }
        }
    }
}

private struct ReopenClosedTabButton: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        Button("Reopen Closed Tab") { browser.reopenClosedTab() }
            .disabled(!browser.canReopenClosedTab)
    }
}

private struct TabNameField: View {
    let tab: Tab
    @Environment(Browser.self) private var browser
    @State private var name = ""
    /// The title the field opened with: left as is, it doesn't become the tab's name.
    @State private var shown: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(tab.title.isEmpty ? "Tab name" : tab.title, text: $name)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit { commit() }
            .onAppear {
                shown = tab.displayTitle
                name = browser.renameDraft ?? tab.displayTitle
                claimFocus($isFocused)
            }
            .onChange(of: name) { browser.renameDraft = name }
            .onChange(of: isFocused) { _, focused in
                if !focused, browser.renamingTabID == tab.id { commit() }
            }
            // Hiding the sidebar (⌘B) would otherwise leave the rename open, holding Escape and the
            // peek. Not when the row only scrolls out of the lazy list.
            .onDisappear {
                if browser.renamingTabID == tab.id, !browser.showsSidebar { commit() }
            }
    }

    /// On the next turn: moving the keyboard while the field ends its own editing (Return) left
    /// SwiftUI's focus behind, and the next rename's field couldn't take it.
    private func commit() {
        browser.rename(tab, to: name, shown: shown)
        let hadKeyboard = isFocused
        DispatchQueue.main.async { [browser] in browser.returnKeyboardToPage(fieldHadKeyboard: hadKeyboard) }
    }
}

private let sidebarRowHeight: CGFloat = 34
/// A folder's tabs sit this far in from its header.
private let folderIndent: CGFloat = 14

struct SidebarRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.sidebarPalette) private var palette
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 10)
            .frame(height: sidebarRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.rowFill(isSelected: isSelected, isHovered: isHovered))
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

/// A favorite's icon with its unread badge at the top right, as an overlay so it never moves the icon.
struct BadgedFavicon: View {
    let image: NSImage?
    let fallback: String
    let badge: UnreadBadge.Shown?

    var body: some View {
        Favicon(image: image, fallback: fallback, size: 20)
            .overlay(alignment: .topTrailing) {
                if let badge {
                    // A frame of no size centers the badge on the icon's corner.
                    UnreadBadgeView(shown: badge)
                        .frame(width: 0, height: 0)
                        .offset(x: -2, y: 2)
                }
            }
    }
}

struct UnreadBadgeView: View {
    let shown: UnreadBadge.Shown

    var body: some View {
        Group {
            switch shown {
            case .dot:
                Circle()
                    .fill(Color(nsColor: .systemRed))
                    .frame(width: 8, height: 8)
            case .count(let count):
                Text(UnreadBadge.label(count))
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3.5)
                    .frame(minWidth: 13, minHeight: 13)
                    .background(Capsule().fill(Color(nsColor: .systemRed)))
                    .fixedSize()
            }
        }
        // Keeps the red off an icon or a tile of the same color.
        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
        .accessibilityElement()
        .accessibilityLabel(UnreadBadge.accessibilityLabel(shown))
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
