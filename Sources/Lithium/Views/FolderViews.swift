import SwiftUI

struct FolderHeader: View {
    let folder: TabFolder
    /// Asks before a folder with tabs goes (`SidebarView`).
    let delete: () -> Void
    @Environment(Browser.self) private var browser
    @Environment(BrowserWindow.self) private var window
    @Environment(\.sidebarPalette) private var palette
    @State private var isTargeted = false

    var body: some View {
        let count = browser.tabList(in: folder.space, window: window.id, folder: folder.id).count
        SidebarRow(isSelected: false, action: toggle) {
            Icon(.folder, size: 14)
                .frame(width: 16)
            if window.renamingFolderID == folder.id {
                FolderNameField(folder: folder)
            } else {
                Text(folder.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if folder.isCollapsed, count > 0 {
                Text("\(count)")
                    .font(Theme.font(11).monospacedDigit())
                    .opacity(0.5)
            }
            Icon(folder.isCollapsed ? .forward : .caretDown, size: 10)
                .frame(width: 18, height: 18)
                .opacity(0.5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.ink.opacity(isTargeted ? 0.45 : 0), lineWidth: 2)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRenaming() })
        .dropDestination(for: SidebarDrag.self) { drags, _ in
            withAnimation(.snappy(duration: 0.2)) { window.dropTab(drags.map(\.item), on: .folder(folder.id, nil)) }
        } isTargeted: { isTargeted = $0 }
        .contextMenu {
            Button(folder.isCollapsed ? "Expand Folder" : "Collapse Folder", action: toggle)
            Button("Rename Folder…", action: startRenaming)
            Divider()
            Button(browser.folderHasTabs(folder.id) ? "Delete Folder…" : "Delete Folder", action: delete)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(folder.isCollapsed ? "Collapsed" : "Expanded")
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.2)) { browser.toggleFolder(folder.id) }
    }

    private func startRenaming() {
        window.renamingFolderID = folder.id
    }
}

/// Return or a click elsewhere keeps the name; Escape (`Browser.dismissOverlay`) leaves it as it was.
private struct FolderNameField: View {
    let folder: TabFolder
    @Environment(Browser.self) private var browser
    @Environment(BrowserWindow.self) private var window
    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Folder name", text: $name)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit { commit() }
            .onAppear {
                name = folder.name
                claimFocus($isFocused)
            }
            .onChange(of: isFocused) { _, focused in
                if !focused, window.renamingFolderID == folder.id { commit() }
            }
            // Gone with the sidebar (⌘B), the rename would otherwise hold Escape and the peek.
            .onDisappear {
                if window.renamingFolderID == folder.id, !window.showsSidebar { commit() }
            }
    }

    private func commit() {
        browser.renameFolder(folder.id, to: name)
        let hadKeyboard = isFocused
        DispatchQueue.main.async { [window] in window.returnKeyboardToPage(fieldHadKeyboard: hadKeyboard) }
    }
}

struct MoveToFolderMenu: View {
    let browser: Browser
    let tab: Tab
    var title = "Move to Folder"
    var showsShortcut = false

    var body: some View {
        Menu(title) {
            Button("New Folder") { withAnimation(.snappy(duration: 0.2)) { browser.newFolder(with: tab) } }
                .keyboardShortcut(showsShortcut ? KeyboardShortcut("n", modifiers: [.command, .option, .shift]) : nil)
            let others = browser.folders(in: tab.spaceID).filter { $0.id != tab.folderID }
            if !others.isEmpty { Divider() }
            ForEach(others) { folder in
                Button(folder.name) { withAnimation(.snappy(duration: 0.2)) { browser.moveTab(tab, toFolder: folder.id) } }
            }
            if tab.folderID != nil {
                Divider()
                Button("Remove from Folder") { withAnimation(.snappy(duration: 0.2)) { browser.moveTab(tab, toFolder: nil, at: 0) } }
            }
        }
    }
}
