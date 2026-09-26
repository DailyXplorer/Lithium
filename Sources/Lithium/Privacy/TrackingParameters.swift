import Foundation

enum TrackingParameters {
    private static let names: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id", "utm_name",
        "gclid", "dclid", "gbraid", "wbraid", "gclsrc", "fbclid", "msclkid", "yclid", "twclid",
        "ttclid", "igshid", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id",
        "oly_enc_id", "vero_id", "rb_clickid", "s_cid", "__s", "_openstat", "wickedid",
    ]

    /// Returns the URL without known tracking parameters, or nil when there is nothing to strip.
    /// The other parameters keep their exact encoding: decoded and encoded again, "%2B" would
    /// come back as "+", which servers read as a space.
    static func stripped(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems, !items.isEmpty else { return nil }
        let kept = items.filter { !names.contains(($0.name.removingPercentEncoding ?? $0.name).lowercased()) }
        guard kept.count != items.count else { return nil }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url
    }
}
