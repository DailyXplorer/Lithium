import Testing
@testable import Lithium

/// The permission prompt can't be clickjacked: a page that makes it appear, or move, under a
/// pointer already clicking doesn't get that click on Allow.
struct PermissionPromptTests {
    @Test func clicksCountOnlyOnceThePromptStayedInPlace() {
        let shown = ContinuousClock.now
        var protection = ClickProtection(at: shown)
        #expect(!protection.accepts(at: shown))
        #expect(!protection.accepts(at: shown + .milliseconds(100)))
        #expect(protection.accepts(at: shown + ClickProtection.delay))

        // Moved under the pointer: armed again from there.
        let moved = shown + .seconds(2)
        protection.rearm(at: moved)
        #expect(!protection.accepts(at: moved + .milliseconds(499)))
        #expect(protection.accepts(at: moved + .milliseconds(500)))
    }
}
