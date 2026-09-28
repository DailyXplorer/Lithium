import Foundation
import Testing
@testable import Lithium

struct RuleListTests {
    /// Element hiding for particular sites only needs the page's own document load. Network rules,
    /// hiding rules for every site and rules with a real address pattern stay as they were.
    @Test func siteElementHidingOnlyMatchesDocumentLoads() throws {
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*", "if-domain": ["*example.com"]], "action": ["type": "css-display-none", "selector": ".ad"]],
            ["trigger": ["url-filter": ".*", "unless-domain": ["*example.org"]], "action": ["type": "css-display-none", "selector": ".promo"]],
            ["trigger": ["url-filter": ".*", "if-frame-url": ["^https?://example\\.net/"]], "action": ["type": "css-display-none", "selector": ".frame"]],
            ["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": ".banner"]],
            ["trigger": ["url-filter": ".*", "if-domain": ["*example.com"]], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^https?://ads\\.", "if-domain": ["*example.com"]], "action": ["type": "css-display-none", "selector": ".x"]],
        ]
        let file = FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: rules).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let prepared = try #require(Privacy.prepared(file))
        let result = try #require(try JSONSerialization.jsonObject(with: Data(prepared.utf8)) as? [[String: Any]])
        let resourceTypes = result.map { ($0["trigger"] as? [String: Any])?["resource-type"] as? [String] }
        #expect(resourceTypes == [["document"], ["document"], ["document"], nil, nil, nil])
        #expect(result.map { ($0["action"] as? [String: Any])?["selector"] as? String } == [".ad", ".promo", ".frame", ".banner", nil, ".x"])
    }

    /// "#x ~ *" becomes three adjacent-sibling selectors, which WebKit matches without walking siblings.
    @Test func siblingSelectorsOnEveryElementAreRewritten() throws {
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": "#captchaBox, #cmdTextDisplay ~ *, #hero ~ .ad"]],
        ]
        let file = FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: rules).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let prepared = try #require(Privacy.prepared(file))
        let result = try #require(try JSONSerialization.jsonObject(with: Data(prepared.utf8)) as? [[String: Any]])
        #expect((result.first?["action"] as? [String: Any])?["selector"] as? String == "#captchaBox, #cmdTextDisplay + *, #cmdTextDisplay + * + *, #cmdTextDisplay + * + * + *, #hero ~ .ad")
    }
}
