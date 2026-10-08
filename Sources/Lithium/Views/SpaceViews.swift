import AppKit
import SwiftUI

/// The foot of the sidebar: a button per space once there are two, then New Space. A click (or
/// ⌃1…⌃9, or a two-finger swipe across the sidebar) switches; a right-click edits or deletes.
struct SpaceBar: View {
    @Environment(Browser.self) private var browser
    @State private var editing: Space.ID?
    @State private var isCreating = false
    @State private var deleting: Space?

    var body: some View {
        HStack(spacing: 2) {
            if browser.hasSpaces {
                ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { index, space in
                    SpaceButton(space: space, number: index + 1, isCurrent: space.id == browser.currentSpaceID) {
                        withAnimation(.snappy(duration: 0.25)) { browser.switchToSpace(space.id) }
                    }
                    .contextMenu {
                        Button("Edit Space…") { editing = space.id }
                        if space.id != Space.mainID {
                            Button("Delete Space…") { deleting = space }
                        }
                    }
                    .popover(isPresented: Binding(get: { editing == space.id }, set: { if !$0 { editing = nil } }), arrowEdge: .top) {
                        SpaceEditor(space: space, isNew: false) { browser.updateSpace($0) } close: { editing = nil }
                    }
                }
            }
            Spacer(minLength: 0)
            IconButton(icon: .folder, help: "New folder (⌥⌘N)") {
                withAnimation(.snappy(duration: 0.2)) { browser.newFolder() }
            }
            IconButton(icon: .plus, help: "New space", isEnabled: browser.canAddSpace) { isCreating = true }
                .popover(isPresented: $isCreating, arrowEdge: .top) {
                    SpaceEditor(space: browser.newSpaceDraft(), isNew: true) { space in
                        withAnimation(.snappy(duration: 0.25)) { browser.addSpace(space) }
                    } close: { isCreating = false }
                }
        }
        .alert(deleting.map { "Delete “\($0.name)”?" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { space in
            Button("Delete", role: .destructive) {
                withAnimation(.snappy(duration: 0.25)) { browser.deleteSpace(space.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { space in
            Text(space.separatesData ? "Its tabs and favorites close, and its cookies and logins are deleted." : "Its tabs and favorites close.")
        }
    }
}

/// A space's icon. The one shown sits on the current tab row's light surface, the others on
/// nothing and dimmed: one space is always current, so it needs marking, not a strong fill.
struct SpaceButton: View {
    let space: Space
    let number: Int
    let isCurrent: Bool
    let action: () -> Void
    @Environment(\.sidebarPalette) private var palette
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            SpaceIcon(space.icon, size: 14)
                .frame(maxWidth: 28)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Self.fill(palette, isCurrent: isCurrent, isHovered: isHovered))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isCurrent ? 1 : 0.6)
        .onHover { isHovered = $0 }
        .help("\(space.name) (⌃\(number))")
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// The tab rows' fills: a hovered space gets half the current one's, so it never looks current.
    static func fill(_ palette: SidebarPalette, isCurrent: Bool, isHovered: Bool) -> Color {
        palette.rowFill(isSelected: isCurrent, isHovered: isHovered)
    }
}

/// Name, color and icon of a space; for a new one, also whether it keeps its own cookies and
/// logins, which can't change afterwards.
struct SpaceEditor: View {
    @State var space: Space
    let isNew: Bool
    let save: (Space) -> Void
    let close: () -> Void
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New space" : "Edit space")
                .font(Theme.font(13, .semibold))
            TextField("Name", text: $space.name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(commit)
            HStack(spacing: 6) {
                ForEach(Space.colors, id: \.self) { hex in
                    Button { space.color = hex } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .overlay { Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1) }
                            .padding(3)
                            .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(space.color == hex ? 1 : 0) }
                            .frame(width: 24, height: 24)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(hex)
                }
            }
            SpaceIconPicker(icon: $space.icon)
            if isNew {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Separate cookies and logins", isOn: $space.separatesData)
                    Text("Sign in to sites with another account here. Can't be changed later.")
                        .font(Theme.font(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if space.separatesData {
                Text("Has its own cookies and logins.")
                    .font(Theme.font(11))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save", action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(Theme.font(13))
        .padding(14)
        .frame(width: 252)
        .onAppear { isNameFocused = true }
    }

    private func commit() {
        save(space)
        close()
    }
}

/// The space editor's icons: Icons or Emoji, a search field, a suggested row, then the rest in a
/// lazy grid, so only the cells scrolled into view are made. The catalog is built off the main
/// thread as the editor opens, and goes when it closes.
struct SpaceIconPicker: View {
    @Binding var icon: String
    @State private var catalog: SpaceIconCatalog?
    @State private var showsEmoji: Bool
    @State private var query = ""

    /// Seven cells fill the editor's width.
    private static let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 7)
    static let suggestedEmoji = ["🏠", "💼", "🎓", "💰", "🎵", "\u{2708}\u{FE0F}", "🎮"]

    /// `catalog` is for snapshots; the editor builds its own.
    init(icon: Binding<String>, catalog: SpaceIconCatalog? = nil) {
        _icon = icon
        _catalog = State(initialValue: catalog)
        _showsEmoji = State(initialValue: Space.isEmoji(icon.wrappedValue))
    }

    var body: some View {
        let all = catalog.map { showsEmoji ? $0.emoji : $0.icons } ?? []
        let results = query.isEmpty ? [] : SpaceIconCatalog.search(query, in: all)
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("Icons or emoji", selection: $showsEmoji) {
                    Text("Icons").tag(false)
                    Text("Emoji").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ScrollView {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 4) {
                    if query.isEmpty {
                        Section { ForEach(suggested, content: cell) }
                        Section { ForEach(all, content: cell) } header: { Divider().padding(.vertical, 2) }
                    } else {
                        ForEach(results, content: cell)
                    }
                }
            }
            .id(showsEmoji)
            .frame(height: 140)
            .overlay {
                if !query.isEmpty, results.isEmpty, catalog != nil {
                    Text("No matches").foregroundStyle(.secondary)
                }
            }
        }
        .task {
            guard catalog == nil else { return }
            catalog = await Task.detached(priority: .userInitiated) { SpaceIconCatalog.load() }.value
        }
    }

    private var suggested: [SpaceIconCatalog.Entry] {
        showsEmoji ? Self.suggestedEmoji.map { SpaceIconCatalog.emoji($0) } : Space.icons.prefix(7).map { SpaceIconCatalog.icon($0) }
    }

    private func cell(_ entry: SpaceIconCatalog.Entry) -> some View {
        Button { icon = entry.id } label: {
            SpaceIcon(entry.id, size: 15)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(icon == entry.id ? Color.accentColor.opacity(0.22) : .primary.opacity(0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.label)
        .accessibilityLabel(entry.label)
    }
}

/// A space's icon: a bundled Phosphor icon, or an emoji. A name that isn't bundled shows the globe.
struct SpaceIcon: View {
    let icon: String
    let size: CGFloat

    init(_ icon: String, size: CGFloat) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        if Space.isEmoji(icon) {
            Text(icon)
                .font(.system(size: size))
                .fixedSize()
                .frame(width: size, height: size)
        } else {
            Image(nsImage: Phosphor.image(named: icon) ?? Phosphor.globe.image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}

/// Two-finger swipes across the sidebar switch spaces (`SpaceSwipe`). Watched only while there
/// are two spaces or more, and only in the sidebar's frame: the page keeps its own swipes.
struct SpaceSwipeArea: NSViewRepresentable {
    let isEnabled: Bool
    let step: (Int) -> Void

    func makeNSView(context: Context) -> SpaceSwipeView { SpaceSwipeView() }

    func updateNSView(_ view: SpaceSwipeView, context: Context) {
        view.step = step
        view.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: SpaceSwipeView, coordinator: ()) {
        view.isEnabled = false
    }
}

final class SpaceSwipeView: NSView {
    var step: (Int) -> Void = { _ in }
    var isEnabled = false {
        didSet { if isEnabled != oldValue { updateMonitor() } }
    }
    private var monitor: Any?
    private var swipe = SpaceSwipe()
    /// The gesture under way began over the sidebar: its later events count wherever they land.
    private var isTracking = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMonitor()
    }

    private func updateMonitor() {
        let wanted = isEnabled && window != nil
        if wanted, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.takes(event) == true } ? nil : event
            }
        } else if !wanted, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Whether the event is the swipe's, kept from the views under it.
    private func takes(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            isTracking = bounds.contains(convert(event.locationInWindow, from: nil))
            // A scroll elsewhere (the page) keeps all its events, momentum included.
            if !isTracking { swipe = SpaceSwipe() }
        }
        guard isTracking || !event.momentumPhase.isEmpty else { return false }
        switch swipe.handle(phase: event.phase, momentumPhase: event.momentumPhase, dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, inverted: event.isDirectionInvertedFromDevice) {
        case .pass: return false
        case .consume: return true
        case .step(let offset):
            step(offset)
            return true
        }
    }
}
