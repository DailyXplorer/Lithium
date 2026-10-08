import AppKit

/// A tab list of its own (Personal, Work), with its own favorites, color and icon, Arc-like. The
/// sidebar shows one space at a time. A space can keep its cookies, logins and site storage apart
/// in a WebKit store of its own, so a site can be signed in with another account there. History,
/// downloads, site settings and extensions stay shared, as WebKit's stores don't cover them.
///
/// Until a second space is made, `Browser.spaces` is empty and every tab and favorite is in the
/// main space: nothing is saved, observed or watched for spaces.
struct Space: Codable, Identifiable, Equatable {
    typealias ID = UUID

    let id: ID
    var name: String
    /// The sidebar's color while the space is shown; nil follows Settings › Appearance.
    var color: String?
    /// A bundled Phosphor icon's name (`SpaceIconCatalog`) or an emoji.
    var icon: String
    /// Cookies, logins and site storage of its own (`WKWebsiteDataStore(forIdentifier:)`, the
    /// space's id). Chosen when the space is made: data can't move between stores afterwards.
    var separatesData = false

    /// The space every tab and favorite is in until the user makes another. It keeps WebKit's
    /// default store, and is never deleted. Saved tabs and favorites leave its id out.
    static let mainID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    static let main = Space(id: mainID, name: "Personal", color: nil, icon: Phosphor.globe.rawValue)

    /// Those of Settings › Appearance, so a space's sidebar looks like one the user could pick.
    static let colors = ["#D5DAF5", "#E6DDF6", "#F6DDE4", "#F7E7D4", "#DDEFE3", "#D8ECF3", "#E4E4E7", "#2B2D42"]
    /// New spaces' icons, in turn; the icon picker suggests the first ones.
    static let icons = ["globe-simple", "briefcase", "house", "code", "graduation-cap", "music-notes", "airplane-tilt", "game-controller", "wallet"]
    /// One per ⌃1…⌃9.
    static let limit = 9

    /// Phosphor names are ASCII; anything else is an emoji.
    static func isEmoji(_ icon: String) -> Bool {
        !icon.unicodeScalars.allSatisfy(\.isASCII)
    }

    /// What a saved tab or favorite records: nothing for the main space, so files written
    /// without spaces stay as they were.
    static func saved(_ id: ID) -> ID? { id == mainID ? nil : id }

    static func trimmedName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

/// A two-finger swipe across the sidebar moves one space over, once per gesture: the fingers
/// lifting and the momentum after them change nothing more. A mouse wheel (no phase) and a mostly
/// vertical scroll (the tab list's own) never switch.
struct SpaceSwipe {
    enum Outcome: Equatable {
        /// Not a space swipe: the event goes on to the sidebar.
        case pass
        /// Part of a swipe that switched: kept from the tab list, which would scroll along.
        case consume
        /// Switch by this many spaces: 1 to the next, -1 to the previous.
        case step(Int)
    }

    /// Horizontal travel, in points, that makes a swipe.
    static let distance: CGFloat = 40

    private var travel = CGSize.zero
    private var isTracking = false
    private var switched = false
    /// The last gesture switched: the momentum after it is kept from the tab list too.
    private var swallowsMomentum = false

    /// `inverted` is `NSEvent.isDirectionInvertedFromDevice` (natural scrolling): the fingers'
    /// direction, not the content's, picks the space. Fingers to the left bring the next one.
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
    /// Every space, the main one first; just the main one until the user makes another.
    var allSpaces: [Space] { spaces.isEmpty ? [.main] : spaces }
    var currentSpace: Space { allSpaces.first { $0.id == currentSpaceID } ?? .main }
    /// More than one space: the sidebar shows the switcher and watches for swipes.
    var hasSpaces: Bool { spaces.count > 1 }
    var canAddSpace: Bool { allSpaces.count < Space.limit }

    /// The favorites of the space shown, in grid order.
    var spacePins: [Pin] { pins(in: currentSpaceID) }

    func pins(in space: Space.ID) -> [Pin] {
        spaces.isEmpty ? pins : pins.filter { $0.space == space }
    }

    /// A space's tab list, in order: each folder's tabs, then those outside folders (`TabFolder`).
    func tabList(in space: Space.ID) -> [Tab] {
        let spaceFolders = folders(in: space)
        guard !spaceFolders.isEmpty else { return tabs.filter { $0.isInTabList && $0.spaceID == space } }
        return spaceFolders.flatMap { tabList(in: space, folder: $0.id) } + tabList(in: space, folder: nil)
    }

    /// The tabs of a folder, or with nil those outside folders, in order.
    func tabList(in space: Space.ID, folder: TabFolder.ID?) -> [Tab] {
        tabs.filter { $0.isInTabList && $0.spaceID == space && $0.folderID == folder }
    }

    func agentGroup(in space: Space.ID) -> [Tab] {
        tabs.filter { $0.isInAgentGroup && $0.spaceID == space }
    }

    /// The space's live favorites, its tab list and its Agent group, as its sidebar reads.
    func navigationOrder(in space: Space.ID) -> [Tab] {
        pins(in: space).compactMap(liveTab(for:)) + tabList(in: space) + agentGroup(in: space)
    }

    /// A draft for the space editor: the next color and icon no space has yet.
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

    /// ⌃1…⌃9.
    func switchToSpace(at index: Int) {
        guard hasSpaces, spaces.indices.contains(index) else { return }
        switchToSpace(spaces[index].id)
    }

    /// A swipe: the next or previous space, stopping at either end.
    func switchSpace(by offset: Int) {
        guard hasSpaces, let index = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        switchToSpace(at: min(max(index + offset, 0), spaces.count - 1))
    }
}
