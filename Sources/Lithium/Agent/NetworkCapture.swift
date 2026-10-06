import Foundation
import Observation
import WebKit

/// One request in a tab's network log, its address and headers already redacted.
struct NetworkEntry {
    let id: Int
    let loadID: UInt64
    /// WebKit's id of the child frame that made it; nil for the main frame.
    let frameID: UInt64?
    let type: String
    let method: String
    /// The method the page asked for, which a redirect may have changed: its script reports that one.
    let askedMethod: String
    let url: String
    let requestHeaders: [String: String]
    let started: ContinuousClock.Instant
    var status: Int?
    var mimeType: String?
    var responseHeaders: [String: String]?
    var fromCache = false
    var ended: ContinuousClock.Instant?
    var error: String?
    /// Stopped by WebKit or the page (a new page, `stop`), which is no failure of the server's.
    var cancelled = false
    var redirectedTo: String?
    var body: CapturedBody?

    /// An HTTP error, or the network failing.
    var failed: Bool {
        (status ?? 0) >= 400 || (error != nil && !cancelled)
    }

    /// The address and why it failed, as `batch` and `failedScripts` name it.
    var failure: String {
        "\(url) \(status.map(String.init) ?? error ?? "failed")"
    }
}

/// A response body kept for `network_body`: text only, redacted, cut at `TabCapture.maxBody`.
struct CapturedBody {
    let text: String
    let truncated: Bool
}

/// One console message or uncaught error, its text redacted.
struct ConsoleEntry {
    let id: Int
    let level: String
    /// `exception` or `rejection` for an error the page didn't catch.
    let kind: String?
    let text: String
    let source: String?
    let line: Int?
    let column: Int?
    let frameID: UInt64?
}

/// A tab's network log and console, from the first agent use of the tab until it closes or
/// access is turned off. Each is a ring buffer; a new page, or the tab sleeping, drops what the
/// page before left. `inFlight` and `lastActivity` are observed, for `networkIdle` waits.
@MainActor
@Observable
final class TabCapture {
    static let maxEntries = 1000
    static let maxMessages = 500
    static let maxBody = 256 * 1024
    /// Bodies kept per tab, all together; the oldest go first.
    static let maxBodies = 2 * 1024 * 1024

    @ObservationIgnored private(set) var entries: [NetworkEntry] = []
    @ObservationIgnored private(set) var messages: [ConsoleEntry] = []
    /// Requests of the page shown still loading: WebKit's load id to the entry's.
    private(set) var inFlight: [UInt64: Int] = [:]
    /// The last request that started or ended, or the capture starting.
    private(set) var lastActivity = ContinuousClock.now
    @ObservationIgnored private var nextEntry = 1
    @ObservationIgnored private var nextMessage = 1
    /// Where the page loading in the main frame starts in both buffers, from its document's request.
    @ObservationIgnored private var pageMark: (entry: Int, message: Int)?
    /// Frames showing an extension's page: what they load is the extension's, never listed.
    @ObservationIgnored private var extensionFrames: Set<UInt64> = []
    @ObservationIgnored private var bodyBytes = 0
    /// Set as the web view's resource load delegate, which WebKit holds weakly.
    @ObservationIgnored let spy = ResourceLoadSpy()

    init() {
        spy.capture = self
    }

    // MARK: Network

    /// `askedMethod`: the next leg of a request already listed, which a new page keeps from its
    /// first, and the method its first asked for.
    func requestStarted(_ load: ResourceLoadSpy.Load, method: String, url: URL?, headers: [AnyHashable: Any], askedMethod: String? = nil) {
        if url?.scheme?.lowercased() == Extensions.scheme {
            if !load.isMainFrame, load.type == "document", let frame = load.frameID { extensionFrames.insert(frame) }
            return
        }
        if let frame = load.frameID, extensionFrames.contains(frame) { return }
        if load.isMainFrame, load.type == "document", askedMethod == nil { pageMark = (nextEntry, nextMessage) }
        let address = String((url?.absoluteString ?? "").prefix(2048))
        append(NetworkEntry(id: nextEntry, loadID: load.id, frameID: load.frameID, type: load.type, method: method, askedMethod: askedMethod ?? method, url: AgentURLs.redacted(address), requestHeaders: AgentRedaction.headers(headers), started: .now))
        inFlight[load.id] = nextEntry - 1
        lastActivity = .now
    }

    /// A redirect ends the request with its status and starts the next one, under the same load.
    func redirected(_ load: ResourceLoadSpy.Load, response: URLResponse, to request: URLRequest) {
        guard let index = index(of: load.id), let next = request.url else { return }
        responded(at: index, response, fromCache: false)
        entries[index].redirectedTo = AgentURLs.redacted(next.absoluteString)
        entries[index].ended = .now
        inFlight[load.id] = nil
        requestStarted(load, method: request.httpMethod ?? entries[index].method, url: next, headers: request.allHTTPHeaderFields ?? [:], askedMethod: entries[index].askedMethod)
    }

    func responded(_ load: ResourceLoadSpy.Load, _ response: URLResponse) {
        guard let index = index(of: load.id) else { return }
        responded(at: index, response, fromCache: load.fromCache)
    }

    func completed(_ load: ResourceLoadSpy.Load, error: Error?, response: URLResponse?) {
        guard let index = index(of: load.id) else { return }
        if let response, entries[index].status == nil { responded(at: index, response, fromCache: load.fromCache) }
        entries[index].ended = .now
        if let error = error as NSError? {
            entries[index].error = error.localizedDescription
            entries[index].cancelled = error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
        }
        inFlight[load.id] = nil
        lastActivity = .now
    }

    private func responded(at index: Int, _ response: URLResponse, fromCache: Bool) {
        entries[index].mimeType = response.mimeType
        entries[index].fromCache = fromCache
        guard let http = response as? HTTPURLResponse else { return }
        entries[index].status = http.statusCode
        entries[index].responseHeaders = AgentRedaction.headers(http.allHeaderFields)
    }

    /// Entries keep consecutive ids, so a load's entry is found by arithmetic.
    private func index(of load: UInt64) -> Int? {
        guard let id = inFlight[load] else { return nil }
        return index(ofEntry: id)
    }

    func index(ofEntry id: Int) -> Int? {
        guard let first = entries.first?.id, id >= first, id - first < entries.count else { return nil }
        return id - first
    }

    private func append(_ entry: NetworkEntry) {
        entries.append(entry)
        nextEntry += 1
        guard entries.count > Self.maxEntries else { return }
        let gone = entries.removeFirst()
        bodyBytes -= gone.body?.text.utf8.count ?? 0
        if inFlight[gone.loadID] == gone.id { inFlight[gone.loadID] = nil }
    }

    /// A fetch or XHR body the page's script saw, kept with the latest request it fits that
    /// has none yet: the last leg of its redirects, at the address the body came from, under the
    /// method the page asked for. The text was redacted off the main thread.
    func attach(_ body: CapturedBody, url: String, method: String, frameID: UInt64?) {
        let address = AgentURLs.redacted(url)
        guard let index = entries.lastIndex(where: { $0.body == nil && $0.url == address && $0.askedMethod == method && $0.frameID == frameID && ["fetch", "xhr"].contains($0.type) }) else { return }
        entries[index].body = body
        bodyBytes += body.text.utf8.count
        for oldest in entries.indices where bodyBytes > Self.maxBodies {
            guard let dropped = entries[oldest].body else { continue }
            entries[oldest].body = nil
            bodyBytes -= dropped.text.utf8.count
        }
    }

    /// The main frame's scripts that failed on the page shown: handlers they would have attached
    /// are missing, and a button may do nothing.
    var failedScripts: [NetworkEntry] {
        entries.filter { $0.frameID == nil && $0.type == "script" && $0.failed }
    }

    // MARK: Console

    func log(level: String, kind: String? = nil, text: String, source: String? = nil, line: Int? = nil, column: Int? = nil, frameID: UInt64?) {
        messages.append(ConsoleEntry(id: nextMessage, level: level, kind: kind, text: AgentRedaction.text(String(text.prefix(4096))), source: source.map { AgentURLs.redacted(String($0.prefix(2048))) }, line: line, column: column, frameID: frameID))
        nextMessage += 1
        if messages.count > Self.maxMessages { messages.removeFirst() }
    }

    // MARK: Pages

    /// The main frame shows a new document: what the page before left goes. The new page's own
    /// request, and what it started before saying hello, stay. A page Back brings from WebKit's
    /// cache (`restored`), or one without a request seen (no resource load delegate), keeps nothing.
    func newPage(restored: Bool = false) {
        let mark = (restored ? nil : pageMark) ?? (nextEntry, nextMessage)
        pageMark = nil
        entries.removeAll { $0.id < mark.entry }
        messages.removeAll { $0.id < mark.message }
        inFlight = inFlight.filter { $0.value >= mark.entry }
        bodyBytes = entries.reduce(0) { $0 + ($1.body?.text.utf8.count ?? 0) }
        extensionFrames = []
    }

    /// The main frame's load ended without a page (a download, a stopped load): the page shown
    /// stays, and the next one starts from its own request.
    func loadEndedUnshown() {
        pageMark = nil
    }

    /// The tab slept or its page's process died: its page and its requests are gone.
    func reset() {
        entries = []
        messages = []
        inFlight = [:]
        pageMark = nil
        bodyBytes = 0
        extensionFrames = []
        lastActivity = .now
    }
}

/// The web view's resource load delegate (`_WKResourceLoadDelegate`, private WebKit, set only on
/// a web view that has `_setResourceLoadDelegate:`): every load of every frame, cross-origin ones
/// included, with the headers the page set and the response's status. Pages can't see it.
@MainActor
final class ResourceLoadSpy: NSObject {
    private static let setter = NSSelectorFromString("_setResourceLoadDelegate:")
    nonisolated static let isAvailable = WKWebView.instancesRespond(to: NSSelectorFromString("_setResourceLoadDelegate:"))

    weak var capture: TabCapture?

    func attach(to webView: WKWebView) {
        guard webView.responds(to: Self.setter) else { return }
        webView.perform(Self.setter, with: self)
    }

    func detach(from webView: WKWebView) {
        guard webView.responds(to: Self.setter), Self.delegate(of: webView) === self else { return }
        webView.perform(Self.setter, with: nil)
    }

    static func delegate(of webView: WKWebView) -> AnyObject? {
        property(webView, "_resourceLoadDelegate") as AnyObject?
    }

    /// What `_WKResourceLoadInfo` says of a load, each property read only if it is there.
    struct Load {
        let id: UInt64
        let frameID: UInt64?
        let isMainFrame: Bool
        let type: String
        let fromCache: Bool

        /// `_WKResourceLoadInfoResourceType`; 3, 5 and 12 were seen in the design's prototype.
        private static let types = [0: "manifest", 1: "beacon", 2: "csp-report", 3: "document", 4: "image", 5: "fetch", 6: "font", 7: "media", 8: "object", 9: "ping", 10: "script", 11: "stylesheet", 12: "xhr", 13: "xslt"]

        init?(_ info: NSObject) {
            guard let id = (ResourceLoadSpy.property(info, "resourceLoadID") as? NSNumber)?.uint64Value else { return nil }
            self.id = id
            // The main frame's loads have no parent frame.
            isMainFrame = info.responds(to: NSSelectorFromString("parentFrame")) && ResourceLoadSpy.property(info, "parentFrame") == nil
            frameID = isMainFrame ? nil : ResourceLoadSpy.frameID(of: ResourceLoadSpy.property(info, "frame") as? NSObject)
            type = (ResourceLoadSpy.property(info, "resourceType") as? NSNumber).flatMap { Self.types[$0.intValue] } ?? "other"
            fromCache = (ResourceLoadSpy.property(info, "loadedFromCache") as? NSNumber)?.boolValue ?? false
        }
    }

    /// A frame handle's id (`_WKFrameHandle.frameID`), the one a load and a script message share.
    nonisolated static func frameID(of handle: NSObject?) -> UInt64? {
        handle.flatMap { (property($0, "frameID") as? NSNumber)?.uint64Value }
    }

    /// A frame's id as `Load` gives it, through `WKFrameInfo._handle`; nil for the main frame.
    static func frameID(of frame: WKFrameInfo) -> UInt64? {
        frame.isMainFrame ? nil : frameID(of: property(frame, "_handle") as? NSObject)
    }

    /// A private property, read only where the object has it: a missing key would raise.
    private nonisolated static func property(_ object: NSObject, _ key: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    @objc(webView:resourceLoad:didSendRequest:)
    func webView(_ webView: WKWebView, resourceLoad info: NSObject, didSendRequest request: URLRequest) {
        guard let load = Load(info) else { return }
        // Lithium's own icon drawing; only its first load, so the page's of the same icon stays.
        if load.isMainFrame, load.type == "image", let url = request.url, (webView as? PageWebView)?.iconsDrawn.remove(url) != nil { return }
        capture?.requestStarted(load, method: request.httpMethod ?? "GET", url: request.url, headers: request.allHTTPHeaderFields ?? [:])
    }

    @objc(webView:resourceLoad:didPerformHTTPRedirection:newRequest:)
    func webView(_ webView: WKWebView, resourceLoad info: NSObject, didPerformHTTPRedirection response: URLResponse, newRequest request: URLRequest) {
        guard let load = Load(info) else { return }
        capture?.redirected(load, response: response, to: request)
    }

    @objc(webView:resourceLoad:didReceiveResponse:)
    func webView(_ webView: WKWebView, resourceLoad info: NSObject, didReceiveResponse response: URLResponse) {
        guard let load = Load(info) else { return }
        capture?.responded(load, response)
    }

    @objc(webView:resourceLoad:didCompleteWithError:response:)
    func webView(_ webView: WKWebView, resourceLoad info: NSObject, didCompleteWithError error: Error?, response: URLResponse?) {
        guard let load = Load(info) else { return }
        capture?.completed(load, error: error, response: response)
    }
}
