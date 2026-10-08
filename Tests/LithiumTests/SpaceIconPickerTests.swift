import AppKit
import SwiftUI
import Testing
@testable import Lithium

/// The space icon picker's icons: nothing built until the picker opens, quick to build
/// and to search on every keystroke, and every listed icon bundled.
@MainActor
@Suite(.serialized)
struct SpaceIconPickerTests {
    /// The sidebar's space icons build no catalog; a picker's goes when the picker does.
    @Test func nothingIsBuiltBeforeThePickerOpens() {
        #expect(SpaceIconCatalog.live == 0)
        let sidebarIcons = NSHostingView(rootView: HStack { SpaceIcon("briefcase", size: 14); SpaceIcon("🎮", size: 14) })
        _ = sidebarIcons.fittingSize
        #expect(SpaceIconCatalog.live == 0)

        do {
            let catalog = SpaceIconCatalog.load()
            withExtendedLifetime(catalog) {
                #expect(SpaceIconCatalog.live == 1)
            }
        }
        #expect(SpaceIconCatalog.live == 0)
    }

    /// Generous bounds, so only a real regression fails: built once per opening, searched per keystroke.
    @Test func buildingAndSearchingAreQuick() {
        let clock = ContinuousClock()
        var catalog: SpaceIconCatalog?
        let build = clock.measure { catalog = SpaceIconCatalog.load() }
        #expect(build < .milliseconds(50), "built in \(build)")
        let icons = catalog?.icons ?? []
        for query in ["work", "home", "money", "music", "code", "travel", "school", "game", "smiling face", "x"] {
            let search = clock.measure { _ = SpaceIconCatalog.search(query, in: icons) }
            #expect(search < .milliseconds(5), "“\(query)” in \(search)")
        }
    }

    @Test func searchesIconsByNameAndKeyword() {
        let catalog = SpaceIconCatalog.load()
        func icons(_ query: String) -> [String] { SpaceIconCatalog.search(query, in: catalog.icons).map(\.id) }
        let expected = [("work", "briefcase"), ("home", "house"), ("money", "wallet"), ("music", "music-notes"), ("code", "code"), ("travel", "airplane"), ("school", "graduation-cap"), ("game", "game-controller")]
        for (query, icon) in expected {
            #expect(icons(query).contains(icon), "“\(query)”")
        }
        #expect(icons("Graduation  CAP") == ["graduation-cap"], "every term, any case")
        #expect(icons("").count == catalog.icons.count)
        #expect(icons("zzz").isEmpty)
        #expect(icons("ear").isEmpty, "a term matches the start of a word, not inside one (heart, learning)")
    }

    /// Every listed icon has its SVG (scripts/update-space-icons.py), and the suggestions are listed.
    @Test func everyListedIconIsBundled() {
        let catalog = SpaceIconCatalog.load()
        let names = catalog.icons.map(\.id)
        #expect(names.count >= 250)
        #expect(Set(names).count == names.count)
        let missing = names.filter { Resources.bundle.url(forResource: $0, withExtension: "svg") == nil }
        #expect(missing.isEmpty, "not bundled: \(missing.joined(separator: ", "))")
        #expect(Space.icons.allSatisfy(names.contains))
        #expect(!names.contains(where: Space.isEmoji), "icons only, no emoji")
    }

    /// The grid shows each icon once: an id in both the suggested row and the full list drew an
    /// empty cell. Together the two sections still hold every icon.
    @Test func gridIdentitiesAreUnique() {
        let catalog = SpaceIconCatalog.load()
        let sections = SpaceIconPicker.sections(of: catalog.icons)
        let ids = (sections.suggested + sections.rest).map(\.id)
        #expect(sections.suggested.map(\.id) == Array(Space.icons.prefix(7)))
        #expect(Set(ids).count == ids.count, "duplicates: \(Dictionary(grouping: ids) { $0 }.filter { $1.count > 1 }.keys.sorted())")
        #expect(Set(ids) == Set(catalog.icons.map(\.id)))
    }

    /// A space keeps an icon's name, or an emoji saved by an earlier version, which still draws;
    /// a name that isn't bundled draws the globe.
    @Test func spaceIconsAreNamesOrSavedEmoji() {
        #expect(!Space.isEmoji("graduation-cap"))
        #expect(Space.isEmoji("🎓"))
        #expect(Space.isEmoji("\u{2708}\u{FE0F}"))
        let image = Phosphor.image(named: "code")
        #expect(image === Phosphor.code.image)
        #expect(image?.isTemplate == true)
        #expect(Phosphor.image(named: "no-such-icon") == nil)
    }
}
