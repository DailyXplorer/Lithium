import Foundation
import Observation
import WebKit

/// An element as `agent.js` knows it: the document's random token and the element's number in it.
struct ElementAddress: Hashable {
    let document: String
    let id: Int
}

/// What agents have to do with one tab. Made the first time an agent touches the tab or one of
/// its frames says hello; dropped when the tab closes.
@MainActor
@Observable
final class AgentTab {
    @ObservationIgnored weak var tab: Tab?
    /// An agent opened, navigated, selected or stopped it: it carries a badge until it closes.
    var isTouched = false
    var isBusy = false
    /// What ends the running call early; cleared when that call ends.
    var interruption: AgentInterruption?
    /// Kept until a read finds none or the main frame shows another document.
    var challenge: AgentChallenge?
    @ObservationIgnored var lastAction: Date?
    @ObservationIgnored var holder: String?
    /// The page's alert, confirm or prompt; nil hands it to the user.
    var dialog: AgentDialog?
    @ObservationIgnored var dialogReply: CheckedContinuation<DialogReply?, Never>?
    /// The agent started the tab's load: a download while it is under way is the agent's, and
    /// asks the user, until the user's own click or Enter starts another load.
    @ObservationIgnored var drive: AgentDrive?
    var downloadAnswers = 0
    @ObservationIgnored var downloadAnswer: Result<ConfirmationGrant, AgentToolError>?
    /// Files the user allowed for an upload, for the next file chooser within 5 seconds.
    @ObservationIgnored var armedUpload: (files: [URL], expires: ContinuousClock.Instant)?
    @ObservationIgnored var fileChoosersCancelled = 0
    /// Set by `resize` while the tab is out of the user's window; cleared once shown.
    @ObservationIgnored var viewport: CGSize?
    var acting: AgentActing?
    @ObservationIgnored var opened: [Tab] = []
    /// Forms the user allowed an agent to fill, for 2 minutes (card number, expiry and CVC ask once).
    @ObservationIgnored var formCovers: [FormCover] = []
    @ObservationIgnored var prompts = 0
    /// Allows got during the running action, so its retry (`AgentHub.action`) doesn't ask twice.
    /// Downloads and files never come from it: each asks.
    @ObservationIgnored var answered: [String: ConfirmationGrant] = [:]
    /// Nil until the first agent use, so a tab no agent used costs nothing.
    @ObservationIgnored var capture: TabCapture?

    static func prompt(_ kind: ConfirmationKind, _ action: String, subject: String) -> String {
        "\(kind.rawValue)\n\(action)\n\(subject)"
    }

    /// Child frames by document token; the main frame needs no `WKFrameInfo`.
    @ObservationIgnored private(set) var frames: [String: WKFrameInfo] = [:]
    @ObservationIgnored private(set) var mainDocument: String?
    /// Refs: `e12`, `f3` for a frame's document, `f3:e40` inside it. Numbers count up for the
    /// tab's whole life, so a ref from an old page never names an element of a new one.
    private struct RefTable {
        var refs: [String: ElementAddress] = [:]
        var issued: [ElementAddress: String] = [:]
        var frameRefs: [String: String] = [:]
        var frameElements: [ElementAddress: String] = [:]
    }
    @ObservationIgnored private var table = RefTable()
    @ObservationIgnored private var nextElement = 1
    @ObservationIgnored private var nextFrame = 1
    /// So an unchanged frame answers without walking its document.
    @ObservationIgnored var reports: [String: (scope: String, report: FrameReport)] = [:]
    /// The last snapshot each session got in each view, for diffs.
    @ObservationIgnored var snapshots: [String: PageSnapshot] = [:]
    @ObservationIgnored var seqs: [String: Int] = [:]
    /// Every node a snapshot of this page showed, so `stale_ref` can say what a ref was.
    @ObservationIgnored var shown: [String: SnapshotNode] = [:]

    init(tab: Tab) {
        self.tab = tab
    }

    // MARK: Frames

    /// The main frame's hello starts a new page, or brings back one restored from WebKit's cache.
    func hello(token: String, frame: WKFrameInfo, restored: Bool = false) {
        if frame.isMainFrame {
            guard token != mainDocument else { return }
            hellos += 1
            reports = [:]
            shown = [:]
            // The user may have passed the check: the next read says if the new page is one.
            challenge = nil
            capture?.newPage(restored: restored)
            switchPage(to: token)
        } else {
            // A frame that navigated drops its old token, which would otherwise grow `frames`
            // and run capture's scripts twice there. Without WebKit's frame id, nothing is dropped.
            if let id = ResourceLoadSpy.frameID(of: frame),
               let old = frames.first(where: { $0.key != token && ResourceLoadSpy.frameID(of: $0.value) == id })?.key {
                frames[old] = nil
                forgetDocument(old)
            }
            frames[token] = frame
            if frames.count >= sweepAt { sweepFrames() }
        }
    }

    /// Frames held before gone ones are swept, so rotating ads don't pile them up. A gone frame
    /// fails the probe call; a busy one doesn't answer and stays.
    static let framesBeforeSweep = 32
    @ObservationIgnored private var sweepAt = framesBeforeSweep

    private func sweepFrames() {
        guard let webView = tab?.loadedWebView else { return }
        sweepAt = frames.count * 2
        for (token, frame) in frames {
            webView.callAsyncJavaScript("return 0", arguments: [:], in: frame, in: PageProbe.world) { [weak self] result in
                guard case .failure = result else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.childFrame(token, answeredAs: nil)
                    self.sweepAt = max(Self.framesBeforeSweep, self.frames.count * 2)
                }
            }
        }
    }

    func pageGone() {
        frames = [:]
        pagesLeft = []
        reports = [:]
        sweepAt = Self.framesBeforeSweep
    }

    /// How many main documents said hello, to spot a late answer from the page before.
    @ObservationIgnored private(set) var hellos = 0

    /// A page without the bootstrap (open before access was on) makes its own token. False for a
    /// late answer from a page left since `asked`.
    func mainFrameAnswered(_ token: String, asked: Int) -> Bool {
        guard mainDocument != token else { return true }
        guard asked == hellos else { return false }
        reports = [:]
        if mainDocument == nil { mainDocument = token } else { switchPage(to: token) }
        return true
    }

    /// The last 8 pages left, for Back: a restored page's frames may say hello before its main
    /// frame, and a page left's frames must never answer for the page shown.
    @ObservationIgnored private var pagesLeft: [(document: String, frames: [String: WKFrameInfo], refs: RefTable)] = []

    private func switchPage(to token: String) {
        // Taken out first: the page coming back may be the oldest kept.
        let restored = pagesLeft.firstIndex { $0.document == token }.map { pagesLeft.remove(at: $0) }
        if let mainDocument, !frames.isEmpty || !table.refs.isEmpty {
            pagesLeft.append((mainDocument, frames, table))
            if pagesLeft.count > 8 { pagesLeft.removeFirst() }
        }
        frames = restored?.frames ?? [:]
        table = restored?.refs ?? RefTable()
        mainDocument = token
    }

    var refCounts: (shown: Int, kept: Int, frames: Int) {
        (table.refs.count, pagesLeft.reduce(0) { $0 + $1.refs.refs.count }, table.frameRefs.count)
    }

    /// A child frame answered as another document (it navigated), or not at all (it is gone).
    func childFrame(_ token: String, answeredAs current: String?) {
        guard current != token, let frame = frames.removeValue(forKey: token) else { return }
        forgetDocument(token)
        if let current, frames[current] == nil { frames[current] = frame }
    }

    private func forgetDocument(_ token: String) {
        reports[token] = nil
        guard let ref = table.frameRefs.removeValue(forKey: token) else { return }
        if let element = table.refs.removeValue(forKey: ref), table.frameElements[element] == ref {
            table.frameElements[element] = nil
        }
    }

    func target(for document: String) -> FrameTarget? {
        if document == mainDocument { return .main }
        return frames[document].map(FrameTarget.child)
    }

    // MARK: Refs

    /// Then the oldest half goes, or a long-lived changing page would get new refs forever.
    static let maxRefs = 40_000

    func ref(for address: ElementAddress) -> String {
        if let ref = table.issued[address] { return ref }
        if table.issued.count >= Self.maxRefs { dropOldestRefs() }
        let element = "e\(nextElement)"
        nextElement += 1
        let ref = address.document == mainDocument ? element : "\(frameRef(for: address.document)):\(element)"
        table.issued[address] = ref
        table.refs[ref] = address
        return ref
    }

    /// Numbers count up, so the lowest are the oldest; frame refs stay.
    private func dropOldestRefs() {
        let oldest = nextElement - Self.maxRefs / 2
        for (address, ref) in table.issued where Int(ref.split(separator: "e").last ?? "") ?? 0 < oldest {
            table.issued[address] = nil
            table.refs[ref] = nil
        }
    }

    func frameRef(for document: String) -> String {
        if let ref = table.frameRefs[document] { return ref }
        let ref = "f\(nextFrame)"
        nextFrame += 1
        table.frameRefs[document] = ref
        return ref
    }

    func document(ofFrame ref: String) -> String? {
        table.frameRefs.first { $0.value == ref }?.key
    }

    /// A frame ref names its `<iframe>` element in the parent, so element tools work on it too.
    func address(of ref: String) -> ElementAddress? {
        table.refs[ref]
    }

    func setFrameElement(_ frameRef: String, _ address: ElementAddress) {
        table.refs[frameRef] = address
        table.frameElements[address] = frameRef
    }

    func frameRef(at address: ElementAddress) -> String? {
        table.frameElements[address]
    }

    nonisolated static func isRef(_ string: String) -> Bool {
        string.wholeMatch(of: /(f\d+:)?e\d+|f\d+/) != nil
    }
}

/// An agent action in progress in a tab, as the user sees it in the page.
struct AgentActing: Equatable {
    let session: String
    var caption: String
    /// The agent's pointer, in the web view's points.
    var pointer: CGPoint?
}

struct FormCover {
    let form: ElementAddress
    let session: String
    let kind: ConfirmationKind
    let until: ContinuousClock.Instant
}

/// An agent's input in a tab, with how far the tab's loads had got then.
struct AgentDrive {
    let session: MCPSession
    var marks: Tab.LoadMarks
    let deadline: ContinuousClock.Instant
    /// The user clicked in the page since, or pressed Enter there.
    var userActivated = false

    /// Until the load it started ends. A load that ends silently (cancelled) or never starts ends
    /// it at the call's deadline; one still loading then is still the agent's.
    @MainActor
    func isUnderWay(in tab: Tab) -> Bool {
        tab.loadMarks == marks && (tab.isLoading || .now < deadline)
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

    /// The invisible reCAPTCHA badge and hCaptcha checkbox are on many pages without any
    /// challenge, so they don't count.
    static func kind(of address: String) -> String? {
        kind(of: address, countingInvisible: false)
    }

    /// Invisible or not: only the frame's own address says whether it counts, not its origin,
    /// which has lost the query.
    static func isProvider(_ address: String) -> Bool {
        kind(of: address, countingInvisible: true) != nil
    }

    private static func kind(of address: String, countingInvisible: Bool) -> String? {
        guard let url = URL(string: address), let host = url.host()?.lowercased() else { return nil }
        let within = { (domain: String) in host == domain || host.hasSuffix("." + domain) }
        if (within("google.com") && url.path().hasPrefix("/recaptcha/")) || within("recaptcha.net") {
            return !countingInvisible && url.query()?.contains("size=invisible") == true ? nil : "recaptcha"
        }
        if within("hcaptcha.com") { return !countingInvisible && url.fragment()?.contains("invisible") == true ? nil : "hcaptcha" }
        if host == "challenges.cloudflare.com" { return "turnstile" }
        if within("arkoselabs.com") || within("funcaptcha.com") { return "arkose" }
        if within("captcha-delivery.com") { return "datadome" }
        if within("px-cloud.net") || within("perimeterx.net") || within("px-cdn.net") { return "perimeterx" }
        if within("awswaf.com") { return "aws-waf" }
        return nil
    }
}
