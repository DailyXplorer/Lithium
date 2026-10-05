import Foundation
import Observation
import WebKit

/// An element as `agent.js` knows it: the document's random token and the element's number in it.
struct ElementAddress: Hashable {
    let document: String
    let id: Int
}

/// What agents have to do with one tab: its badge, its queue, the frames its page reported, the
/// refs issued in it, and the last snapshot each session got. Made the first time an agent
/// touches the tab or one of its frames says hello; dropped when the tab closes.
@MainActor
@Observable
final class AgentTab {
    @ObservationIgnored weak var tab: Tab?
    /// An agent opened, navigated, selected or stopped it: it carries a badge until it closes.
    var isTouched = false
    /// An agent call is running in it (`AgentHub.exclusive`).
    var isBusy = false
    /// What ends the call running in it early; cleared when that call ends.
    var interruption: AgentInterruption?
    /// A CAPTCHA or bot check the agent met in it, for the indicator, until a read finds none or
    /// the main frame shows another document.
    var challenge: AgentChallenge?
    @ObservationIgnored var lastAction: Date?

    /// The child frames that said hello, by document token; the main frame needs no `WKFrameInfo`.
    @ObservationIgnored private(set) var frames: [String: WKFrameInfo] = [:]
    @ObservationIgnored private(set) var mainDocument: String?
    /// Public refs: `e12` for an element, `f3` for a frame's document, `f3:e40` inside it. Numbers
    /// count up for the tab's whole life, so a ref from an old page never names an element of a new one.
    @ObservationIgnored private var refs: [String: ElementAddress] = [:]
    @ObservationIgnored private var issued: [ElementAddress: String] = [:]
    @ObservationIgnored private var frameRefs: [String: String] = [:]
    @ObservationIgnored private var frameElements: [ElementAddress: String] = [:]
    @ObservationIgnored private var nextElement = 1
    @ObservationIgnored private var nextFrame = 1
    /// Each frame's last full report and the generation it had, so an unchanged frame answers
    /// without walking its document.
    @ObservationIgnored var reports: [String: (scope: String, report: FrameReport)] = [:]
    /// The last snapshot each session got of this tab in each view (scope and size), for diffs,
    /// and the last `seq` each session got.
    @ObservationIgnored var snapshots: [String: PageSnapshot] = [:]
    @ObservationIgnored var seqs: [String: Int] = [:]
    /// Every node a snapshot of this page showed, so `stale_ref` can say what a ref was.
    @ObservationIgnored var shown: [String: SnapshotNode] = [:]

    init(tab: Tab) {
        self.tab = tab
    }

    // MARK: Frames

    /// A frame's bootstrap said hello. The main frame's starts a new page, whose frames are all
    /// new, or brings back one Back or Forward restored from WebKit's cache, with its frames.
    func hello(token: String, frame: WKFrameInfo) {
        if frame.isMainFrame {
            guard token != mainDocument else { return }
            reports = [:]
            shown = [:]
            // The user may have passed the check: the next read says if the new page is one.
            challenge = nil
            switchPage(to: token)
        } else {
            frames[token] = frame
        }
    }

    /// The main frame answered with its document token: a page without the bootstrap (open before
    /// access was on) makes its own.
    func mainFrameAnswered(_ token: String) {
        guard mainDocument != token else { return }
        reports = [:]
        if mainDocument == nil { mainDocument = token } else { switchPage(to: token) }
    }

    /// The frames of the pages left, by main document: a restored page's frames say hello again,
    /// maybe before its main frame does, and the frames of a page left must never answer for it.
    @ObservationIgnored private var framesOfPagesLeft: [String: [String: WKFrameInfo]] = [:]

    private func switchPage(to token: String) {
        if let mainDocument, !frames.isEmpty {
            if framesOfPagesLeft.count >= 8 { framesOfPagesLeft = [:] }
            framesOfPagesLeft[mainDocument] = frames
        }
        frames = framesOfPagesLeft.removeValue(forKey: token) ?? [:]
        mainDocument = token
    }

    /// A child frame answered as another document (it navigated), or not at all (it is gone).
    func childFrame(_ token: String, answeredAs current: String?) {
        guard current != token, let frame = frames.removeValue(forKey: token) else { return }
        reports[token] = nil
        if let current, frames[current] == nil { frames[current] = frame }
    }

    /// The frame to call for a document, nil once it is gone.
    func target(for document: String) -> FrameTarget? {
        if document == mainDocument { return .main }
        return frames[document].map(FrameTarget.child)
    }

    // MARK: Refs

    func ref(for address: ElementAddress) -> String {
        if let ref = issued[address] { return ref }
        let element = "e\(nextElement)"
        nextElement += 1
        let ref = address.document == mainDocument ? element : "\(frameRef(for: address.document)):\(element)"
        issued[address] = ref
        refs[ref] = address
        return ref
    }

    /// `f1`, `f2`: one per frame document.
    func frameRef(for document: String) -> String {
        if let ref = frameRefs[document] { return ref }
        let ref = "f\(nextFrame)"
        nextFrame += 1
        frameRefs[document] = ref
        return ref
    }

    /// The element a ref names. A frame ref names its `<iframe>` element in the parent, as last
    /// reported, so element tools work on it like on any element.
    func address(of ref: String) -> ElementAddress? {
        refs[ref]
    }

    func setFrameElement(_ frameRef: String, _ address: ElementAddress) {
        refs[frameRef] = address
        frameElements[address] = frameRef
    }

    /// The ref of the frame document last read in the `<iframe>` at `address`.
    func frameRef(at address: ElementAddress) -> String? {
        frameElements[address]
    }

    nonisolated static func isRef(_ string: String) -> Bool {
        string.wholeMatch(of: /(f\d+:)?e\d+|f\d+/) != nil
    }
}

/// A CAPTCHA or bot check on the page. `page` when the whole page is the check (Cloudflare's
/// "Just a moment", DataDome, PerimeterX, AWS WAF); else a widget in a frame, named by `ref`.
struct AgentChallenge: Equatable {
    let kind: String
    var ref: String?
    var page: Bool

    var json: JSONValue {
        var fields: [String: JSONValue] = ["kind": .string(kind)]
        if let ref { fields["ref"] = .string(ref) }
        if page { fields["page"] = true }
        return .object(fields)
    }

    var label: String {
        switch kind {
        case "recaptcha": "reCAPTCHA"
        case "hcaptcha": "hCaptcha"
        case "turnstile": "Cloudflare Turnstile"
        case "cloudflare": "Cloudflare check"
        case "arkose": "Arkose challenge"
        case "datadome": "DataDome check"
        case "perimeterx": "PerimeterX check"
        case "aws-waf": "AWS WAF check"
        default: kind
        }
    }

    static let pageKinds: Set<String> = ["cloudflare", "datadome", "perimeterx", "aws-waf"]

    /// The challenge a frame at `address` belongs to, by its host. reCAPTCHA's invisible badge
    /// is on many pages without any challenge, so it doesn't count.
    static func kind(of address: String) -> String? {
        guard let url = URL(string: address), let host = url.host()?.lowercased() else { return nil }
        let within = { (domain: String) in host == domain || host.hasSuffix("." + domain) }
        if (within("google.com") && url.path().hasPrefix("/recaptcha/")) || within("recaptcha.net") {
            return url.query()?.contains("size=invisible") == true ? nil : "recaptcha"
        }
        if within("hcaptcha.com") { return "hcaptcha" }
        if host == "challenges.cloudflare.com" { return "turnstile" }
        if within("arkoselabs.com") || within("funcaptcha.com") { return "arkose" }
        if within("captcha-delivery.com") { return "datadome" }
        if within("px-cloud.net") || within("perimeterx.net") || within("px-cdn.net") { return "perimeterx" }
        if within("awswaf.com") { return "aws-waf" }
        return nil
    }
}
