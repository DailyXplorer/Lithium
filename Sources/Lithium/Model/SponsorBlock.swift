import CryptoKit
import Foundation
import WebKit

/// SponsorBlock: sponsors, intros and other segments of YouTube videos, timed by its community
/// (sponsor.ajay.app), skipped as the video plays. The script runs in its own content world,
/// where YouTube's code can neither see it nor reach the app through it. Segments are fetched
/// here, by the first 4 characters of the video's SHA-256, so the server never learns which
/// video is playing.
@MainActor
final class SponsorBlock: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "sponsorBlock"
    static let world = WKContentWorld.world(name: "SponsorBlock")
    static let api = URL(string: "https://sponsor.ajay.app/api/skipSegments/")!

    static let script: WKUserScript = {
        let source = Resources.bundle.url(forResource: "sponsorblock", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }()

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    private(set) var actions: [SegmentCategory: SegmentAction]

    private let fetch: @Sendable (URL) async throws -> (Data, URLResponse)

    private static let enabledKey = "sponsorBlockEnabled"
    private static let actionsKey = "sponsorBlockActions"

    init(fetch: @escaping @Sendable (URL) async throws -> (Data, URLResponse) = SponsorBlock.download) {
        self.fetch = fetch
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        let stored = UserDefaults.standard.dictionary(forKey: Self.actionsKey) as? [String: String] ?? [:]
        actions = Dictionary(uniqueKeysWithValues: SegmentCategory.allCases.map { category in
            (category, stored[category.rawValue].flatMap(SegmentAction.init(rawValue:)) ?? category.defaultAction)
        })
        super.init()
    }

    func setAction(_ action: SegmentAction, for category: SegmentCategory) {
        actions[category] = action
        let stored = Dictionary(uniqueKeysWithValues: actions.map { ($0.key.rawValue, $0.value.rawValue) })
        UserDefaults.standard.set(stored, forKey: Self.actionsKey)
    }

    /// Registers the script's line to the app; `configuration` has a fresh content controller.
    func install(on configuration: WKWebViewConfiguration) {
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: Self.world, name: Self.name)
    }

    func script(for url: URL) -> WKUserScript? {
        isEnabled && Self.handles(url) ? Self.script : nil
    }

    static func handles(_ url: URL?) -> Bool {
        isYouTube(scheme: url?.scheme, host: url?.host())
    }

    private static func isYouTube(scheme: String?, host: String?) -> Bool {
        guard scheme == "https", let host = host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    static func isVideoID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }

    static func hashPrefix(_ videoID: String) -> String {
        SHA256.hash(data: Data(videoID.utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    static func request(for videoID: String, categories: [SegmentCategory]) -> URL {
        let list = { (values: [String]) in "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
        return api.appending(path: hashPrefix(videoID)).appending(queryItems: [
            URLQueryItem(name: "categories", value: list(categories.map(\.rawValue))),
            URLQueryItem(name: "actionTypes", value: list(["skip"])),
        ])
    }

    /// The answer covers every video sharing the hash prefix; only `videoID`'s skips are kept.
    static func segments(in data: Data, for videoID: String) -> [Segment] {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.filter { $0.videoID == videoID }.flatMap(\.segments).compactMap { raw in
            guard raw.actionType == "skip", raw.segment.count == 2, raw.segment[0] < raw.segment[1],
                  let category = SegmentCategory(rawValue: raw.category) else { return nil }
            return Segment(id: raw.UUID, start: raw.segment[0], end: raw.segment[1], category: category, videoDuration: raw.videoDuration ?? 0)
        }
        .sorted { $0.start < $1.start }
    }

    func segments(for videoID: String) async -> [Segment] {
        let categories = SegmentCategory.allCases.filter { actions[$0] != .ignore }
        guard !categories.isEmpty,
              let (data, response) = try? await fetch(Self.request(for: videoID, categories: categories)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return Self.segments(in: data, for: videoID)
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard isEnabled, message.world == Self.world, message.frameInfo.isMainFrame,
              Self.isYouTube(scheme: message.frameInfo.securityOrigin.protocol, host: message.frameInfo.securityOrigin.host),
              let body = message.body as? [String: Any], body["action"] as? String == "segments",
              let videoID = body["videoID"] as? String, Self.isVideoID(videoID) else { return (nil, "Not allowed") }
        let segments = await segments(for: videoID).compactMap { segment -> [String: Any]? in
            guard let action = actions[segment.category], action != .ignore else { return nil }
            return [
                "id": segment.id, "start": segment.start, "end": segment.end, "duration": segment.videoDuration,
                "category": segment.category.rawValue, "label": segment.category.label, "color": segment.category.color,
                "action": action.rawValue,
            ]
        }
        return (["segments": segments], nil)
    }

    nonisolated static func download(_ url: URL) async throws -> (Data, URLResponse) {
        try await session.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10))
    }

    private nonisolated static let session = URLSession(configuration: .ephemeral)

    private struct Entry: Decodable {
        let videoID: String
        let segments: [RawSegment]
    }

    private struct RawSegment: Decodable {
        let category: String
        let actionType: String
        let segment: [Double]
        let UUID: String
        let videoDuration: Double?
    }
}

struct Segment: Equatable {
    let id: String
    let start: Double
    let end: Double
    let category: SegmentCategory
    /// The video's length when the segment was submitted; 0 when unknown.
    let videoDuration: Double
}

enum SegmentAction: String, CaseIterable {
    case skip, button, ignore
}

/// SponsorBlock's categories, in the order its own settings list them. Colors are SponsorBlock's.
enum SegmentCategory: String, CaseIterable {
    case sponsor, selfpromo, interaction, intro, outro, preview, filler
    case musicOfftopic = "music_offtopic"

    var label: String {
        switch self {
        case .sponsor: "Sponsor"
        case .selfpromo: "Self-promotion"
        case .interaction: "Subscribe reminder"
        case .intro: "Intro"
        case .outro: "Endcards and credits"
        case .preview: "Preview and recap"
        case .filler: "Filler tangent"
        case .musicOfftopic: "Non-music section"
        }
    }

    var hint: String {
        switch self {
        case .sponsor: "Paid promotion, or a paid referral or discount."
        case .selfpromo: "The creator’s own merch, donations, or channels they work with, unpaid."
        case .interaction: "A short reminder to like, subscribe or follow in the middle of the video."
        case .intro: "An interval with no actual content: a pause, a static frame, a repeating animation."
        case .outro: "Credits or YouTube endscreens, once the content is over."
        case .preview: "A collection of clips showing what is coming up, or a recap of past episodes."
        case .filler: "Tangents added only for filler or humor, not needed to follow the video."
        case .musicOfftopic: "In music videos, the part that is not the song."
        }
    }

    var color: String {
        switch self {
        case .sponsor: "#00D400"
        case .selfpromo: "#FFFF00"
        case .interaction: "#CC00FF"
        case .intro: "#00FFFF"
        case .outro: "#0202ED"
        case .preview: "#008FD6"
        case .filler: "#7300FF"
        case .musicOfftopic: "#FF9900"
        }
    }

    var defaultAction: SegmentAction {
        switch self {
        case .sponsor: .skip
        case .selfpromo, .interaction: .button
        default: .ignore
        }
    }
}
