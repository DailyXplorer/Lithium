import Foundation
import Observation

/// A named group of tabs in the sidebar. Folders sit above the tabs outside folders, and the tab
/// list reads in that order everywhere (Next Tab, ⌘1…⌘9, Close Tabs Below).
/// Until the user makes one, nothing is sorted, saved or watched for folders.
struct TabFolder: Codable, Identifiable, Equatable {
    typealias ID = UUID

    let id: ID
    var name: String
    var isCollapsed = false
    /// The space whose tab list shows it; nil for the main space (`Space.saved`).
    var spaceID: Space.ID? = nil

    var space: Space.ID { spaceID ?? Space.mainID }

    static let defaultName = "New folder"
}

@MainActor
@Observable
final class TabFolders {
    fileprivate(set) var all: [TabFolder] = []
}

/// A folder's header, or a tab (alone or leading its split pair).
enum TabListRow: Identifiable {
    case folder(TabFolder)
    case tab(TabListEntry)

    var id: UUID {
        switch self {
        case .folder(let folder): folder.id
        case .tab(let entry): entry.id
        }
    }

    var entry: TabListEntry? {
        if case .tab(let entry) = self { entry } else { nil }
    }
}

extension Browser {
    func folders(in space: Space.ID) -> [TabFolder] {
        folders.all.isEmpty ? [] : folders.all.filter { $0.space == space }
    }

    /// Made in `tab`'s space when given, with `tab` in it, else in the space `window` shows; its
    /// name field open there.
    @discardableResult
    func newFolder(with tab: Tab? = nil, in window: BrowserWindow? = nil) -> TabFolder {
        let window = tab.map(self.window(of:)) ?? window ?? commandWindow
        let folder = TabFolder(id: UUID(), name: TabFolder.defaultName, spaceID: Space.saved(tab?.spaceID ?? window.currentSpaceID))
        folders.all.append(folder)
        if let tab { moveTab(tab, toFolder: folder.id) }
        window.renamingFolderID = folder.id
        return folder
    }

    func renameFolder(_ id: TabFolder.ID, to name: String) {
        if let index = folders.all.firstIndex(where: { $0.id == id }) {
            let trimmed = Space.trimmedName(name, fallback: folders.all[index].name)
            if trimmed != folders.all[index].name { folders.all[index].name = trimmed }
        }
        endRenamingFolder(id)
    }

    private func endRenamingFolder(_ id: TabFolder.ID) {
        for window in windows where window.renamingFolderID == id { window.renamingFolderID = nil }
    }

    /// Collapsing leaves its tabs as they are: a sleeping one stays asleep, a playing one plays.
    func toggleFolder(_ id: TabFolder.ID) {
        guard let index = folders.all.firstIndex(where: { $0.id == id }) else { return }
        folders.all[index].isCollapsed.toggle()
    }

    /// Takes the folder out of the list; its tabs must be out of it already (`deleteFolder`).
    func removeFolder(_ id: TabFolder.ID) {
        folders.all.removeAll { $0.id == id }
        endRenamingFolder(id)
    }

    func removeFolders(in space: Space.ID) {
        guard !folders.all.isEmpty else { return }
        folders.all.removeAll { $0.space == space }
    }

    /// In any window: every window of the space shows the folder, and deleting it takes it from all.
    func folderHasTabs(_ id: TabFolder.ID) -> Bool {
        tabs.contains { $0.folderID == id && $0.isInTabList }
    }

    func folderExists(_ id: TabFolder.ID, in space: Space.ID) -> Bool {
        folders.all.contains { $0.id == id && $0.space == space }
    }

    var savedFolders: [TabFolder]? { folders.all.isEmpty ? nil : folders.all }

    /// Before the tabs, which name their folder. A folder of a missing space goes to the main one.
    func restoreFolders(_ saved: [TabFolder]?) {
        guard let saved, !saved.isEmpty else { return }
        let known = Set(allSpaces.map(\.id))
        folders.all = saved.map { folder in
            var folder = folder
            if !known.contains(folder.space) { folder.spaceID = nil }
            return folder
        }
    }
}

extension BrowserWindow {
    var spaceFolders: [TabFolder] { browser.folders(in: currentSpaceID) }

    /// A collapsed folder still shows the selected tab (and its split), as Arc does.
    var tabListRows: [TabListRow] {
        let entries = tabListEntries
        let shown = spaceFolders
        guard !shown.isEmpty else { return entries.map(TabListRow.tab) }
        let selected = selectedTabID
        var rows: [TabListRow] = []
        for folder in shown {
            rows.append(.folder(folder))
            rows += entries.filter { entry in
                guard entry.tab.folderID == folder.id else { return false }
                return !folder.isCollapsed || selected.map { entry.tab.id == $0 || entry.split?.contains($0) == true } == true
            }.map(TabListRow.tab)
        }
        return rows + entries.filter { $0.tab.folderID == nil }.map(TabListRow.tab)
    }
}
