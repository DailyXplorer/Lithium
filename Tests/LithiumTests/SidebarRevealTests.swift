import Testing
@testable import Lithium

struct SidebarRevealTests {
    /// Settings round-trips the preset through its raw value, and the three show in this order.
    @Test func presetsAreStoredByName() {
        #expect(SidebarReveal.allCases.map(\.rawValue) == ["responsive", "normal", "calm"])
        #expect(SidebarReveal.allCases.map(\.label) == ["Responsive", "Normal", "Calm"])
        #expect(SidebarReveal(rawValue: "calm") == .calm)
    }

    /// Each preset waits longer and forgives more than the one before it.
    @Test func presetTimingsAndMargins() {
        #expect(SidebarReveal.allCases.map(\.openDelay) == [.milliseconds(50), .milliseconds(150), .milliseconds(300)])
        #expect(SidebarReveal.allCases.map(\.closeDelay) == [.milliseconds(300), .milliseconds(600), .milliseconds(1200)])
        #expect(SidebarReveal.allCases.map(\.margin) == [24, 48, 80])
    }
}
