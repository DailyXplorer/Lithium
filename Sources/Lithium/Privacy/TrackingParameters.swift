import Foundation

enum TrackingParameters {
    private static let names: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id", "utm_name",
        "gclid", "dclid", "gbraid", "wbraid", "gclsrc", "fbclid", "msclkid", "yclid", "twclid",
        "ttclid", "igshid", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id",
        "oly_enc_id", "vero_id", "rb_clickid", "s_cid", "__s", "_openstat", "wickedid",
    ]

    /// Returns nil when there is nothing to strip. The raw query is cut on "&" and joined back:
    /// re-encoded, "%2B" would become "+" (a space), and query items Foundation rejects (a literal
    /// "==") would stop the app.
    static func stripped(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery, !query.isEmpty else { return nil }
        let items = query.split(separator: "&", omittingEmptySubsequences: false)
        let kept = items.filter { item in
            let name = String(item.prefix { $0 != "=" })
            return !names.contains((name.removingPercentEncoding ?? name).lowercased())
        }
        guard kept.count != items.count else { return nil }
        components.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        return components.url
    }
}
