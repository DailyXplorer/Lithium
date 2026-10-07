import Foundation
import Testing
import WebKit
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

    /// A group whose new list fails to compile keeps blocking with its previous list, isn't
    /// counted, and leaves the set incomplete so it is tried again.
    @MainActor
    @Test func aGroupThatFailsToCompileKeepsItsPreviousList() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rule-lists-\(UUID())")
        try FileManager.default.createDirectory(at: root.appending(path: "store"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let created: WKContentRuleListStore? = WKContentRuleListStore(url: root.appending(path: "store"))
        let store = try #require(created)

        func filters(updated: String, ads: String) throws -> (folder: URL, manifest: Manifest) {
            let folder = root.appending(path: updated.filter(\.isNumber))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ads.write(to: folder.appending(path: "ads.json"), atomically: true, encoding: .utf8)
            try #"[{"trigger":{"url-filter":"cookie-banner"},"action":{"type":"block"}}]"#
                .write(to: folder.appending(path: "cookies.json"), atomically: true, encoding: .utf8)
            let groups = ["ads": Manifest.Group(webkitRules: 10), "cookies": Manifest.Group(webkitRules: 5)]
            return (folder, Manifest(updated: updated, groups: groups, advancedRules: nil))
        }

        let first = try filters(updated: "2026-10-01T00:00:00Z", ads: #"[{"trigger":{"url-filter":"ad-banner"},"action":{"type":"block"}}]"#)
        let loaded = await Privacy.loadGroups(from: first.folder, manifest: first.manifest, into: store)
        #expect(loaded.lists.count == 2 && loaded.ruleCount == 15 && loaded.complete)

        // A trigger without a url-filter: WebKit refuses the whole list.
        let second = try filters(updated: "2026-10-02T00:00:00Z", ads: #"[{"trigger":{},"action":{"type":"block"}}]"#)
        let reloaded = await Privacy.loadGroups(from: second.folder, manifest: second.manifest, into: store)
        let identifiers = reloaded.lists.compactMap(\.identifier)
        #expect(identifiers.count == 2)
        #expect(identifiers.first?.hasPrefix("lithium-ads-20261001") == true)
        #expect(identifiers.last?.hasPrefix("lithium-cookies-20261002") == true)
        #expect(reloaded.ruleCount == 5 && !reloaded.complete)
        #expect((await store.availableIdentifiers() ?? []).sorted() == identifiers.sorted())
    }
}
