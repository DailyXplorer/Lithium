import AppKit
import Foundation
import Testing
@testable import Lithium

/// Each test has its own choice and defaults: the shared one sets the font of every page other
/// tests load. Serialized: the tests share Theme's picked-font cache.
@MainActor
@Suite(.serialized)
struct FontChoiceTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "FontChoiceTests-\(UUID().uuidString)")!
    }

    /// DM Sans for both by default; websites follow the interface font until given their own.
    @Test func websitesFollowTheInterfaceFontUntilGivenTheirOwn() {
        let fonts = FontChoice(defaults: defaults())
        #expect(fonts.interface == nil)
        #expect(fonts.websiteFamily == "DM Sans")
        fonts.setInterface("Helvetica Neue")
        #expect(fonts.websiteFamily == "Helvetica Neue")
        fonts.setWebsite("Georgia")
        #expect(fonts.websiteFamily == "Georgia")
        fonts.setWebsite("")
        #expect(fonts.website == nil)
        #expect(fonts.websiteFamily == "Helvetica Neue")
        fonts.setInterface("DM Sans")
        #expect(fonts.interface == nil, "DM Sans is the default, not a choice")
    }

    @Test func choicesAreKept() {
        let store = defaults()
        let fonts = FontChoice(defaults: store)
        fonts.setInterface("Georgia")
        fonts.setWebsite("Helvetica Neue")
        let again = FontChoice(defaults: store)
        #expect(again.interface == "Georgia")
        #expect(again.website == "Helvetica Neue")
    }

    /// A font removed from the Mac after it was picked: DM Sans, not whatever the system substitutes.
    @Test func aMissingFontFallsBackToDMSans() {
        let fonts = FontChoice(defaults: defaults())
        fonts.setInterface("No Such Font 7F3A")
        #expect(fonts.websiteFamily == "DM Sans")
        #expect(Theme.pickedFont("No Such Font 7F3A", 13, .regular) == nil)
    }

    /// Every view asks on each redraw: a missing font is remembered, until fonts are installed or
    /// removed on the Mac, so one reinstalled while Lithium runs comes back without a relaunch.
    @Test func aMissingFontIsRememberedUntilTheFontsChange() async {
        #expect(Theme.pickedFont("No Such Font 9C2E", 13, .regular) == nil)
        #expect(Theme.pickedFonts.family == "No Such Font 9C2E")
        #expect(Theme.pickedFonts.fonts.count == 1, "the miss is remembered")
        let lookups = Theme.pickedFontLookups
        #expect(Theme.pickedFont("No Such Font 9C2E", 13, .regular) == nil)
        #expect(Theme.pickedFonts.fonts.count == 1)
        #expect(Theme.pickedFontLookups == lookups, "the miss comes from the cache")
        NotificationCenter.default.post(name: NSFont.fontSetChangedNotification, object: nil)
        let remembered = { Theme.pickedFonts.family == "No Such Font 9C2E" && !Theme.pickedFonts.fonts.isEmpty }
        let deadline = Date().addingTimeInterval(2)
        while remembered(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(!remembered(), "looked up again after the fonts change")
    }

    @Test func thePickedInterfaceFontKeepsSizeAndWeight() throws {
        let regular = try #require(Theme.pickedFont("Helvetica Neue", 13, .regular))
        let bold = try #require(Theme.pickedFont("Helvetica Neue", 13, .bold))
        #expect(regular.familyName == "Helvetica Neue")
        #expect(bold.familyName == "Helvetica Neue")
        #expect(regular.pointSize == 13)
        #expect(NSFontManager.shared.weight(of: bold) > NSFontManager.shared.weight(of: regular))
    }

    /// Every view asks on each redraw: each size and weight is built once.
    @Test func theInterfaceFontIsBuiltOncePerSizeAndWeight() throws {
        Theme.registerFonts()
        let regular = try #require(Theme.nsFont(13))
        #expect(Theme.nsFont(13) === regular)
        let semibold = try #require(Theme.nsFont(13, .semibold))
        #expect(Theme.nsFont(13, .semibold) === semibold)
        #expect(semibold !== regular)
        #expect(Theme.nsFont(15)?.pointSize == 15)
    }

    @Test func settingsListsTheMacsFamiliesAfterDMSans() {
        let families = FontChoice.families()
        #expect(families.first == "DM Sans")
        #expect(families.filter { $0 == "DM Sans" }.count == 1)
        #expect(families.contains("Helvetica Neue"))
        #expect(!families.contains { $0.hasPrefix(".") }, "the system's hidden families")
    }

    @Test func lithiumsPagesTakeTheInterfaceFont() {
        #expect(InternalSchemeHandler.interfaceFontCSS(nil).isEmpty)
        #expect(InternalSchemeHandler.interfaceFontCSS("Georgia").contains(#"font-family: "Georgia", "DM Sans""#))
    }
}
