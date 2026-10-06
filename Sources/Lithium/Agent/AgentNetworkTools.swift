import Foundation
import WebKit

/// Receives what `agent-console.js` passes from the page's world: console messages, and response
/// bodies when Settings › Agents › Capture response bodies is on. The page can see this handler,
/// so it exists only in tabs an agent used (design section 8).
@MainActor
final class AgentConsoleHandler: NSObject, WKScriptMessageHandler {
    static let name = "lithiumAgentConsole"
    private static let levels: Set<String> = ["log", "info", "warn", "error", "debug"]

    weak var hub: AgentHub?
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()

    init(hub: AgentHub) {
        self.hub = hub
    }

    private static func script(_ name: String) -> String {
        Resources.bundle.url(forResource: name, withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    private static let consoleTemplate = script("agent-console")
    static func consoleSource(bodies: Bool) -> String {
        consoleTemplate.replacingOccurrences(of: "__LITHIUM_BODIES__", with: bodies ? "true" : "false")
    }

    private static let consoleScripts = [false, true].map { WKUserScript(source: consoleSource(bodies: $0), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page) }
    static let errorsSource = script("agent-errors")
    private static let errors = WKUserScript(source: errorsSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: PageProbe.world)

    /// The scripts for the documents the page loads from now on, in every frame.
    func install(on controller: WKUserContentController, bodies: Bool) {
        if !controllers.contains(controller) {
            controller.removeScriptMessageHandler(forName: Self.name, contentWorld: .page)
            controller.add(self, contentWorld: .page, name: Self.name)
            controllers.add(controller)
        }
        controller.addUserScript(Self.consoleScripts[bodies ? 1 : 0])
        controller.addUserScript(Self.errors)
    }

    /// A page that takes no script of the agent's doesn't find the handler either.
    func remove(from controller: WKUserContentController) {
        guard controllers.contains(controller) else { return }
        controller.removeScriptMessageHandler(forName: Self.name, contentWorld: .page)
        controllers.remove(controller)
    }

    /// Access turned off: pages no longer find the handler. A wrapper already in a page posts
    /// into nothing, without an error, until the page goes.
    func uninstall() {
        for controller in controllers.allObjects {
            controller.removeScriptMessageHandler(forName: Self.name, contentWorld: .page)
        }
        controllers.removeAllObjects()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let tab = (message.webView as? PageWebView)?.tab, let hub,
              let capture = hub.tabs[tab.id]?.capture, ![Internal.scheme, Extensions.scheme].contains(message.frameInfo.securityOrigin.protocol) else { return }
        let frameID = ResourceLoadSpy.frameID(of: message.frameInfo)
        if let response = body["body"] as? [String: Any] {
            guard hub.capturesBodies, let url = response["url"] as? String, let method = response["method"] as? String, let text = response["text"] as? String else { return }
            let truncated = response["truncated"] as? Bool ?? false
            let raw = String(text.prefix(TabCapture.maxBody))
            Task {
                let redacted = await Task.detached { AgentRedaction.body(raw) }.value
                capture.attach(CapturedBody(text: redacted, truncated: truncated || raw.count < text.count), url: url, method: method, frameID: frameID)
            }
        } else if let level = body["level"] as? String, Self.levels.contains(level) {
            if let dropped = body["dropped"] as? Int, dropped > 0 {
                capture.log(level: "warn", text: "Lithium left out \(dropped) console messages: the page logged more than 100 in a second.", frameID: frameID)
            }
            capture.log(level: level, text: body["text"] as? String ?? "", frameID: frameID)
        }
    }
}

extension AgentHub {
    static let networkTools: [AgentTool] = [networkLog, networkBody, consoleLog]

    // MARK: Capture

    /// The tab's network log and console, started the first time an agent uses the tab (any call
    /// naming it, or opening it): the resource load delegate on its web view, and the console
    /// and error scripts in its frames. The page shown gets them at once.
    @discardableResult
    func capture(in tab: Tab) -> TabCapture? {
        guard let state = agentTab(for: tab) else { return nil }
        if let capture = state.capture { return capture }
        let capture = TabCapture()
        state.capture = capture
        guard !tab.isAsleep, let webView = tab.loadedWebView else { return capture }
        if usesResourceLoadDelegate { capture.spy.attach(to: webView) }
        // Lithium's own pages take no script of the agent's.
        guard !AgentURLs.isBlocked(tab.url) else { return capture }
        consoleHandler.install(on: webView.configuration.userContentController, bodies: capturesBodies)
        let console = AgentConsoleHandler.consoleSource(bodies: capturesBodies)
        for frame in [nil] + state.frames.values.map(Optional.some) {
            webView.evaluateJavaScript(console, in: frame, in: .page, completionHandler: nil)
            webView.evaluateJavaScript(AgentConsoleHandler.errorsSource, in: frame, in: PageProbe.world, completionHandler: nil)
        }
        return capture
    }

    /// Hooked from `Tab.attach`: a tab agents use keeps its network log through a new web view
    /// (waking, a new configuration). Its scripts come with the page, from `install`.
    func didAttach(_ webView: WKWebView, to tab: Tab) {
        guard usesResourceLoadDelegate, let capture = tabs[tab.id]?.capture else { return }
        capture.spy.attach(to: webView)
    }

    /// Access turned off: no web view keeps the delegate, no page finds the console handler.
    func stopCapturing() {
        for state in tabs.values {
            if let capture = state.capture, let webView = state.tab?.loadedWebView { capture.spy.detach(from: webView) }
            state.capture = nil
        }
        consoleHandler.uninstall()
    }

    // MARK: Network idle

    /// `networkidle` needs to see requests start and end, which only the resource load delegate does.
    func checkNetworkIdle(_ wait: LoadWait) throws {
        guard wait == .networkidle, !usesResourceLoadDelegate else { return }
        throw AgentToolError(code: "unsupported", message: "networkidle needs WebKit’s resource load delegate, which this version of macOS doesn’t offer. Use load, or wait_for text or a ref.")
    }

    /// Until none of the page's requests has been in flight for `quiet`, counted from the last
    /// one that ended, or from `after` if later. Requests of a page the tab left don't count.
    /// The tab closing, sleeping, the user navigating it, `stop` and the deadline end the wait.
    func waitForNetworkIdle(_ named: NamedTab, quiet: Duration = .milliseconds(500), after start: ContinuousClock.Instant? = nil, deadline: ContinuousClock.Instant, timeout: Duration) async throws {
        try checkNetworkIdle(.networkidle)
        guard let capture = capture(in: named.tab) else { throw named.closedError }
        let quietSince = { () -> ContinuousClock.Instant? in
            guard capture.inFlight.isEmpty else { return nil }
            return max(capture.lastActivity, start ?? capture.lastActivity)
        }
        while true {
            let since = try await watch(named, until: deadline) { () -> ContinuousClock.Instant? in
                try self.checkPageShown(named, before: "its requests were done")
                return quietSince()
            }
            guard let since else {
                throw timedOut(named, after: timeout, "\(capture.inFlight.count) of its requests were still loading")
            }
            if ContinuousClock.now >= since + quiet { return }
            guard ContinuousClock.now < deadline else {
                throw timedOut(named, after: timeout, "its last request ended less than \(Int(quiet / .milliseconds(1))) ms before")
            }
            _ = try await watch(named, until: min(since + quiet, deadline)) { quietSince() != since ? true : nil }
        }
    }

    // MARK: Tools

    private static let tabParam = AgentParam.tab

    static let networkLog = AgentTool(
        name: "network_log",
        description: "List the page’s requests (secrets redacted); recorded from the agent’s first call in the tab.",
        inputSchema: schema([
            "tab": tabParam,
            "since": ["type": "integer", "description": "Only ids above this"],
            "filter": ["type": "string", "description": "Part of the URL"],
            "type": ["type": "string", "enum": ["document", "fetch", "xhr", "script", "stylesheet", "image", "font", "media", "other"]],
            "minStatus": ["type": "integer", "description": "Such as 400 for errors"],
            "headers": AgentParam.flag,
            "limit": ["type": "integer", "description": "Default 100, newest"],
        ], required: ["tab"]),
        output: { arguments, _, hub in
            let arguments = Arguments(value: arguments)
            let named = try hub.tab(named: try arguments.string("tab"))
            let since = try arguments.value["since"].map { _ in try arguments.int("since", default: 0, in: 0...Int.max) }
            let filter = try arguments.optionalString("filter")?.lowercased()
            let type = try arguments.optionalString("type")
            let minStatus = try arguments.int("minStatus", default: 0, in: 0...999)
            let headers = try arguments.bool("headers", default: false)
            let limit = try arguments.int("limit", default: 100, in: 1...1000)
            try hub.checkDrivable(named)
            guard let capture = hub.capture(in: named.tab), let state = hub.tabs[named.tab.id] else { throw named.closedError }
            guard hub.usesResourceLoadDelegate else {
                if since != nil { throw AgentToolError(code: "unsupported", message: "since needs WebKit’s resource load delegate, which this version of macOS doesn’t offer.") }
                return try await hub.timelineLog(named, filter: filter, type: type, minStatus: minStatus, limit: limit)
            }
            let frames = frameRefs(in: state)
            let matching = capture.entries.filter { entry in
                entry.id > (since ?? 0) && (filter.map { entry.url.lowercased().contains($0) } ?? true)
                    && (type.map { entry.type == $0 || $0 == "other" && !namedTypes.contains(entry.type) } ?? true)
                    && (entry.status ?? 999) >= minStatus
            }
            let shown = matching.suffix(limit)
            var fields: [String: JSONValue] = [
                "tab": .string(named.id),
                "source": "resource-load-delegate",
                "entries": .array(shown.map { json($0, frames: frames, headers: headers) }),
            ]
            if matching.count > shown.count { fields["omitted"] = .int(matching.count - shown.count) }
            var lines = ["\(named.id) network log, \(shown.count) of \(matching.count) requests\(matching.count > shown.count ? " (older ones left out)" : "")"]
            lines += shown.map { line($0, frames: frames) }
            return AgentToolOutput(structured: .object(fields), text: lines.joined(separator: "\n"))
        }
    )

    static let networkBody = AgentTool(
        name: "network_body",
        description: "Read a response’s text body by network_log id, if the user turned body capture on.",
        inputSchema: schema(["tab": tabParam, "id": AgentParam.integer], required: ["tab", "id"]),
        output: { arguments, _, hub in
            let arguments = Arguments(value: arguments)
            let named = try hub.tab(named: try arguments.string("tab"))
            let id = try arguments.int("id", default: 0, in: 1...Int.max)
            try hub.checkDrivable(named)
            guard hub.capturesBodies else {
                throw AgentToolError(code: "bodies_off", message: "Response bodies are off. The user can turn on Capture response bodies in Lithium › Settings › Agents.")
            }
            guard let capture = hub.capture(in: named.tab) else { throw named.closedError }
            guard hub.usesResourceLoadDelegate, let index = capture.index(ofEntry: id) else {
                throw Arguments.invalid("\(named.id)’s network log has no request \(id): it keeps the requests of the page shown, the last \(TabCapture.maxEntries).")
            }
            let entry = capture.entries[index]
            var body = entry.body
            if body == nil {
                body = try await hub.documentBody(of: entry, in: named, capture: capture)
            }
            guard let body else { throw AgentToolError(code: "unsupported", message: noBody(entry)) }
            let cookies = await hub.cookieValues(of: named.tab, hosts: [URL(string: entry.url)?.host()].compactMap { $0 })
            let text = AgentRedaction.scrubbing(cookies, in: body.text)
            var fields: [String: JSONValue] = ["tab": .string(named.id), "id": .int(id), "url": .string(entry.url), "text": .string(text)]
            if let mime = entry.mimeType { fields["mimeType"] = .string(mime) }
            if body.truncated { fields["truncated"] = true }
            return AgentToolOutput(structured: .object(fields), text: "#\(id) \(entry.url)\(body.truncated ? " (cut at 256 KB)" : "")\n\(text)")
        }
    )

    static let consoleLog = AgentTool(
        name: "console_log",
        description: "List the page’s console messages and uncaught errors (secrets redacted).",
        inputSchema: schema([
            "tab": tabParam,
            "since": ["type": "integer", "description": "Only ids above this"],
            "level": ["type": "string", "enum": ["debug", "log", "info", "warn", "error"], "description": "This level and above"],
            "limit": ["type": "integer", "description": "Default 200, newest"],
        ], required: ["tab"]),
        output: { arguments, _, hub in
            let arguments = Arguments(value: arguments)
            let named = try hub.tab(named: try arguments.string("tab"))
            let since = try arguments.int("since", default: 0, in: 0...Int.max)
            let level = try arguments.choice("level", ["debug", "log", "info", "warn", "error"], default: "debug")
            let limit = try arguments.int("limit", default: 200, in: 1...500)
            try hub.checkDrivable(named)
            guard let capture = hub.capture(in: named.tab), let state = hub.tabs[named.tab.id] else { throw named.closedError }
            let frames = frameRefs(in: state)
            let matching = capture.messages.filter { $0.id > since && severity($0.level) >= severity(level) }
            let shown = Array(matching.suffix(limit))
            let hosts = [named.tab.url?.host()].compactMap { $0 } + shown.compactMap { $0.source.flatMap(URL.init(string:))?.host() }
            let cookies = await hub.cookieValues(of: named.tab, hosts: hosts)
            var fields: [String: JSONValue] = ["tab": .string(named.id)]
            fields["messages"] = .array(shown.map { message in
                var entry: [String: JSONValue] = ["id": .int(message.id), "level": .string(message.level), "text": .string(AgentRedaction.scrubbing(cookies, in: message.text))]
                if let kind = message.kind { entry["kind"] = .string(kind) }
                if let source = message.source { entry["source"] = .string(source) }
                if let line = message.line { entry["line"] = .int(line) }
                if let column = message.column { entry["column"] = .int(column) }
                if let frame = message.frameID { entry["frame"] = .string(frames[frame] ?? "child") }
                return .object(entry)
            })
            if matching.count > shown.count { fields["omitted"] = .int(matching.count - shown.count) }
            let lines = ["\(named.id) console, \(shown.count) of \(matching.count) messages"] + shown.map { message in
                var parts = ["#\(message.id)", message.kind ?? message.level, SnapshotNode.quoted(AgentRedaction.scrubbing(cookies, in: message.text))]
                if let source = message.source { parts.append("\(source)\(message.line.map { ":\($0)" } ?? "")") }
                if let frame = message.frameID { parts.append("in \(frames[frame] ?? "a child frame")") }
                return parts.joined(separator: " ")
            }
            return AgentToolOutput(structured: .object(fields), text: lines.joined(separator: "\n"))
        }
    )

    // MARK: Helpers

    private static let namedTypes: Set<String> = ["document", "fetch", "xhr", "script", "stylesheet", "image", "font", "media"]

    private static func severity(_ level: String) -> Int {
        switch level {
        case "debug": 0
        case "warn": 2
        case "error": 3
        default: 1
        }
    }

    /// WebKit's frame ids of the child frames that said hello, to their refs. Extension frames
    /// never say hello, and a frame Lithium never heard from is just "child".
    private static func frameRefs(in state: AgentTab) -> [UInt64: String] {
        var refs: [UInt64: String] = [:]
        for (token, info) in state.frames {
            if let id = ResourceLoadSpy.frameID(of: info) { refs[id] = state.frameRef(for: token) }
        }
        return refs
    }

    private static func json(_ entry: NetworkEntry, frames: [UInt64: String], headers: Bool) -> JSONValue {
        var fields: [String: JSONValue] = ["id": .int(entry.id), "type": .string(entry.type), "method": .string(entry.method), "url": .string(entry.url)]
        if let status = entry.status { fields["status"] = .int(status) }
        if let mime = entry.mimeType { fields["mimeType"] = .string(mime) }
        if let ended = entry.ended { fields["ms"] = .int(Int((ended - entry.started) / .milliseconds(1))) } else { fields["loading"] = true }
        if entry.fromCache { fields["fromCache"] = true }
        if let error = entry.error { fields["error"] = .string(error) }
        if let next = entry.redirectedTo { fields["redirectedTo"] = .string(next) }
        if let frame = entry.frameID { fields["frame"] = .string(frames[frame] ?? "child") }
        if entry.body != nil { fields["body"] = true }
        if headers {
            fields["requestHeaders"] = .object(entry.requestHeaders.mapValues(JSONValue.string))
            if let response = entry.responseHeaders { fields["responseHeaders"] = .object(response.mapValues(JSONValue.string)) }
        }
        return .object(fields)
    }

    private static func line(_ entry: NetworkEntry, frames: [UInt64: String]) -> String {
        var parts = ["#\(entry.id)", entry.method, entry.status.map(String.init) ?? "-", entry.type, entry.url]
        if let mime = entry.mimeType { parts.append(mime) }
        if let ended = entry.ended { parts.append("\(Int((ended - entry.started) / .milliseconds(1))) ms") } else { parts.append("loading") }
        if entry.fromCache { parts.append("cached") }
        if let next = entry.redirectedTo { parts.append("→ \(next)") }
        if let error = entry.error { parts.append("failed: \(SnapshotNode.quoted(error))") }
        if let frame = entry.frameID { parts.append("in \(frames[frame] ?? "a child frame")") }
        if entry.body != nil { parts.append("body") }
        return parts.joined(separator: " ")
    }

    private static let textual = /^(text\/(?!event-stream)|application\/([\w.+-]*\+)?(json|xml|javascript|x-www-form-urlencoded|graphql))/.ignoresCase()

    private static func isText(_ mimeType: String?) -> Bool {
        mimeType.map { $0.contains(textual) } ?? false
    }

    private static func noBody(_ entry: NetworkEntry) -> String {
        if entry.ended == nil { return "Request \(entry.id) is still loading." }
        if entry.error != nil { return "Request \(entry.id) failed, with no body." }
        if let mime = entry.mimeType, !isText(mime) { return "Request \(entry.id) is \(mime), not text: Lithium keeps text bodies only." }
        return "Lithium has no body for request \(entry.id) (\(entry.type)): it keeps those of fetch and XMLHttpRequest, from pages loaded after Capture response bodies was turned on, and the page’s own document."
    }

    /// The page's own document, which WebKit still holds, read when asked rather than kept.
    private func documentBody(of entry: NetworkEntry, in named: NamedTab, capture: TabCapture) async throws -> CapturedBody? {
        let latest = capture.entries.last { $0.type == "document" && $0.frameID == nil && $0.redirectedTo == nil }
        guard latest?.id == entry.id, entry.ended != nil, entry.error == nil, Self.isText(entry.mimeType),
              !named.tab.isAsleep, let webView = named.tab.loadedWebView, let data = await PDFReader.mainResourceData(of: webView) else { return nil }
        let truncated = data.count > TabCapture.maxBody
        let raw = String(decoding: data.prefix(TabCapture.maxBody), as: UTF8.self)
        return CapturedBody(text: await Task.detached { AgentRedaction.body(raw) }.value, truncated: truncated)
    }

    /// Cookie values of the hosts' sites, kept out of bodies and console messages: a page can
    /// log `document.cookie`, and a server can echo a cookie it got.
    private func cookieValues(of tab: Tab, hosts: [String]) async -> [String] {
        let sites = Set(hosts.map(SiteInfo.registrable))
        guard !sites.isEmpty else { return [] }
        let store = (tab.isAsleep ? nil : tab.loadedWebView)?.configuration.websiteDataStore ?? .default()
        let cookies = await store.httpCookieStore.allCookies()
        return cookies.filter { sites.contains(SiteInfo.registrable(String($0.domain.trimmingPrefix(".")))) }.map(\.value)
    }

    /// Without the resource load delegate: each frame's performance timeline, which has no
    /// headers, no request in flight, and no status in WebKits that leave it out.
    private func timelineLog(_ named: NamedTab, filter: String?, type: String?, minStatus: Int, limit: Int) async throws -> AgentToolOutput {
        struct Timeline: Decodable, DocumentReport {
            struct Item: Decodable {
                let url: String
                let type: String
                let start: Double
                let ms: Double
                let status: Int?
            }

            let token: String
            let entries: [Item]
        }
        return try await reading(named) { webView, deadline in
            let reports = try await askEveryFrame(named, webView, "resources", [:], Timeline.self, until: deadline)
            var matching: [JSONValue] = []
            var lines: [String] = []
            for (report, refs) in reports.reports {
                for item in report.entries {
                    let kind = Self.timelineTypes[item.type] ?? "other"
                    let url = AgentURLs.redacted(item.url)
                    guard filter.map({ url.lowercased().contains($0) }) ?? true, type.map({ $0 == kind }) ?? true, (item.status ?? 999) >= minStatus else { continue }
                    var fields: [String: JSONValue] = ["type": .string(kind), "url": .string(url), "ms": .int(Int(item.ms))]
                    if let status = item.status { fields["status"] = .int(status) }
                    if let frame = refs.frameRef { fields["frame"] = .string(frame) }
                    matching.append(.object(fields))
                    lines.append("\(item.status.map(String.init) ?? "-") \(kind) \(url) \(Int(item.ms)) ms\(refs.frameRef.map { " in \($0)" } ?? "")")
                }
            }
            var fields: [String: JSONValue] = ["tab": .string(named.id), "source": "performance-timeline", "entries": .array(Array(matching.suffix(limit)))]
            if matching.count > limit { fields["omitted"] = .int(matching.count - limit) }
            reports.note(&fields)
            let text = ["\(named.id) network log from the performance timeline: no headers, ids or requests still loading"] + lines.suffix(limit)
            return AgentToolOutput(structured: .object(fields), text: text.joined(separator: "\n"))
        }
    }

    /// The timeline's `initiatorType`, as the delegate's types name it.
    private static let timelineTypes = ["navigation": "document", "fetch": "fetch", "xmlhttprequest": "xhr", "script": "script", "link": "stylesheet", "img": "image", "image": "image", "video": "media", "audio": "media"]
}
