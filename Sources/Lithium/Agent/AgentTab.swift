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
    /// The session whose call last ran in the tab or acted there.
    @ObservationIgnored var holder: String?
    /// The page's alert, confirm or prompt, waiting for an answer, and how to give it: nil hands
    /// it to the user, as the page's own dialog.
    var dialog: AgentDialog?
    @ObservationIgnored var dialogReply: CheckedContinuation<DialogReply?, Never>?
    /// The agent started the tab's load: its navigation or its events. A download while that
    /// load is under way is the agent's, and asks the user, until the user's own click or Enter
    /// starts another load.
    @ObservationIgnored var drive: AgentDrive?
    /// The user's answers to the agent's downloads in the tab, for the call that started one.
    var downloadAnswers = 0
    @ObservationIgnored var downloadAnswer: Result<ConfirmationGrant, AgentToolError>?
    /// Files the user allowed for an upload, for the next file chooser within 5 seconds.
    @ObservationIgnored var armedUpload: (files: [URL], expires: ContinuousClock.Instant)?
    /// File choosers the agent's action opened without allowed files, cancelled.
    @ObservationIgnored var fileChoosersCancelled = 0
    /// The page size an agent asked for with `resize`, while the tab is out of the user's window;
    /// shown to the user, the page takes the window's size again and this goes.
    @ObservationIgnored var viewport: CGSize?
    /// The agent action running in it, for the border, caption and pointer dot the user sees.
    var acting: AgentActing?
    /// Tabs its page opened during that action.
    @ObservationIgnored var opened: [Tab] = []
    /// Forms whose fields the user allowed an agent to fill, for 2 minutes after the first Allow
    /// (card number, expiry and CVC ask once), by form, session and kind.
    @ObservationIgnored var formCovers: [FormCover] = []
    /// Prompts the user was shown for it, so an action knows it waited on them.
    @ObservationIgnored var prompts = 0
    /// The Allows `gate` and an upload got during the action running in it, by kind, prompt and
    /// subject: the action run again (`AgentHub.action`) takes each once, without asking twice.
    /// A download or a file never comes from it: each asks.
    @ObservationIgnored var answered: [String: ConfirmationGrant] = [:]
    /// Its network log and console, from the first agent use of the tab: nil until then, so a
    /// tab no agent used costs nothing.
    @ObservationIgnored var capture: TabCapture?

    static func prompt(_ kind: ConfirmationKind, _ action: String, subject: String) -> String {
        "\(kind.rawValue)\n\(action)\n\(subject)"
    }

    /// The child frames that said hello, by document token; the main frame needs no `WKFrameInfo`.
    @ObservationIgnored private(set) var frames: [String: WKFrameInfo] = [:]
    @ObservationIgnored private(set) var mainDocument: String?
    /// Public refs: `e12` for an element, `f3` for a frame's document, `f3:e40` inside it. Numbers
    /// count up for the tab's whole life, so a ref from an old page never names an element of a new one.
    /// The table holds the page shown; a page left takes its own along, for Back to bring back.
    private struct RefTable {
        var refs: [String: ElementAddress] = [:]
        var issued: [ElementAddress: String] = [:]
        var frameRefs: [String: String] = [:]
        var frameElements: [ElementAddress: String] = [:]
    }
    @ObservationIgnored private var table = RefTable()
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
            // A frame that navigated has one document, so one token: the last one's refs are
            // stale already, and keeping it would grow `frames` and run capture's scripts twice
            // there. Without WebKit's frame id, nothing is dropped.
            if let id = ResourceLoadSpy.frameID(of: frame),
               let old = frames.first(where: { $0.key != token && ResourceLoadSpy.frameID(of: $0.value) == id })?.key {
                frames[old] = nil
                reports[old] = nil
            }
            frames[token] = frame
            if frames.count >= sweepAt { sweepFrames() }
        }
    }

    /// Child frames held before those WebKit no longer has are swept out: a page that keeps
    /// swapping frames (rotating ads) would otherwise pile them up until it is left. Each is
    /// asked once, in Lithium's world: a frame that is gone fails the call, and a busy one just
    /// doesn't answer and stays. The next sweep waits for twice the frames still held.
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

    /// The tab's page went (it slept, or its process died): every frame went with it, and with
    /// the pages left too.
    func pageGone() {
        frames = [:]
        pagesLeft = []
        reports = [:]
        sweepAt = Self.framesBeforeSweep
    }

    /// How many main documents said hello: a main frame asked before the last one answered from
    /// the document before it.
    @ObservationIgnored private(set) var hellos = 0

    /// The main frame, asked when `hellos` was `asked`, answered with its document token: a page
    /// without the bootstrap (open before access was on) makes its own. False when a main document
    /// said hello since and the answer came from another one: a late answer of the page left.
    func mainFrameAnswered(_ token: String, asked: Int) -> Bool {
        guard mainDocument != token else { return true }
        guard asked == hellos else { return false }
        reports = [:]
        if mainDocument == nil { mainDocument = token } else { switchPage(to: token) }
        return true
    }

    /// The frames and refs of the pages left, by main document: a restored page's frames say hello
    /// again, maybe before its main frame does, and the frames of a page left must never answer
    /// for it. Its refs answer `stale_ref` until it comes back. The last 8 left are kept, the
    /// oldest first out.
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

    /// Refs held for the page shown, and for the pages left that Back may bring back.
    var refCounts: (shown: Int, kept: Int) {
        (table.refs.count, pagesLeft.reduce(0) { $0 + $1.refs.refs.count })
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

    /// Element refs held for the page shown before the oldest half goes: a long-lived page that
    /// keeps changing would otherwise get new refs forever. A dropped ref answers `stale_ref`.
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

    /// `f1`, `f2`: one per frame document.
    func frameRef(for document: String) -> String {
        if let ref = table.frameRefs[document] { return ref }
        let ref = "f\(nextFrame)"
        nextFrame += 1
        table.frameRefs[document] = ref
        return ref
    }

    /// The document a frame ref (`f3`) names, while the page that issued it is shown.
    func document(ofFrame ref: String) -> String? {
        table.frameRefs.first { $0.value == ref }?.key
    }

    /// The element a ref names. A frame ref names its `<iframe>` element in the parent, as last
    /// reported, so element tools work on it like on any element.
    func address(of ref: String) -> ElementAddress? {
        table.refs[ref]
    }

    func setFrameElement(_ frameRef: String, _ address: ElementAddress) {
        table.refs[frameRef] = address
        table.frameElements[address] = frameRef
    }

    /// The ref of the frame document last read in the `<iframe>` at `address`.
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
    /// "Clicking “Pay €42.00”".
    var caption: String
    /// The agent's pointer, in the web view's points.
    var pointer: CGPoint?
}

/// Typing into one form's fields, allowed once by the user for a while.
struct FormCover {
    let form: ElementAddress
    let session: String
    let kind: ConfirmationKind
    let until: ContinuousClock.Instant
}

/// An agent's input in a tab: the session that gave it, how far the tab's loads had got then,
/// and the deadline of the call that gave it.
struct AgentDrive {
    let session: MCPSession
    var marks: Tab.LoadMarks
    let deadline: ContinuousClock.Instant
    /// The user clicked in the page since, or pressed Enter there.
    var userActivated = false

    /// Until the load it started ends: a page shown, a move within the page, a download, a
    /// scheme refused. A load that ends without a word (cancelled), or never starts, ends it at
    /// the call's deadline; one still loading then is still the agent's.
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

    /// The challenge a frame at `address` belongs to, by its host. The invisible reCAPTCHA badge
    /// and hCaptcha checkbox are on many pages without any challenge, so they don't count.
    static func kind(of address: String) -> String? {
        kind(of: address, countingInvisible: false)
    }

    /// Whether `address` is a challenge provider's frame, invisible or not: its own address then
    /// says whether it counts, and the origin alone, which has lost the query, must not.
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
