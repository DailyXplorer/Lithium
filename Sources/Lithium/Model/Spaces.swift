import AppKit

/// A tab list of its own (Personal, Work), with its own favorites, color and icon. A space can keep
/// cookies, logins and site storage in a WebKit store of its own, with its own site permissions
/// (`Tab.siteSpace`); history, downloads and extensions stay shared, as WebKit's stores don't cover them.
/// Until a second space is made, `Browser.spaces` is empty and nothing is saved or watched for spaces.
struct Space: Codable, Identifiable, Equatable {
    typealias ID = UUID

    let id: ID
    var name: String
    /// The sidebar's color while the space is shown; nil follows Settings › Appearance.
    var color: String?
    /// A Phosphor icon's name (`SpaceIconCatalog`), or an emoji saved by an earlier version.
    var icon: String
    /// A `WKWebsiteDataStore(forIdentifier:)` of the space's id. Chosen when the space is made:
    /// data can't move between stores afterwards.
    var separatesData = false

    /// Keeps WebKit's default store and is never deleted. Saved tabs and favorites leave its id out.
    static let mainID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    static let main = Space(id: mainID, name: "Personal", color: nil, icon: Phosphor.globe.rawValue)

    /// Those of Settings › Appearance, so a space's sidebar looks like one the user could pick.
    static let colors = ["#D5DAF5", "#E6DDF6", "#F6DDE4", "#F7E7D4", "#DDEFE3", "#D8ECF3", "#E4E4E7", "#2B2D42"]
    /// New spaces' icons, in turn; the icon picker suggests the first ones.
    static let icons = ["globe-simple", "briefcase", "house", "code", "graduation-cap", "music-notes", "airplane-tilt", "game-controller", "wallet"]
    /// One per ⌃1…⌃9.
    static let limit = 9

    /// Phosphor names are ASCII; anything else is an emoji saved by an earlier version.
    static func isEmoji(_ icon: String) -> Bool {
        !icon.unicodeScalars.allSatisfy(\.isASCII)
    }

    /// Nil for the main space, so files written without spaces stay as they were.
    static func saved(_ id: ID) -> ID? { id == mainID ? nil : id }

    /// Separate spaces' per-site choices as saved in the defaults: by space id, then site.
    static func siteChoices(_ stored: [String: Any]?) -> [ID: [String: Bool]] {
        var choices: [ID: [String: Bool]] = [:]
        for (key, value) in stored ?? [:] {
            if let id = UUID(uuidString: key), let sites = value as? [String: Bool] { choices[id] = sites }
        }
        return choices
    }

    static func stored(_ choices: [ID: [String: Bool]]) -> [String: [String: Bool]] {
        Dictionary(uniqueKeysWithValues: choices.map { ($0.key.uuidString, $0.value) })
    }

    static func trimmedName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

/// A two-finger swipe across the sidebar moves one space over, once per gesture, momentum included.
/// A mouse wheel (no phase) and a mostly vertical scroll never switch.
struct SpaceSwipe {
    enum Outcome: Equatable {
        case pass
        /// Part of a swipe that switched: kept from the tab list, which would scroll along.
        case consume
        case step(Int)
    }

    static let distance: CGFloat = 40

    private var travel = CGSize.zero
    private var isTracking = false
    private var switched = false
    /// The last gesture switched: the momentum after it is kept from the tab list too.
    private var swallowsMomentum = false

    /// `inverted` is `NSEvent.isDirectionInvertedFromDevice`: the fingers' direction, not the
    /// content's, picks the space. Fingers to the left bring the next one.
    mutating func handle(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, dx: CGFloat, dy: CGFloat, inverted: Bool) -> Outcome {
        if !momentumPhase.isEmpty { return swallowsMomentum ? .consume : .pass }
        if phase.contains(.began) || phase.contains(.mayBegin) {
            travel = .zero
            isTracking = true
            switched = false
            swallowsMomentum = false
            return .pass
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            let ended = switched
            isTracking = false
            switched = false
            swallowsMomentum = ended
            return ended ? .consume : .pass
        }
        guard phase.contains(.changed), isTracking else { return .pass }
        if switched { return .consume }
        travel.width += dx
        travel.height += dy
        let (x, y) = (abs(travel.width), abs(travel.height))
        // A scroll of the tab list: this gesture switches nothing, however it bends later.
        if y > Self.distance / 2, y > x {
            isTracking = false
            return .pass
        }
        guard x >= Self.distance, x > 2 * y else { return .pass }
        switched = true
        let fingers = inverted ? travel.width : -travel.width
        return .step(fingers < 0 ? 1 : -1)
    }
}

extension Browser {
    var allSpaces: [Space] { spaces.isEmpty ? [.main] : spaces }
    /// More than one space: the sidebar shows the switcher and watches for swipes.
    var hasSpaces: Bool { spaces.count > 1 }
    var canAddSpace: Bool { allSpaces.count < Space.limit }

    func separatesData(_ id: Space.ID) -> Bool {
        id != Space.mainID && spaces.contains { $0.id == id && $0.separatesData }
    }

    func pins(in space: Space.ID) -> [Pin] {
        spaces.isEmpty ? pins : pins.filter { $0.space == space }
    }

    /// The space's tabs in `window`'s sidebar: its folders' first, then the tabs outside folders.
    func tabList(in space: Space.ID, window: BrowserWindow.ID) -> [Tab] {
        let spaceFolders = folders(in: space)
        guard !spaceFolders.isEmpty else { return tabs.filter { $0.isInTabList && $0.spaceID == space && $0.windowID == window } }
        return spaceFolders.flatMap { tabList(in: space, window: window, folder: $0.id) } + tabList(in: space, window: window, folder: nil)
    }

    /// With a nil folder, the tabs outside folders.
    func tabList(in space: Space.ID, window: BrowserWindow.ID, folder: TabFolder.ID?) -> [Tab] {
        tabs.filter { $0.isInTabList && $0.spaceID == space && $0.windowID == window && $0.folderID == folder }
    }

    func agentGroup(in space: Space.ID, window: BrowserWindow.ID) -> [Tab] {
        tabs.filter { $0.isInAgentGroup && $0.spaceID == space && $0.windowID == window }
    }

    /// The space's live favorites, its tab list and its Agent group, as the window's sidebar reads.
    func navigationOrder(in space: Space.ID, window: BrowserWindow.ID) -> [Tab] {
        pins(in: space).compactMap(liveTab(for:)).filter { $0.windowID == window } + tabList(in: space, window: window) + agentGroup(in: space, window: window)
    }

    func newSpaceDraft() -> Space {
        let all = allSpaces
        let colors = Set(all.compactMap(\.color))
        let icons = Set(all.map(\.icon))
        return Space(
            id: UUID(),
            name: "Space \(all.count + 1)",
            color: Space.colors.first { !colors.contains($0) } ?? Space.colors[0],
            icon: Space.icons.first { !icons.contains($0) } ?? Space.main.icon
        )
    }

}

extension BrowserWindow {
    var currentSpace: Space { browser.allSpaces.first { $0.id == currentSpaceID } ?? .main }
    var spacePins: [Pin] { browser.pins(in: currentSpaceID) }

    /// ⌃1…⌃9.
    func switchToSpace(at index: Int) {
        guard browser.hasSpaces, browser.spaces.indices.contains(index) else { return }
        switchToSpace(browser.spaces[index].id)
    }

    func switchSpace(by offset: Int) {
        guard browser.hasSpaces, let index = browser.spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        switchToSpace(at: min(max(index + offset, 0), browser.spaces.count - 1))
    }
}
