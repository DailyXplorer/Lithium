import Foundation
import Testing
import WebKit
@testable import Lithium

/// Folders in the sidebar's tab list. A whole Browser keeps its data in the home folder, so this
/// suite only runs in a throwaway one: `scripts/test --filter TabFoldersTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct TabFoldersTests {
    /// Never made one: the rows are the tabs, and the session file says nothing of folders.
    @Test func withoutFoldersNothingChanges() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let a = browser.newTab(url: page("a"))
        let b = browser.newTab(url: page("b"))
        #expect(browser.folders.all.isEmpty)
        #expect(browser.commandWindow.tabListRows.map(\.id) == [b.id, a.id])
        #expect(browser.commandWindow.tabListEntries.map(\.index) == [0, 1])

        browser.saveNow()
        let session = try String(decoding: Data(contentsOf: SessionStore.fileURL), as: UTF8.self)
        #expect(session.range(of: "folder") == nil)
    }

    /// A new folder opens its name field; its tabs come first in the list, in the order Next Tab
    /// and ⌘1…⌘9 follow, and drags move tabs in, within and out of it.
    @Test func tabsMoveInWithinAndOutOfAFolder() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let a = browser.newTab(url: page("a"))
        let b = browser.newTab(url: page("b"))
        let c = browser.newTab(url: page("c"))
        #expect(browser.commandWindow.regularTabs.map(\.id) == [c.id, b.id, a.id])

        let folder = browser.newFolder(with: a)
        #expect(browser.commandWindow.renamingFolderID == folder.id)
        #expect(browser.commandWindow.isRenaming)
        browser.renameFolder(folder.id, to: "  Work ")
        #expect(browser.commandWindow.spaceFolders.map(\.name) == ["Work"])
        #expect(!browser.commandWindow.isRenaming)
        browser.commandWindow.renamingFolderID = folder.id
        browser.renameFolder(folder.id, to: "  ")
        #expect(browser.commandWindow.spaceFolders.map(\.name) == ["Work"], "an empty name keeps the one it had")

        #expect(a.folderID == folder.id)
        #expect(browser.commandWindow.regularTabs.map(\.id) == [a.id, c.id, b.id])
        #expect(browser.navigationOrder.map(\.id) == [a.id, c.id, b.id])
        #expect(browser.commandWindow.tabListRows.map(\.id) == [folder.id, a.id, c.id, b.id])
        #expect(browser.commandWindow.tabListEntries.map(\.index) == [0, 0, 1], "places count within the folder, then outside")

        // Dropped on the header: at the folder's end. On a row: before or after it.
        #expect(browser.commandWindow.dropTab([c.id.uuidString], on: .folder(folder.id, nil)))
        #expect(browser.tabList(in: Space.mainID, window: browser.commandWindow.id, folder: folder.id).map(\.id) == [a.id, c.id])
        #expect(browser.commandWindow.dropTab([b.id.uuidString], on: .folder(folder.id, 0)))
        #expect(browser.tabList(in: Space.mainID, window: browser.commandWindow.id, folder: folder.id).map(\.id) == [b.id, a.id, c.id])
        #expect(browser.commandWindow.dropTab([c.id.uuidString], on: .folder(folder.id, 1)))
        #expect(browser.tabList(in: Space.mainID, window: browser.commandWindow.id, folder: folder.id).map(\.id) == [b.id, c.id, a.id])
        #expect(browser.commandWindow.dropTab([b.id.uuidString], on: .folder(folder.id, 2)))
        #expect(browser.tabList(in: Space.mainID, window: browser.commandWindow.id, folder: folder.id).map(\.id) == [c.id, b.id, a.id])
        #expect(browser.commandWindow.dropTab([b.id.uuidString], on: .folder(folder.id, 2)))
        #expect(browser.tabList(in: Space.mainID, window: browser.commandWindow.id, folder: folder.id).map(\.id) == [c.id, b.id, a.id], "dropped on its own row, it stays")

        // Out again, on the tab list; a tab already outside folders stays where it is.
        #expect(browser.commandWindow.dropTab([a.id.uuidString], on: .tabList(0)))
        #expect(a.folderID == nil)
        #expect(browser.commandWindow.regularTabs.map(\.id) == [c.id, b.id, a.id])
        #expect(!browser.commandWindow.dropTab([a.id.uuidString], on: .tabList(1)))
        #expect(!browser.commandWindow.dropTab([a.id.uuidString], on: .folder(UUID(), nil)), "a folder no longer there")

        browser.commandWindow.selectItem(at: 0)
        #expect(browser.commandWindow.selectedTab === c)
        browser.commandWindow.selectAdjacentTab(1)
        #expect(browser.commandWindow.selectedTab === b)
    }

    /// Collapsed, a folder shows its header and the tab shown, if it is in it, and nothing else:
    /// ⌘1…⌘9 count the rows shown. Collapsing doesn't wake a sleeping tab.
    @Test func aCollapsedFolderShowsOnlyTheTabShown() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let loose = browser.newTab(url: page("loose"))
        let asleep = browser.newTab(url: page("asleep"))
        let shown = browser.newTab(url: page("shown"))
        let folder = browser.newFolder(with: asleep)
        browser.moveTab(shown, toFolder: folder.id)
        browser.select(loose)
        asleep.sleep(configuration: browser.makeConfiguration(for: asleep.url))
        #expect(asleep.isAsleep)

        browser.toggleFolder(folder.id)
        #expect(browser.commandWindow.spaceFolders.first?.isCollapsed == true)
        #expect(browser.commandWindow.tabListRows.map(\.id) == [folder.id, loose.id])
        #expect(asleep.isAsleep)
        browser.commandWindow.selectItem(at: 0)
        #expect(browser.commandWindow.selectedTab === loose, "the folder's hidden tabs have no number")

        browser.select(shown)
        #expect(browser.commandWindow.tabListRows.map(\.id) == [folder.id, shown.id, loose.id])
        #expect(asleep.isAsleep)

        browser.toggleFolder(folder.id)
        #expect(browser.commandWindow.tabListRows.map(\.id) == [folder.id, asleep.id, shown.id, loose.id])
        #expect(asleep.isAsleep, "expanding doesn't wake it either")
    }

    /// An agent's tab moved into a folder becomes the user's; a split pair moves as one row, and
    /// a tab opened in split view beside a folder's tab joins its folder.
    @Test func agentTabsAndSplitPairsMoveWhole() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let a = browser.newTab(url: page("a"))
        let b = browser.newTab(url: page("b"))
        let c = browser.newTab(url: page("c"))
        let folder = browser.newFolder()
        browser.renameFolder(folder.id, to: "Work")

        let agents = browser.newAgentTab(session: "s1")
        #expect(browser.commandWindow.dropTab([agents.id.uuidString], on: .folder(folder.id, nil)))
        #expect(agents.openedByAgent == nil)
        #expect(agents.folderID == folder.id)
        #expect(browser.commandWindow.agentTabs.isEmpty)
        #expect(!browser.commandWindow.dropTab([b.id.uuidString], on: .agentGroup))

        browser.select(a)
        browser.openInSplit(b)
        #expect(browser.split(of: a)?.contains(b.id) == true)
        browser.moveTab(a, toFolder: folder.id)
        #expect(a.folderID == folder.id)
        #expect(b.folderID == folder.id)
        let rows = browser.commandWindow.tabListRows.compactMap(\.entry).filter { $0.tab.folderID == folder.id }
        #expect(rows.map(\.tab.id) == [agents.id, a.id], "the agent's tab, and the pair as one row")
        #expect(rows.last?.split?.partner(of: a.id) == b.id)

        browser.select(agents)
        browser.openInSplit(c)
        #expect(c.folderID == folder.id)
    }

    /// A pair's sidebar row drags as its first side, like a tab's row: dropped on a folder and back
    /// on the tab list, both sides go and stay one row.
    @Test func aSplitRowDragsIntoAndOutOfAFolder() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let a = browser.newTab(url: page("a"))
        let b = browser.newTab(url: page("b"))
        browser.newTab(url: page("c"))
        let folder = browser.newFolder()
        browser.select(a)
        browser.openInSplit(b)
        let split = try #require(browser.split(of: a))
        let first = try #require(browser.tabs.first { $0.id == split.first })

        #expect(browser.commandWindow.dropTab([browser.startDragging(first)], on: .folder(folder.id, nil)))
        #expect(browser.splits.draggedTabID == nil)
        #expect(a.folderID == folder.id && b.folderID == folder.id)
        let rows = browser.commandWindow.tabListRows.compactMap(\.entry).filter { $0.tab.folderID == folder.id }
        #expect(rows.count == 1 && rows.first?.split == browser.split(of: a), "the pair as one row")

        #expect(browser.commandWindow.dropTab([browser.startDragging(first)], on: .tabList(0)))
        #expect(a.folderID == nil && b.folderID == nil)
        #expect(browser.split(of: a)?.contains(b.id) == true)
    }

    /// The folders, their names, collapsed state and tabs come back after a relaunch, the tabs
    /// asleep. A private tab is never saved, and a tab pinned leaves its folder.
    @Test func foldersComeBackAfterRelaunch() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let a = browser.newTab(url: page("a"))
        let b = browser.newTab(url: page("b"))
        let pinned = browser.newTab(url: page("pinned"))
        let secret = browser.newTab(url: page("secret"), privateStore: .nonPersistent())
        let work = browser.newFolder(with: a)
        browser.renameFolder(work.id, to: "Work")
        for tab in [b, pinned, secret] { browser.moveTab(tab, toFolder: work.id) }
        browser.toggleFolder(work.id)
        let later = browser.newFolder()
        browser.renameFolder(later.id, to: "Later")
        browser.pin(pinned)
        #expect(pinned.folderID == nil)
        #expect(browser.tabList(in: Space.mainID, window: browser.commandWindow.id, folder: work.id).map(\.id) == [a.id, b.id, secret.id])
        browser.select(pinned)
        browser.saveNow()

        let again = Browser()
        defer { reset(again) }
        #expect(again.commandWindow.spaceFolders.map(\.name) == ["Work", "Later"])
        #expect(again.commandWindow.spaceFolders.map(\.isCollapsed) == [true, false])
        let restored = again.tabList(in: Space.mainID, window: again.commandWindow.id, folder: work.id)
        #expect(restored.map(\.url) == [page("a"), page("b")])
        #expect(restored.map(\.isAsleep) == [true, true])
        let pin = try #require(again.pins.first)
        #expect(again.liveTab(for: pin)?.folderID == nil)
    }

    /// Deleting a folder keeps its tabs at the top of the list, where it was, or closes them:
    /// the selection leaves the folder first, and Reopen Closed Tab brings them back.
    @Test func deletingAFolderKeepsOrClosesItsTabs() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let a = browser.newTab(url: page("a"))
        let b = browser.newTab(url: page("b"))
        let c = browser.newTab(url: page("c"))
        let kept = browser.newFolder(with: a)
        browser.moveTab(c, toFolder: kept.id)
        browser.select(b)
        browser.deleteFolder(kept.id, closingTabs: false)
        #expect(browser.folders.all.isEmpty)
        #expect(browser.commandWindow.regularTabs.map(\.id) == [a.id, c.id, b.id])
        #expect([a, b, c].map(\.folderID) == [nil, nil, nil])
        #expect(browser.commandWindow.selectedTab === b)

        let closed = browser.newFolder(with: a)
        browser.moveTab(c, toFolder: closed.id)
        browser.select(a)
        browser.deleteFolder(closed.id, closingTabs: true)
        #expect(browser.folders.all.isEmpty)
        #expect(browser.commandWindow.regularTabs.map(\.id) == [b.id])
        #expect(browser.commandWindow.selectedTab === b)
        browser.reopenClosedTab()
        #expect(browser.commandWindow.selectedTab?.url == page("c"))
        #expect(browser.commandWindow.selectedTab?.folderID == nil)
        #expect(browser.commandWindow.regularTabs.first === browser.commandWindow.selectedTab)
        // The rest come back above, in the folder's order.
        browser.reopenClosedTab()
        #expect(browser.commandWindow.regularTabs.map(\.url) == [page("a"), page("c"), page("b")])
    }

    /// A closed tab reopens in its folder, in its place; a copy stays in the folder, just below.
    @Test func reopenedAndDuplicatedTabsStayInTheirFolder() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let a = browser.newTab(url: page("a"))
        let b = browser.newTab(url: page("b"))
        let folder = browser.newFolder(with: a)
        browser.moveTab(b, toFolder: folder.id)
        browser.close(a)
        browser.reopenClosedTab()
        let reopened = try #require(browser.commandWindow.selectedTab)
        #expect(browser.tabList(in: Space.mainID, window: browser.commandWindow.id, folder: folder.id).map(\.id) == [reopened.id, b.id])

        browser.duplicate(reopened)
        let copy = try #require(browser.commandWindow.selectedTab)
        #expect(browser.tabList(in: Space.mainID, window: browser.commandWindow.id, folder: folder.id).map(\.id) == [reopened.id, copy.id, b.id])
    }

    /// Each space has its own folders; a tab only goes into one of its space's, and a deleted
    /// space's folders go with it.
    @Test func foldersBelongToTheirSpace() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let home = browser.newFolder()
        var work = browser.newSpaceDraft()
        work.name = "Work"
        browser.addSpace(work)
        #expect(browser.commandWindow.spaceFolders.isEmpty)
        let report = browser.newTab(url: page("report"))
        browser.moveTab(report, toFolder: home.id)
        #expect(report.folderID == nil)
        let projects = browser.newFolder(with: report)
        #expect(projects.space == work.id)
        #expect(browser.commandWindow.spaceFolders.map(\.id) == [projects.id])

        browser.deleteSpace(work.id)
        #expect(browser.folders.all.map(\.id) == [home.id])
    }

    /// A folder's name being typed holds the peeked sidebar, and Escape ends it, the name as it was.
    @Test func escapeEndsAFolderRename() throws {
        let browser = makeBrowser()
        defer { reset(browser) }
        let folder = browser.newFolder()
        #expect(browser.commandWindow.holdsPeek)
        #expect(browser.dismissOverlay())
        #expect(!browser.commandWindow.isRenaming)
        #expect(!browser.commandWindow.holdsPeek)
        #expect(browser.commandWindow.spaceFolders.map(\.name) == [folder.name])
    }

    private func makeBrowser() -> Browser {
        SessionStore.save(Session())
        PinStore.save([])
        return Browser()
    }

    /// Closes everything, so the next test's browser starts empty.
    private func reset(_ browser: Browser) {
        browser.tabs.forEach { browser.close($0, remembering: false) }
        browser.pins.forEach(browser.unpin)
        for space in browser.spaces.reversed() { browser.deleteSpace(space.id) }
        for folder in browser.folders.all { browser.removeFolder(folder.id) }
        SessionStore.save(Session())
    }

    private func page(_ name: String) -> URL { URL(string: "data:text/html,\(name)")! }
}
