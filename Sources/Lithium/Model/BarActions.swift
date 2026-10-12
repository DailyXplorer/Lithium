import Foundation
import SwiftUI
import WebKit

/// Browser commands the address bar offers once the typed words clearly name one (`matches`).
enum BarAction: Hashable, CaseIterable {
    case copyLink, newPrivateTab, duplicateTab, reopenClosedTab
    case pinTab, unpinTab, openSplitView, exitSplitView, enterZenMode, exitZenMode
    case translatePage, showOriginal, clearSiteData, turnOnEnergySaving, turnOffEnergySaving, settings

    var title: String {
        switch self {
        case .copyLink: "Copy link"
        case .newPrivateTab: "New private tab"
        case .duplicateTab: "Duplicate tab"
        case .reopenClosedTab: "Reopen closed tab"
        case .pinTab: "Pin tab"
        case .unpinTab: "Unpin tab"
        case .openSplitView: "Open in split view"
        case .exitSplitView: "Exit split view"
        case .enterZenMode: "Enter zen mode"
        case .exitZenMode: "Exit zen mode"
        case .translatePage: "Translate page"
        case .showOriginal: "Show original"
        case .clearSiteData: "Clear site data"
        case .turnOnEnergySaving: "Turn on energy saving"
        case .turnOffEnergySaving: "Turn off energy saving"
        case .settings: "Settings"
        }
    }

    private var aliases: [String] {
        switch self {
        case .copyLink: ["Copy URL", "Copy address"]
        case .newPrivateTab: ["Private window", "Incognito"]
        // Energy saving: none, so a search for "battery saver" stays a search on Return.
        case .duplicateTab, .turnOnEnergySaving, .turnOffEnergySaving: []
        case .reopenClosedTab: ["Undo close tab", "Restore tab"]
        case .pinTab: ["Add to favorites"]
        case .unpinTab: ["Remove from favorites"]
        case .openSplitView: ["Split view", "Side by side"]
        case .exitSplitView: ["Close split view"]
        case .enterZenMode, .exitZenMode: ["Zen", "Zen mode", "Focus mode"]
        case .translatePage: ["Translate"]
        case .showOriginal: ["Original page", "Stop translating"]
        case .clearSiteData: ["Clear cookies", "Delete cookies"]
        case .settings: ["Preferences"]
        }
    }

    /// Lower sorts first.
    struct Match: Comparable {
        /// Every word of a name typed out whole: Return runs it rather than the search.
        var isWhole: Bool
        var hasTypo: Bool
        var fromStart: Bool

        fileprivate var rank: Int { (isWhole ? 0 : 4) + (hasTypo ? 2 : 0) + (fromStart ? 0 : 1) }

        static func < (lhs: Match, rhs: Match) -> Bool { lhs.rank < rhs.rank }
    }

    static let shownLimit = 2

    /// Each typed word starts a word of the name, in order, with at most one typo in the query.
    /// Letter minimums keep everyday searches ("new", "pin", "rest", "data") from bringing actions up.
    static func matches(_ query: String, among available: [BarAction]) -> [(action: BarAction, match: Match)] {
        let typed = words(query)
        let letters = typed.joined().count
        guard letters >= 3 else { return [] }
        let found = available.compactMap { action -> (BarAction, Match)? in
            let best = ([action.title] + action.aliases).enumerated()
                .compactMap { match(typed, words($0.element), isTitle: $0.offset == 0) }
                .filter { letters >= 4 || $0.isWhole }.min()
            return best.map { (action, $0) }
        }
        return found.enumerated()
            .sorted { ($0.element.1.rank, $0.offset) < ($1.element.1.rank, $1.offset) }
            .prefix(shownLimit).map { (action: $0.element.0, match: $0.element.1) }
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func match(_ typed: [String], _ name: [String], isTitle: Bool) -> Match? {
        var next = 0
        var typos = 0
        var whole = typed.count == name.count
        var fromStart = false
        for (position, word) in typed.enumerated() {
            guard let (index, (typo, isWholeWord)) = (next..<name.count).lazy
                .compactMap({ index in wordMatch(word, name[index]).map { (index, $0) } }).first else { return nil }
            if position == 0 {
                fromStart = index == 0
                if !fromStart, word.count < 4 { return nil }
                // "rest" starts restaurant as much as Restore tab: under five letters, a lone word must be
                // the title's first word typed whole ("copy") or a whole one-word alias ("zen").
                if typed.count == 1, word.count < 5,
                   !(isWholeWord && fromStart && (isTitle || name.count == 1)) { return nil }
            }
            typos += typo ? 1 : 0
            whole = whole && isWholeWord
            next = index + 1
        }
        guard typos <= 1 else { return nil }
        return Match(isWhole: whole, hasTypo: typos > 0, fromStart: fromStart)
    }

    /// Whether `typed` starts `word`, or would with one letter wrong, missing, extra or swapped
    /// (five letters typed or more, first letter right).
    private static func wordMatch(_ typed: String, _ word: String) -> (typo: Bool, whole: Bool)? {
        if word.hasPrefix(typed) { return (false, typed.count == word.count) }
        guard typed.count >= 5, word.count >= max(4, typed.count - 1), typed.first == word.first else { return nil }
        // A start of the word plus one more letter starts another word ("resta", "opena", "copyr"),
        // not a typo: only a whole word typed just as long may end on one ("clera").
        if word.hasPrefix(typed.dropLast()), word.count != typed.count { return nil }
        let letters = Array(word)
        for length in max(1, typed.count - 1)...min(word.count, typed.count + 1)
        where editDistance(Array(typed), Array(letters[..<length])) <= 1 {
            return (true, length == word.count)
        }
        return nil
    }

    /// Optimal string alignment distance: a swap of two neighbours counts one.
    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in stride(from: 1, through: a.count, by: 1) {
            for j in stride(from: 1, through: b.count, by: 1) {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[a.count][b.count]
    }
}

extension Browser {
    /// Only what the menus would have enabled for `tab`; read as the user types, from state at hand.
    func barActions(for tab: Tab?) -> [BarAction] {
        var actions: [BarAction] = []
        let hasPage = tab?.url != nil
        if hasPage { actions.append(.copyLink) }
        actions.append(.newPrivateTab)
        if hasPage { actions.append(.duplicateTab) }
        if canReopenClosedTab { actions.append(.reopenClosedTab) }
        // As the menus: a private tab is never pinned.
        if let tab, hasPage, !tab.isEphemeral { actions.append(tab.pinID == nil ? .pinTab : .unpinTab) }
        if let tab, tab.isInTabList {
            if split(of: tab) != nil { actions.append(.exitSplitView) } else if splitPartner(for: tab) != nil { actions.append(.openSplitView) }
        }
        actions.append(isZenMode ? .exitZenMode : .enterZenMode)
        if let tab, tab.canTranslate { actions.append(tab.pageTranslation?.isActive == true ? .showOriginal : .translatePage) }
        if let scheme = tab?.url?.scheme?.lowercased(), ["http", "https"].contains(scheme) { actions.append(.clearSiteData) }
        actions.append(energy.isOn ? .turnOffEnergySaving : .turnOnEnergySaving)
        actions.append(.settings)
        return actions
    }

    func perform(_ action: BarAction, on tab: Tab?) {
        switch action {
        case .copyLink: copyLink(of: tab)
        case .newPrivateTab:
            newTab(privateStore: .nonPersistent())
            requestAddressFocus()
        case .duplicateTab: if let tab { duplicate(tab) }
        case .reopenClosedTab: reopenClosedTab()
        case .pinTab: if let tab { pin(tab) }
        case .unpinTab: if let favorite = pins.first(where: { $0.id == tab?.pinID }) { unpin(favorite) }
        case .openSplitView: if let tab { openInSplit(tab) }
        case .exitSplitView: if let tab { exitSplit(of: tab) }
        case .enterZenMode, .exitZenMode:
            guard isZenMode == (action == .exitZenMode) else { return }
            withAnimation(.snappy(duration: 0.2)) { toggleZenMode() }
        case .translatePage, .showOriginal: toggleTranslation(tab)
        case .clearSiteData: clearSiteData(of: tab)
        case .turnOnEnergySaving, .turnOffEnergySaving: turnEnergySaving(on: action == .turnOnEnergySaving)
        case .settings: openSettings()
        }
    }

    /// In the tab's own store (a private tab's stays its own), then a reload. Returned for tests to await.
    @discardableResult
    func clearSiteData(of tab: Tab?) -> Task<Void, Never>? {
        guard let tab, let url = tab.url else { return nil }
        let info = SiteInfo(url: url, store: tab.dataStore)
        return Task {
            await info.load()
            await info.clear()
            navigate(tab, .reload)
        }
    }
}
