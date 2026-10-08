import AppKit
import WebKit

/// A `wait_for` condition `agent.js` evaluates inside the page.
enum DOMCondition {
    case element(ref: String, state: String)
    case text(String, present: Bool)

    /// Nil when the call waits for something else (load, url).
    /// `gone`: the text came as `textGone`, which waits for it to go.
    init?(ref: String?, text: String?, gone: Bool = false, arguments: Arguments) throws {
        if let ref {
            guard AgentTab.isRef(ref) else { throw Arguments.invalid("ref must be a ref from snapshot, such as e9 or f2:e7.") }
            self = .element(ref: ref, state: try arguments.choice("state", ["visible", "hidden", "enabled", "attached", "detached"], default: "visible"))
        } else if let text {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Arguments.invalid("text must not be empty.") }
            if gone, arguments.value["present"] != nil { throw Arguments.invalid("textGone takes no present: it waits for the text to go.") }
            self = .text(text.split(whereSeparator: \.isWhitespace).joined(separator: " "), present: gone ? false : try arguments.bool("present", default: true))
        } else {
            return nil
        }
    }
}

extension AgentHub {
    static let readTools: [AgentTool] = [snapshotTool, readText, linksTool, formsTool, findText, elementInfo, screenshotTool, pdfTool]

    /// A read waits its turn and runs within this; a page kept busy by a script answers `timeout`.
    static let readTimeout: Duration = .seconds(10)
    /// How much longer than the main frame a child frame may take to answer a read.
    static let frameTimeout: Duration = .seconds(2)

    private static let refParam = AgentParam.ref
    private static let tabParam = AgentParam.tab

    // MARK: Tools

    static let snapshotTool = AgentTool(
        name: "snapshot",
        description: "List the page’s elements with refs, roles, names, values, states and boxes.",
        inputSchema: schema([
            "tab": tabParam,
            "scope": ["type": "string", "enum": ["viewport", "page"], "description": "Default viewport (and one screen below)"],
            "since": ["type": "integer", "description": "A seq: only what changed since"],
            "format": ["type": "string", "enum": ["text", "json"]],
            "maxNodes": ["type": "integer", "description": "Default 300"],
        ], required: ["tab"]),
        output: { arguments, session, hub in
            let arguments = Arguments(value: arguments)
            let named = try hub.tab(named: try arguments.string("tab"))
            let scope = try arguments.choice("scope", ["viewport", "page"], default: "viewport")
            let format = try arguments.choice("format", ["text", "json"], default: "text")
            let maxNodes = try arguments.int("maxNodes", default: 300, in: 1...2000)
            let since = try arguments.value["since"].map { _ in try arguments.int("since", default: 0, in: 0...Int.max) }
            // A page paused under a dialog can't be read: the snapshot says what waits for an answer.
            if let dialog = hub.tabs[named.tab.id]?.dialog { return hub.dialogSnapshot(named, dialog) }
            do {
                return addingFailedScripts(to: try await snapshot(named, scope: scope, format: format, maxNodes: maxNodes, since: since, session: session, hub: hub), of: named, hub: hub)
            } catch let error as AgentToolError where error.code == "dialog_open" {
                guard let dialog = hub.tabs[named.tab.id]?.dialog else { throw error }
                return hub.dialogSnapshot(named, dialog)
            }
        }
    )

    /// The page's failed scripts, when it has any, in the result and as the text's last line.
    private static func addingFailedScripts(to output: AgentToolOutput, of named: NamedTab, hub: AgentHub) -> AgentToolOutput {
        guard let failed = hub.failedScripts(in: named.tab), var fields = output.structured.object else { return output }
        var output = output
        fields["failedScripts"] = failed
        if let text = output.text {
            let line = (hub.tabs[named.tab.id]?.capture?.failedScripts ?? []).prefix(5).map(\.failure).joined(separator: ", ")
            output.text = "\(text)\nfailed scripts: \(line)"
            if fields["text"] != nil { fields["text"] = output.text.map(JSONValue.string) }
        }
        output.structured = .object(fields)
        return output
    }

    private static func snapshot(_ named: NamedTab, scope: String, format: String, maxNodes: Int, since: Int?, session: MCPSession, hub: AgentHub) async throws -> AgentToolOutput {
        try await hub.reading(named) { webView, deadline in
            guard let state = hub.agentTab(for: named.tab) else { throw named.closedError }
            if named.tab.pdf != nil { throw AgentHub.pdfShown(named, use: "read_text or screenshot") }
            var snapshot = try await hub.snapshot(of: named, in: webView, scope: scope, maxNodes: maxNodes, until: deadline)
            let previous = state.record(&snapshot, session: session.id)
            if let since, let previous, previous.seq == since, previous.document == snapshot.document {
                let diff = snapshot.diff(since: previous)
                guard format == "text" else { return AgentToolOutput(structured: diff) }
                return AgentToolOutput(structured: AgentHub.textResult(snapshot, diff["text"]?.string ?? "", since: since), text: diff["text"]?.string)
            }
            guard format == "text" else { return AgentToolOutput(structured: snapshot.json) }
            return AgentToolOutput(structured: AgentHub.textResult(snapshot, snapshot.text, since: nil), text: snapshot.text)
        }
    }

    static let readText = AgentTool(
        name: "read_text",
        description: "Read the page’s visible text: its main content, the whole page (main: false) or one element.",
        inputSchema: schema([
            "tab": tabParam,
            "ref": refParam,
            "format": ["type": "string", "enum": ["text", "markdown"]],
            "main": AgentParam.flag,
            "maxChars": ["type": "integer", "description": "Default 50000"],
        ], required: ["tab"]),
        output: { arguments, _, hub in
            let arguments = Arguments(value: arguments)
            let named = try hub.tab(named: try arguments.string("tab"))
            let ref = try arguments.optionalString("ref")
            if let ref, !AgentTab.isRef(ref) { throw Arguments.invalid("ref must be a ref from snapshot, such as e9 or f2:e7.") }
            let format = try arguments.choice("format", ["text", "markdown"], default: "text")
            let main = try arguments.bool("main", default: true)
            let maxChars = try arguments.int("maxChars", default: 50_000, in: 1...200_000)
            return try await hub.reading(named) { webView, deadline in
                if let pdf = named.tab.pdf {
                    guard let text = pdf.document?.string else {
                        throw AgentToolError(code: "unsupported", message: "\(named.id) shows a PDF that is locked or still loading.")
                    }
                    return AgentHub.textOutput(["tab": .string(named.id), "url": .string(named.tab.url?.absoluteString ?? ""), "title": .string(pdf.title)], text: text, maxChars: maxChars)
                }
                try await hub.refuseChallenge(in: named, webView, until: deadline)
                var target = FrameTarget.main
                var args: [String: Any] = ["main": main, "format": format, "maxChars": maxChars]
                if let ref {
                    let (address, frame) = try await hub.element(ref, in: named, webView, until: deadline)
                    target = frame
                    args["id"] = address.id
                    args["token"] = address.document
                }
                let data = try await hub.ask(named, webView, target, "readText", args, until: deadline)
                let read = try PageProbe.decode(ReadReport.self, from: data)
                if read.gone == true, let ref { throw await hub.staleRef(ref, in: named, webView, until: deadline) }
                return AgentHub.textOutput(["tab": .string(named.id), "url": .string(read.url ?? ""), "title": .string(read.title ?? "")], text: read.text ?? "", maxChars: maxChars, truncated: read.truncated == true)
            }
        }
    )

    static let linksTool = AgentTool(
        name: "links",
        description: "List the page’s visible links with refs, text and URLs.",
        inputSchema: schema([
            "tab": tabParam,
            "filter": ["type": "string", "description": "Part of the text or URL"],
        ], required: ["tab"])
    ) { arguments, _, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        let filter = try arguments.optionalString("filter") ?? ""
        return try await hub.reading(named) { webView, deadline in
            if named.tab.pdf != nil { throw AgentHub.pdfShown(named, use: "read_text") }
            try await hub.refuseChallenge(in: named, webView, until: deadline)
            var links: [JSONValue] = []
            let frames = try await hub.askEveryFrame(named, webView, "links", ["filter": filter], LinksReport.self, until: deadline)
            for (report, frame) in frames.reports {
                for link in report.links {
                    var fields: [String: JSONValue] = ["ref": .string(frame.ref(link.id)), "text": .string(link.text), "href": .string(link.href)]
                    if let ref = frame.frameRef { fields["in"] = .string(ref) }
                    links.append(.object(fields))
                }
            }
            var fields: [String: JSONValue] = ["tab": .string(named.id), "count": .int(links.count), "links": .array(links)]
            frames.note(&fields)
            return .object(fields)
        }
    }

    static let formsTool = AgentTool(
        name: "forms",
        description: "List the page’s forms with their fields (refs, names, values, options) and submit buttons.",
        inputSchema: schema(["tab": tabParam], required: ["tab"])
    ) { arguments, _, hub in
        let named = try hub.tab(named: try Arguments(value: arguments).string("tab"))
        return try await hub.reading(named) { webView, deadline in
            if named.tab.pdf != nil { throw AgentHub.pdfShown(named, use: "read_text") }
            try await hub.refuseChallenge(in: named, webView, until: deadline)
            var forms: [JSONValue] = []
            var loose: [JSONValue] = []
            let frames = try await hub.askEveryFrame(named, webView, "forms", [:], FormsReport.self, until: deadline)
            for (report, frame) in frames.reports {
                for form in report.forms {
                    var fields: [String: JSONValue] = [
                        "ref": .string(frame.ref(form.id)), "name": .string(form.name), "action": .string(form.action), "method": .string(form.method),
                        "fields": .array(form.fields.map { $0.json(frame) }), "submits": .array(form.submits.map { .string(frame.ref($0)) }),
                    ]
                    if let ref = frame.frameRef { fields["in"] = .string(ref) }
                    forms.append(.object(fields))
                }
                loose += report.loose.map { $0.json(frame) }
            }
            var fields: [String: JSONValue] = ["tab": .string(named.id), "forms": .array(forms), "fieldsOutsideForms": .array(loose)]
            frames.note(&fields)
            return .object(fields)
        }
    }

    static let findText = AgentTool(
        name: "find_text",
        description: "Find visible text: up to 50 matches, each with the ref of its link, button or block.",
        inputSchema: schema([
            "tab": tabParam,
            "text": AgentParam.text,
            "caseSensitive": AgentParam.flag,
        ], required: ["tab", "text"])
    ) { arguments, _, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        // The page's lines have their spaces collapsed, so the text has too, as wait_for's.
        let text = try arguments.string("text").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { throw Arguments.invalid("text must not be empty.") }
        let caseSensitive = try arguments.bool("caseSensitive", default: false)
        return try await hub.reading(named) { webView, deadline in
            if named.tab.pdf != nil { throw AgentHub.pdfShown(named, use: "read_text") }
            try await hub.refuseChallenge(in: named, webView, until: deadline)
            var count = 0
            var matches: [JSONValue] = []
            let args: [String: Any] = ["text": text, "caseSensitive": caseSensitive, "limit": 50]
            let frames = try await hub.askEveryFrame(named, webView, "find", args, FindReport.self, until: deadline)
            for (report, frame) in frames.reports {
                count += report.count
                for match in report.matches where matches.count < 50 {
                    var fields: [String: JSONValue] = ["ref": .string(frame.ref(match.id)), "context": .string(match.context)]
                    if let role = match.role { fields["role"] = .string(role) }
                    if let ref = frame.frameRef { fields["in"] = .string(ref) }
                    matches.append(.object(fields))
                }
            }
            var fields: [String: JSONValue] = ["tab": .string(named.id), "count": .int(count), "matches": .array(matches)]
            frames.note(&fields)
            return .object(fields)
        }
    }

    static let elementInfo = AgentTool(
        name: "element_info",
        description: "Tell where an element is, whether it is visible and in view, and what covers it.",
        inputSchema: schema(["tab": tabParam, "ref": refParam], required: ["tab", "ref"])
    ) { arguments, _, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        let ref = try arguments.string("ref")
        guard AgentTab.isRef(ref) else { throw Arguments.invalid("ref must be a ref from snapshot, such as e9 or f2:e7.") }
        return try await hub.reading(named) { webView, deadline in
            if named.tab.pdf != nil { throw AgentHub.pdfShown(named, use: "read_text or screenshot") }
            let (address, frame) = try await hub.element(ref, in: named, webView, until: deadline)
            let data = try await hub.ask(named, webView, frame, "info", ["id": address.id, "token": address.document], until: deadline)
            let info = try PageProbe.decode(ElementReport.self, from: data)
            guard info.gone != true, let box = info.box else { throw await hub.staleRef(ref, in: named, webView, until: deadline) }
            let layout = try await hub.layout(of: named, webView, until: deadline, placing: address)
            guard let placement = layout.placement(ofDocument: address.document), let state = hub.agentTab(for: named.tab) else {
                throw AgentToolError(code: "frame_gone", message: "The frame \(ref) is in has gone. Call snapshot for current refs.")
            }
            let css = placement.place(box)
            let view = AgentScreenshot.viewRect(css, viewport: layout.main.viewport, zoom: webView.pageZoom)
            var boxes: [String: JSONValue] = ["css": AgentHub.rect(css), "view": AgentHub.rect(view)]
            if let window = webView.window {
                let inWindow = webView.convert(view, to: nil)
                boxes["window"] = AgentHub.rect(inWindow)
                let onScreen = window.convertToScreen(inWindow)
                if window.isVisible, NSScreen.screens.contains(where: { $0.frame.intersects(onScreen) }) { boxes["screen"] = AgentHub.rect(onScreen) }
            }
            var fields: [String: JSONValue] = [
                "tab": .string(named.id), "ref": .string(ref), "role": .string(info.role ?? ""), "name": .string(info.name ?? ""),
                "visible": .bool(info.visible == true), "inViewport": .bool(info.inViewport == true && css.intersects(placement.clip)), "box": .object(boxes),
            ]
            if let hidden = info.hidden { fields["hidden"] = .string(hidden) }
            if let guardKind = info.guard { fields["guard"] = .string(guardKind) }
            if let covered = info.coveredBy {
                let frameRef = address.document == state.mainDocument ? nil : state.frameRef(for: address.document)
                let coverRef = state.ref(for: ElementAddress(document: address.document, id: covered.id))
                var cover: [String: JSONValue] = ["ref": .string(coverRef), "element": .string(covered.tag), "text": .string(covered.text)]
                if covered.extension == true { cover["extensionUI"] = true }
                if let frameRef { cover["in"] = .string(frameRef) }
                fields["coveredBy"] = .object(cover)
            }
            return .object(fields)
        }
    }

    static let screenshotTool = AgentTool(
        name: "screenshot",
        description: "Take a screenshot of the viewport, an element (ref) or the whole page; secret fields are masked.",
        inputSchema: schema([
            "tab": tabParam,
            "ref": refParam,
            "fullPage": AgentParam.flag,
            "format": ["type": "string", "enum": ["png", "jpeg"]],
            "maxWidth": ["type": "integer", "description": "Default 1600 px"],
        ], required: ["tab"]),
        output: { arguments, _, hub in
            let arguments = Arguments(value: arguments)
            let named = try hub.tab(named: try arguments.string("tab"))
            let ref = try arguments.optionalString("ref")
            if let ref, !AgentTab.isRef(ref) { throw Arguments.invalid("ref must be a ref from snapshot, such as e9 or f2:e7.") }
            let fullPage = try arguments.bool("fullPage", default: false)
            if fullPage, ref != nil { throw Arguments.invalid("Give ref or fullPage, not both.") }
            let jpeg = try arguments.choice("format", ["png", "jpeg"], default: "png") == "jpeg"
            let maxWidth = try arguments.int("maxWidth", default: 1600, in: 100...4000)
            return try await hub.reading(named) { webView, deadline in
                try await hub.screenshot(named, webView, ref: ref, fullPage: fullPage, jpeg: jpeg, maxWidth: maxWidth, until: deadline)
            }
        }
    )

    static let pdfTool = AgentTool(
        name: "pdf",
        description: "Save the whole page as a PDF; secret fields are masked.",
        inputSchema: schema(["tab": tabParam], required: ["tab"]),
        output: { arguments, _, hub in
            let named = try hub.tab(named: try Arguments(value: arguments).string("tab"))
            return try await hub.reading(named) { webView, deadline in
                let data: Data
                var fields: [String: JSONValue] = ["tab": .string(named.id), "maskedRegions": 0]
                if let pdf = named.tab.pdf {
                    guard let document = pdf.document?.dataRepresentation() else {
                        throw AgentToolError(code: "unsupported", message: "\(named.id) shows a PDF that is locked or still loading.")
                    }
                    data = document
                } else {
                    let (layout, page) = try await hub.masked(named, webView, from: try await hub.layout(of: named, webView, until: deadline), until: deadline) {
                        try await webView.pdf(configuration: WKPDFConfiguration())
                    }
                    let masks = AgentHub.documentMasks(try AgentHub.masks(layout, of: named), layout.main.viewport)
                    fields["maskedRegions"] = .int(masks.count)
                    if masks.isEmpty {
                        data = page
                    } else {
                        guard let size = AgentScreenshot.pdfPageSize(page) else {
                            throw AgentToolError(code: "unsupported", message: "Lithium couldn’t make a PDF of \(named.id).")
                        }
                        guard size.height <= AgentScreenshot.maxPDFLength else {
                            throw AgentToolError(code: "unsupported", message: "\(named.id) is too long to save as a PDF with its secret fields masked. Use screenshot instead.")
                        }
                        let inPoints = masks.map { AgentHub.scaled($0, by: size.width / max(1, layout.main.viewport.pw)) }
                        guard let flat = await Task.detached(priority: .userInitiated, operation: { AgentScreenshot.maskedPDF(page, masks: inPoints) }).value else {
                            throw AgentToolError(code: "unsupported", message: "Lithium couldn’t make a PDF of \(named.id).")
                        }
                        data = flat.data
                        fields["pages"] = .int(flat.pages)
                    }
                }
                fields["bytes"] = .int(data.count)
                let resource: JSONValue = [
                    "type": "resource",
                    "resource": ["uri": .string("lithium-agent://\(named.id)/page.pdf"), "mimeType": "application/pdf", "blob": .string(data.base64EncodedString())],
                ]
                return AgentToolOutput(structured: .object(fields), text: "PDF of \(named.id), \(data.count) bytes.", attachments: [resource])
            }
        }
    )

    // MARK: Reading

    /// Runs a read in its turn in the tab, within `readTimeout`. A sleeping tab wakes first, onto
    /// a page agents may open.
    func reading<Value>(_ named: NamedTab, _ body: (_ webView: WKWebView, _ deadline: ContinuousClock.Instant) async throws -> Value) async throws -> Value {
        let deadline = ContinuousClock.now + AgentHub.readTimeout
        return try await exclusive(named, until: deadline, timeout: AgentHub.readTimeout) {
            try checkDrivable(named)
            let tab = named.tab
            if tab.isAsleep {
                try await checkWakeable(named, until: deadline)
                _ = try await navigation(in: named, wait: .domcontentloaded, deadline: deadline, timeout: AgentHub.readTimeout, landedWithinPage: nil) { tab.wake() }
            }
            return try await body(sizedWebView(of: tab), deadline)
        }
    }

    /// The tab's web view, sized. One that was never in the window has no size, and its page
    /// lays out in an empty viewport: it gets the size of the page area the user sees.
    func sizedWebView(of tab: Tab) -> WKWebView {
        let webView = tab.webView
        if webView.superview == nil, webView.frame.width < 1 || webView.frame.height < 1 {
            webView.frame = CGRect(origin: .zero, size: pageAreaSize)
        }
        fitViewport(of: webView, in: tab)
        return webView
    }

    /// A tab out of the user's window keeps the size `resize` gave its page, in the stage too,
    /// where the other pages follow the stage's size.
    func fitViewport(of webView: WKWebView, in tab: Tab) {
        guard webView.userWindow == nil, let size = tabs[tab.id]?.viewport else { return }
        webView.autoresizingMask = []
        if webView.frame.size != size { webView.setFrameSize(size) }
    }

    /// Hooked from `Tab.didComeIntoView`: the user's window gives the page its own size.
    func cameIntoView(_ tab: Tab) {
        tabs[tab.id]?.viewport = nil
    }

    /// Starts a call to `agent.js`; its answer comes in the returned box.
    func start(_ webView: WKWebView, _ target: FrameTarget, _ operation: String, _ arguments: [String: Any]) -> PageAnswer<Data> {
        let answer = PageAnswer<Data>()
        Task {
            do { answer.result = .success(try await PageProbe.run(operation, arguments, in: target, of: webView)) } catch { answer.result = .failure(error) }
        }
        return answer
    }

    /// The answer, or nil when the frame is gone or the script failed. A page kept busy past the
    /// deadline answers `timeout`; the tab closing, the user navigating it, or `stop` end the wait.
    private func answer(_ answer: PageAnswer<Data>, from named: NamedTab, until deadline: ContinuousClock.Instant) async throws -> Data? {
        guard let result = try await watch(named, until: deadline, { answer.result }) else {
            throw AgentToolError(code: "timeout", message: "\(named.id)’s page didn’t answer within \(Int(AgentHub.readTimeout / .seconds(1))) s: a script may be keeping it busy.")
        }
        return try? result.get()
    }

    /// One frame's answer; a frame that is gone is `frame_gone`.
    func ask(_ named: NamedTab, _ webView: WKWebView, _ target: FrameTarget, _ operation: String, _ arguments: [String: Any], until deadline: ContinuousClock.Instant) async throws -> Data {
        guard let data = try await answer(start(webView, target, operation, arguments), from: named, until: deadline) else {
            throw AgentHub.pageChanged(named)
        }
        return data
    }

    /// A frame's answer and how to name what it holds.
    struct FrameRefs {
        let state: AgentTab
        let document: String
        let frameRef: String?

        @MainActor func ref(_ id: Int) -> String {
            state.ref(for: ElementAddress(document: document, id: id))
        }
    }

    /// Every frame's answer, and how many child frames didn't answer in time.
    struct FrameReports<Report> {
        var reports: [(Report, FrameRefs)]
        var late = 0

        /// Added to a result that lists what every frame holds, so the agent knows it's partial.
        func note(_ fields: inout [String: JSONValue]) {
            if late > 0 { fields["framesNotRead"] = .int(late) }
        }
    }

    /// Asks the main frame and every child frame that said hello, side by side. The main frame
    /// must answer; child frames that are gone or late (`childAnswers`) are left out.
    func askEveryFrame<Report: Decodable & DocumentReport>(_ named: NamedTab, _ webView: WKWebView, _ operation: String, _ arguments: [String: Any], _ type: Report.Type, until deadline: ContinuousClock.Instant, patient: Bool = false) async throws -> FrameReports<Report> {
        guard let state = agentTab(for: named.tab) else { throw named.closedError }
        let hellos = state.hellos
        let main = start(webView, .main, operation, arguments)
        let children = state.frames.map { token, info in (token: token, answer: start(webView, .child(info), operation, arguments)) }
        let report = try PageProbe.decode(type, from: try await ask(named, webView, .main, operation, arguments, until: deadline, answered: main))
        guard state.mainFrameAnswered(report.token, asked: hellos) else { throw AgentHub.pageChanged(named) }
        var reports = FrameReports(reports: [(report, FrameRefs(state: state, document: report.token, frameRef: nil))])
        let (answers, late) = try await childAnswers(children, of: state, from: named, until: deadline, patient: patient)
        reports.late = late
        for (token, data) in answers {
            guard let data, let child = try? PageProbe.decode(type, from: data) else {
                state.childFrame(token, answeredAs: nil)
                continue
            }
            state.childFrame(token, answeredAs: child.token)
            guard !reports.reports.contains(where: { $0.1.document == child.token }) else { continue }
            reports.reports.append((child, FrameRefs(state: state, document: child.token, frameRef: state.frameRef(for: child.token))))
        }
        return reports
    }

    /// The child frames' answers, asked side by side with the main frame's. Once the main frame
    /// answered they get `frameTimeout` more; a frame still busy then is late and left out, and
    /// pictures paint it over whole. The tab closing, the user navigating it or `stop` end the
    /// wait as they end any other. Frames of a page the main frame no longer shows are dropped.
    /// `patient` gives them the whole deadline. Nil data: the frame is gone or its script failed.
    func childAnswers(_ children: [(token: String, answer: PageAnswer<Data>)], of state: AgentTab, from named: NamedTab, until deadline: ContinuousClock.Instant, patient: Bool = false) async throws -> (answers: [(token: String, data: Data?)], late: Int) {
        let budget = patient ? deadline : min(deadline, .now + AgentHub.frameTimeout)
        var answers: [(token: String, data: Data?)] = []
        var late = 0
        for (token, pending) in children where state.frames[token] != nil {
            guard let result = try await watch(named, until: budget, { pending.result }) else {
                late += 1
                continue
            }
            answers.append((token, try? result.get()))
        }
        return (answers, late)
    }

    private func ask(_ named: NamedTab, _ webView: WKWebView, _ target: FrameTarget, _ operation: String, _ arguments: [String: Any], until deadline: ContinuousClock.Instant, answered pending: PageAnswer<Data>) async throws -> Data {
        guard let data = try await answer(pending, from: named, until: deadline) else {
            throw AgentHub.pageChanged(named)
        }
        return data
    }

    /// The page as the snapshot shows it, from every frame's report, put together. A frame that
    /// saw nothing change since its last report answers without walking its document.
    func snapshot(of named: NamedTab, in webView: WKWebView, scope: String, maxNodes: Int, until deadline: ContinuousClock.Instant) async throws -> PageSnapshot {
        guard let state = agentTab(for: named.tab) else { throw named.closedError }
        let arguments = { (token: String?) -> [String: Any] in
            var fields: [String: Any] = ["scope": scope, "key": scope]
            if let token, let cached = state.reports[token], cached.scope == scope, let generation = cached.report.gen {
                fields["since"] = generation
                fields["of"] = token
            }
            return fields
        }
        let hellos = state.hellos
        let main = start(webView, .main, "snapshot", arguments(state.mainDocument))
        let children = state.frames.map { token, info in (token: token, answer: start(webView, .child(info), "snapshot", arguments(token))) }
        let full = { (data: Data) throws -> FrameReport in
            let report = try PageProbe.decode(FrameReport.self, from: data)
            guard report.unchanged == true else {
                state.reports[report.token] = (scope, report)
                return report
            }
            guard var cached = state.reports[report.token]?.report else { throw PageProbe.Failure() }
            // The frame's rank among its parent's frames changes when the parent adds one before it.
            cached.path = report.path
            return cached
        }
        let mainReport = try full(try await ask(named, webView, .main, "snapshot", [:], until: deadline, answered: main))
        guard state.mainFrameAnswered(mainReport.token, asked: hellos) else { throw AgentHub.pageChanged(named) }
        var reports: [FrameReport] = []
        var origins: [String: String] = [:]
        for (token, data) in try await childAnswers(children, of: state, from: named, until: deadline).answers {
            guard let data, let report = try? full(data) else {
                state.childFrame(token, answeredAs: nil)
                continue
            }
            state.childFrame(token, answeredAs: report.token)
            // A frame's first document (about:blank, with its parent's origin) answers as the one it shows now.
            guard origins[report.token] == nil, let origin = state.frames[report.token]?.securityOrigin else { continue }
            origins[report.token] = "\(origin.protocol)://\(origin.host)\(origin.port == 0 ? "" : ":\(origin.port)")"
            reports.append(report)
        }
        var snapshot = state.compose(tab: named.id, main: mainReport, children: reports, origins: origins, zoom: webView.pageZoom, maxNodes: maxNodes, providers: paymentProviders)
        snapshot.view = "\(scope) \(maxNodes)"
        if state.challenge != snapshot.challenge { state.challenge = snapshot.challenge }
        return snapshot
    }

    /// What navigation tools and `wait_for` add: what the viewport shows now, as a diff from this
    /// session's last default snapshot of the tab, or whole when there was none or it was another page.
    /// Within the call's deadline, and a few seconds at most. Left out, with a note, rather than
    /// failing the call, when the page doesn't answer; the tab closing, the user taking it back
    /// or `stop` fail the call, as they would have a moment earlier.
    func addingDiff(to page: JSONValue, of named: NamedTab, for session: MCPSession, if wanted: Bool, until deadline: ContinuousClock.Instant) async throws -> JSONValue {
        guard wanted, var fields = page.object, named.tab.pdf == nil, !named.tab.isAsleep, named.tab.loadedWebView != nil,
              !AgentURLs.isBlocked(named.tab.url), let state = agentTab(for: named.tab) else { return page }
        let webView = sizedWebView(of: named.tab)
        var snapshot: PageSnapshot
        do {
            snapshot = try await self.snapshot(of: named, in: webView, scope: "viewport", maxNodes: 300, until: min(deadline, .now + .seconds(3)))
        } catch let error as AgentToolError where ["tab_closed", "user_interrupted", "stopped"].contains(error.code) {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let late = (error as? AgentToolError)?.code == "timeout"
            fields["diffNote"] = .string("No diff: the page \(late ? "didn’t answer in time" : "changed while it was read"). Call snapshot.")
            return .object(fields)
        }
        let previous = state.record(&snapshot, session: session.id)
        if let previous, previous.document == snapshot.document {
            fields["diff"] = snapshot.diff(since: previous)["text"] ?? .null
        } else {
            fields["diff"] = .string(snapshot.text)
        }
        if let challenge = snapshot.challenge { fields["challenge"] = challenge.json }
        return .object(fields)
    }

    /// Reads that a challenge page would only mislead answer `challenge_requires_user` instead:
    /// Lithium doesn't solve CAPTCHAs or bot checks, the user does. A widget on a page (reCAPTCHA
    /// on a sign-in form) leaves the page readable; either shows in the indicator.
    func refuseChallenge(in named: NamedTab, _ webView: WKWebView, until deadline: ContinuousClock.Instant) async throws {
        guard let state = agentTab(for: named.tab) else { throw named.closedError }
        let report = try PageProbe.decode(ChallengeReport.self, from: try await ask(named, webView, .main, "challenge", [:], until: deadline))
        // Only frames the user can see, as in the snapshot: invisible checks (a 0x0 DataDome
        // frame, an invisible Turnstile) sit on many pages that need nothing from the user.
        let challenge = report.page.map { AgentChallenge(kind: $0, page: true) }
            ?? report.frames.lazy.compactMap(AgentChallenge.kind(of:)).first.map { AgentChallenge(kind: $0, page: AgentChallenge.pageKinds.contains($0)) }
        if state.challenge != challenge { state.challenge = challenge }
        guard let challenge, challenge.page else { return }
        throw AgentToolError(
            code: "challenge_requires_user",
            message: "\(named.id) shows a \(challenge.label). Lithium doesn’t solve these: ask the user to complete it in Lithium, then call wait_for (text, url or load) and read again."
        )
    }

    /// The element a ref names and the frame to ask about it.
    func element(_ ref: String, in named: NamedTab, _ webView: WKWebView, until deadline: ContinuousClock.Instant) async throws -> (ElementAddress, FrameTarget) {
        guard let state = agentTab(for: named.tab), let address = state.address(of: ref) else {
            throw AgentToolError(code: "stale_ref", message: "\(named.id) has no element \(ref). Call snapshot for current refs.")
        }
        guard let target = state.target(for: address.document) else {
            if ref.hasPrefix("f") {
                throw AgentToolError(code: "frame_gone", message: "The frame \(ref) is in has gone. Call snapshot for current refs.")
            }
            throw await staleRef(ref, in: named, webView, until: deadline)
        }
        return (address, target)
    }

    /// `stale_ref`, naming what the ref was and, when one with the same role and name sits near
    /// where it was, the element that took its place.
    func staleRef(_ ref: String, in named: NamedTab, _ webView: WKWebView, until deadline: ContinuousClock.Instant) async -> AgentToolError {
        guard let old = tabs[named.tab.id]?.shown[ref] else { return AgentToolError(code: "stale_ref", message: "\(ref) is no longer on \(named.id)’s page. Call snapshot for current refs.") }
        var message = "\(ref) \(old.role) \(SnapshotNode.quoted(old.name ?? "")) was removed."
        if let fresh = try? await snapshot(of: named, in: webView, scope: "page", maxNodes: 2000, until: deadline) {
            let distance = { (node: SnapshotNode) in abs(node.box[0] - old.box[0]) + abs(node.box[1] - old.box[1]) }
            let match = fresh.nodes.filter { $0.ref != ref && $0.role == old.role && $0.name == old.name && distance($0) <= 200 }.min { distance($0) < distance($1) }
            if let match { message += " \(match.ref) \(match.role) \(SnapshotNode.quoted(match.name ?? "")) is in its place." }
        }
        return AgentToolError(code: "stale_ref", message: message + " Call snapshot for current refs.")
    }

    /// Where every frame sits, and what to mask in it. `placing` an element: its box is read with
    /// the masks, and when a frame too slow for `frameTimeout` leaves it unplaced, the frames get
    /// the read's whole deadline, as the element's own read just had; only a frame that went away
    /// is `frame_gone`.
    func layout(of named: NamedTab, _ webView: WKWebView, until deadline: ContinuousClock.Instant, placing element: ElementAddress? = nil) async throws -> FrameLayout {
        let arguments: [String: Any] = element.map { ["element": $0.id, "of": $0.document] } ?? [:]
        let read = { (patient: Bool) in
            let frames = try await self.askEveryFrame(named, webView, "masks", arguments, MaskReport.self, until: deadline, patient: patient)
            return (FrameLayout(main: frames.reports[0].0, children: frames.reports.dropFirst().map(\.0), providers: self.paymentProviders), frames.late)
        }
        let (layout, late) = try await read(false)
        guard let element, late > 0, layout.placement(ofDocument: element.document) == nil else { return layout }
        return try await read(true).0
    }

    /// What `take` captures, with the layout its masks come from. Every frame's scroll and masks
    /// are read before and after it; a page that scrolled meanwhile is read and captured again,
    /// three times at most, then refused: masks read at another scroll would miss the fields. A
    /// field that moved, showed or went meanwhile (an animation) is captured again too, and on
    /// the last try painted over at both places and between.
    func masked<Value>(_ named: NamedTab, _ webView: WKWebView, from layout: FrameLayout, placing element: ElementAddress? = nil, until deadline: ContinuousClock.Instant, _ take: () async throws -> Value) async throws -> (layout: FrameLayout, value: Value) {
        var layout = layout
        for attempt in 1...3 {
            let value = try await take()
            let after = try await self.layout(of: named, webView, until: deadline, placing: element)
            if after.keepsScroll(of: layout) {
                if after.masks == layout.masks { return (layout, value) }
                if attempt == 3 { return (layout.masking(after), value) }
            }
            layout = after
        }
        throw AgentToolError(code: "frame_gone", message: "\(named.id)’s page kept scrolling while it was pictured, so its password and card fields couldn’t be painted over. Try again.")
    }

    private static func pageChanged(_ named: NamedTab) -> AgentToolError {
        AgentToolError(code: "frame_gone", message: "\(named.id)’s page changed while it was read. Try again.")
    }

    /// What a picture of the page paints over, in top-level viewport CSS pixels.
    private static func masks(_ layout: FrameLayout, of named: NamedTab) throws -> [CGRect] {
        guard let masks = layout.masks else {
            throw AgentToolError(code: "unsupported", message: "\(named.id) has a frame Lithium can’t place (in a shadow root or an embed), so it can’t paint over the password and card fields in it. Use snapshot or read_text.")
        }
        return masks
    }

    // MARK: Waiting

    /// Waits in the page for an element's state or for text, within the call's deadline. A text
    /// wait reads the main frame and the same-origin frames in it, and goes on in the next
    /// document when the main frame navigates. Text gone answers a note when frames of another
    /// origin, which it can't read, may still hold it.
    @discardableResult
    func wait(for condition: DOMCondition, in named: NamedTab, deadline: ContinuousClock.Instant, timeout: Duration) async throws -> String? {
        let tab = named.tab
        if tab.isAsleep { _ = try await navigation(in: named, wait: .domcontentloaded, deadline: deadline, timeout: timeout, landedWithinPage: nil) { tab.wake() } }
        if tab.pdf != nil { throw AgentHub.pdfShown(named, use: "wait_for load or url") }
        let webView = sizedWebView(of: tab)
        let remaining = { max(1, Int((deadline - .now) / .milliseconds(1))) }
        switch condition {
        case .element(let ref, let state):
            let gone = state == "detached" || state == "hidden"
            let address: ElementAddress
            let target: FrameTarget
            do {
                (address, target) = try await element(ref, in: named, webView, until: deadline)
            } catch let error as AgentToolError where gone && ["stale_ref", "frame_gone"].contains(error.code) {
                return nil
            }
            let key = Self.waitKey()
            let pending = start(webView, target, "wait", ["id": address.id, "token": address.document, "state": state, "timeoutMs": remaining(), "key": key])
            // The page's own timer would keep it checking long after the call ended.
            defer { if pending.result == nil { _ = start(webView, target, "cancelWait", ["key": key]) } }
            let commits = tab.commits
            // A call into a document that went away never answers, and a frame navigating or
            // taken away commits nothing in the tab: for an element of a frame, its document and
            // the <iframe> showing it are asked after every half second.
            var probed: [(element: ElementAddress, target: FrameTarget)] = []
            if target.info != nil, let state = agentTab(for: tab) {
                probed.append((address, target))
                if let frame = state.address(of: state.frameRef(for: address.document)), let parent = state.target(for: frame.document) { probed.append((frame, parent)) }
            }
            var asked: [PageAnswer<Data>] = []
            var met: Bool?
            repeat {
                asked = probed.indices.map { index in
                    if asked.indices.contains(index), asked[index].result == nil { return asked[index] }
                    return start(webView, probed[index].target, "info", ["id": probed[index].element.id, "token": probed[index].element.document])
                }
                let probes = asked
                met = try await watch(named, until: probes.isEmpty ? deadline : min(deadline, .now + .milliseconds(500))) { () -> Bool? in
                    if let result = pending.result {
                        guard let report = try? result.get(), let wait = try? PageProbe.decode(WaitReport.self, from: report), wait.gone != true else { return gone }
                        return wait.met == true
                    }
                    for result in probes.compactMap(\.result) {
                        guard let report = try? result.get(), let info = try? PageProbe.decode(WaitReport.self, from: report), info.gone != true else { return gone }
                    }
                    // The main frame's document was replaced, and every frame in it: the element
                    // can't come back, and a nested frame's probes go to documents that never answer.
                    return tab.commits != commits ? gone : nil
                }
            } while met == nil && ContinuousClock.now < deadline
            if met == true { return nil }
            if met == false, !gone {
                // A frame of the page left can still answer after the main frame committed, before
                // the next page says hello: the element is gone whatever it says.
                if tab.commits != commits { throw await staleRef(ref, in: named, webView, until: .now + .seconds(2)) }
                throw await staleRefIfGone(ref, named, webView, deadline, timeout: timeout, state: state)
            }
            throw timedOut(named, after: timeout, "\(ref) is not \(state)")
        case .text(let text, let present):
            let event = "“\(text)” \(present ? "showed" : "went")"
            var pause = Duration.milliseconds(50)
            let key = Self.waitKey()
            var current: PageAnswer<Data>?
            // The page's own timer would keep it re-reading its text long after the call ended.
            defer { if let current, current.result == nil { _ = start(webView, .main, "cancelWait", ["key": key]) } }
            while ContinuousClock.now < deadline {
                try checkPageShown(named, before: event)
                let commits = tab.commits
                let pending = start(webView, .main, "wait", ["text": text, "present": present, "timeoutMs": remaining(), "key": key])
                current = pending
                let outcome = try await watch(named, until: deadline) { () -> (met: Bool, unread: Int)? in
                    try self.checkPageShown(named, before: event)
                    if let result = pending.result {
                        // A document between pages fails at once: ask the next one.
                        guard let data = try? result.get(), let wait = try? PageProbe.decode(WaitReport.self, from: data) else { return (false, 0) }
                        return wait.met == true ? (true, wait.unread ?? 0) : nil
                    }
                    return tab.commits != commits ? (false, 0) : nil
                }
                guard let outcome else { break }
                if outcome.met {
                    // Gone from what Lithium could read, maybe not from a frame it couldn't.
                    guard !present, outcome.unread > 0 else { return nil }
                    return "\(outcome.unread == 1 ? "1 frame" : "\(outcome.unread) frames") of another origin couldn’t be checked: find_text reads every frame."
                }
                // The main frame moved on: wait until the next document shows, then ask it.
                _ = try await watch(named, until: deadline) { tab.isAwaitingCommit ? nil : true }
                guard tab.commits == commits else {
                    pause = .milliseconds(50)
                    continue
                }
                // The page failed the call with nothing moving on (its process gone, say): ask
                // again a little later, unless the tab stops showing a page meanwhile.
                _ = try await watch(named, until: min(deadline, .now + pause)) { () -> Bool? in
                    try self.checkPageShown(named, before: event)
                    return nil
                }
                pause = min(pause * 2, .seconds(1))
            }
            throw timedOut(named, after: timeout, present ? "no “\(text)” on the page" : "“\(text)” was still on the page")
        }
    }

    private static var waitKeys = 0
    /// Names a wait in the page, so the call can end it there.
    private static func waitKey() -> Int {
        waitKeys += 1
        return waitKeys
    }

    /// The element of a wait that never came: `stale_ref` when it has gone meanwhile.
    private func staleRefIfGone(_ ref: String, _ named: NamedTab, _ webView: WKWebView, _ deadline: ContinuousClock.Instant, timeout: Duration, state: String) async -> AgentToolError {
        if let address = tabs[named.tab.id]?.address(of: ref), let target = tabs[named.tab.id]?.target(for: address.document),
           let data = try? await ask(named, webView, target, "info", ["id": address.id, "token": address.document], until: .now + .seconds(1)),
           (try? PageProbe.decode(ElementReport.self, from: data))?.gone != true {
            return timedOut(named, after: timeout, "\(ref) is not \(state)")
        }
        return await staleRef(ref, in: named, webView, until: .now + .seconds(2))
    }

    // MARK: Screenshots

    private func screenshot(_ named: NamedTab, _ webView: WKWebView, ref: String?, fullPage: Bool, jpeg: Bool, maxWidth: Int, until deadline: ContinuousClock.Instant) async throws -> AgentToolOutput {
        var fields: [String: JSONValue] = ["tab": .string(named.id), "format": .string(jpeg ? "jpeg" : "png")]
        let picture: (image: CGImage, scale: Double, masks: [CGRect])
        if let pdf = named.tab.pdf {
            guard ref == nil, let page = await pdf.thumbnail(of: pdf.pageIndex, size: CGSize(width: maxWidth, height: maxWidth * 3 / 2)),
                  let image = AgentScreenshot.cgImage(page), let rendered = AgentScreenshot.render(image, masks: [], maxWidth: maxWidth) else {
                throw AgentToolError(code: "unsupported", message: "\(named.id) shows a PDF: only its current page can be pictured, without ref.")
            }
            picture = rendered
            fields["page"] = .int(pdf.pageIndex + 1)
        } else {
            var address: ElementAddress?
            if let ref {
                address = try await self.element(ref, in: named, webView, until: deadline).0
                fields["ref"] = .string(ref)
            }
            // The element's box comes with the masks, so the crop and the masks share the picture's scroll.
            let place = { (layout: FrameLayout) async throws -> CGRect? in
                guard let ref, let address else { return nil }
                guard let placement = layout.placement(ofDocument: address.document) else {
                    throw AgentToolError(code: "frame_gone", message: "The frame \(ref) is in has gone. Call snapshot for current refs.")
                }
                guard let box = layout.box(of: address) else { throw await self.staleRef(ref, in: named, webView, until: deadline) }
                return placement.place(box)
            }
            let first = try await layout(of: named, webView, until: deadline, placing: address)
            var element = try await place(first)
            let inViewport = element.map { CGRect(x: 0, y: 0, width: first.main.viewport.w, height: first.main.viewport.h).contains($0) } ?? !fullPage
            if inViewport {
                let (layout, image) = try await masked(named, webView, from: first, placing: address, until: deadline) { try await webView.takeSnapshot(configuration: nil) }
                element = try await place(layout)
                let viewport = layout.main.viewport
                let masks = try AgentHub.masks(layout, of: named)
                guard let cgImage = AgentScreenshot.cgImage(image) else { throw AgentToolError(code: "unsupported", message: "Lithium couldn’t picture \(named.id).") }
                let pixels = Double(cgImage.width) / max(1, webView.bounds.width)
                let toPixels = { (css: CGRect) in AgentHub.scaled(AgentScreenshot.viewRect(css, viewport: viewport, zoom: webView.pageZoom), by: pixels) }
                guard let rendered = AgentScreenshot.render(cgImage, crop: element.map { toPixels($0) }, masks: masks.map { toPixels($0) }, maxWidth: maxWidth) else {
                    throw AgentToolError(code: "unsupported", message: "\(ref ?? named.id) has nothing to picture.")
                }
                picture = (rendered.image, rendered.scale * pixels * viewport.vs * webView.pageZoom, rendered.masks)
            } else {
                // Beyond the viewport: the whole page as a PDF, drawn, without scrolling the user's page.
                let (layout, page) = try await masked(named, webView, from: first, placing: address, until: deadline) { try await webView.pdf(configuration: WKPDFConfiguration()) }
                element = try await place(layout)
                let viewport = layout.main.viewport
                let masks = try AgentHub.masks(layout, of: named)
                guard let size = AgentScreenshot.pdfPageSize(page) else { throw AgentToolError(code: "unsupported", message: "Lithium couldn’t picture \(named.id).") }
                let points = size.width / max(1, viewport.pw)
                // Only the element's box is drawn, at a density for its own width.
                let area = element.map { AgentHub.scaled($0.offsetBy(dx: viewport.sx, dy: viewport.sy), by: points) }
                if let area, area.intersection(CGRect(origin: .zero, size: size)).isEmpty {
                    throw AgentToolError(code: "unsupported", message: "\(ref ?? named.id) has nothing to picture.")
                }
                let density = min(2, Double(maxWidth) / max(1, area?.width ?? size.width))
                guard let rendered = await AgentScreenshot.picture(ofPDF: page, area: area, scale: density, masks: AgentHub.documentMasks(masks, viewport).map { AgentHub.scaled($0, by: points) }, maxWidth: maxWidth) else {
                    throw AgentToolError(code: "unsupported", message: "Lithium couldn’t picture \(named.id).")
                }
                picture = (rendered.image, rendered.scale * points * density, rendered.masks)
                if rendered.cut { fields["truncated"] = true }
                if fullPage { fields["fullPage"] = true }
            }
        }
        guard let data = await AgentScreenshot.encode(picture.image, jpeg: jpeg) else {
            throw AgentToolError(code: "unsupported", message: "Lithium couldn’t encode the picture of \(named.id).")
        }
        fields["width"] = .int(picture.image.width)
        fields["height"] = .int(picture.image.height)
        fields["scale"] = .double((picture.scale * 1000).rounded() / 1000)
        fields["masked"] = .array(picture.masks.map(AgentHub.rect))
        let image: JSONValue = ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(jpeg ? "image/jpeg" : "image/png")]
        let masked = picture.masks.isEmpty ? "" : ", \(picture.masks.count) regions painted over"
        return AgentToolOutput(structured: .object(fields), text: "Picture of \(named.id), \(picture.image.width)x\(picture.image.height)\(masked).", attachments: [image])
    }

    // MARK: Helpers

    /// The rects to mask in the whole page, in document CSS pixels.
    private static func documentMasks(_ masks: [CGRect], _ viewport: PageViewport) -> [CGRect] {
        masks.map { $0.offsetBy(dx: viewport.sx, dy: viewport.sy) }
    }

    private static func scaled(_ rect: CGRect, by factor: Double) -> CGRect {
        CGRect(x: rect.minX * factor, y: rect.minY * factor, width: rect.width * factor, height: rect.height * factor)
    }

    private static func rect(_ rect: CGRect) -> JSONValue {
        [.int(Int(css: rect.minX)), .int(Int(css: rect.minY)), .int(Int(css: rect.width)), .int(Int(css: rect.height))]
    }

    private static func pdfShown(_ named: NamedTab, use tools: String) -> AgentToolError {
        AgentToolError(code: "unsupported", message: "\(named.id) shows a PDF in Lithium’s viewer, which has no elements. Use \(tools).")
    }

    private static func textResult(_ snapshot: PageSnapshot, _ text: String, since: Int?) -> JSONValue {
        var fields: [String: JSONValue] = ["tab": .string(snapshot.tab), "seq": .int(snapshot.seq), "format": "text", "text": .string(text)]
        if let since { fields["since"] = .int(since) }
        if let challenge = snapshot.challenge { fields["challenge"] = challenge.json }
        return .object(fields)
    }

    private static func textOutput(_ fields: [String: JSONValue], text: String, maxChars: Int, truncated: Bool = false) -> AgentToolOutput {
        var fields = fields
        fields["text"] = .string(String(text.prefix(maxChars)))
        fields["truncated"] = .bool(truncated || text.count > maxChars)
        return AgentToolOutput(structured: .object(fields), text: String(text.prefix(maxChars)))
    }
}

/// A frame's answer, whatever the operation: the document it came from.
protocol DocumentReport {
    var token: String { get }
}

extension FrameReport: DocumentReport {}
extension MaskReport: DocumentReport {}

struct ChallengeReport: Decodable {
    let token: String
    let page: String?
    let frames: [String]
}

struct ReadReport: Decodable {
    let token: String
    var gone: Bool?
    var title: String?
    var url: String?
    var text: String?
    var truncated: Bool?
}

struct LinksReport: Decodable, DocumentReport {
    struct Link: Decodable {
        let id: Int
        let text: String
        let href: String
    }

    let token: String
    let links: [Link]
}

struct FormsReport: Decodable, DocumentReport {
    struct Field: Decodable {
        struct Option: Decodable {
            let label: String
            var selected: Bool?
        }

        let id: Int
        let role: String?
        let name: String
        let type: String
        var value: String?
        var filled: Bool?
        var required: Bool?
        var `guard`: String?
        var options: [Option]?
        var moreOptions: Int?

        @MainActor func json(_ frame: AgentHub.FrameRefs) -> JSONValue {
            var fields: [String: JSONValue] = ["ref": .string(frame.ref(id)), "role": .string(role ?? "textbox"), "name": .string(name), "type": .string(type)]
            if let value { fields["value"] = .string(value) }
            if filled == true { fields["filled"] = true }
            if required == true { fields["required"] = true }
            if let guardKind = self.guard { fields["guard"] = .string(guardKind) }
            if let options {
                fields["options"] = .array(options.map { option in
                    option.selected == true ? ["label": .string(option.label), "selected": true] : ["label": .string(option.label)]
                })
            }
            if let moreOptions { fields["moreOptions"] = .int(moreOptions) }
            if let ref = frame.frameRef { fields["in"] = .string(ref) }
            return .object(fields)
        }
    }

    struct Form: Decodable {
        let id: Int
        let name: String
        let action: String
        let method: String
        let fields: [Field]
        let submits: [Int]
    }

    let token: String
    let forms: [Form]
    let loose: [Field]
}

struct FindReport: Decodable, DocumentReport {
    struct Match: Decodable {
        let id: Int
        let context: String
        /// The link or button the match is in, whose ref `id` then is.
        var role: String?
    }

    let token: String
    let count: Int
    let matches: [Match]
}

struct ElementReport: Decodable {
    struct Cover: Decodable {
        let id: Int
        let tag: String
        let text: String
        var `extension`: Bool?
    }

    let token: String
    var gone: Bool?
    var role: String?
    var name: String?
    var box: [Double]?
    var `guard`: String?
    var visible: Bool?
    var hidden: String?
    var inViewport: Bool?
    var coveredBy: Cover?
}

struct WaitReport: Decodable {
    let token: String
    var gone: Bool?
    var met: Bool?
    /// A text wait: the shown frames of other origins it couldn't read.
    var unread: Int?
}
