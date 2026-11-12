import Foundation
import WebKit

/// MCP tool `annotations`. Hints only: Lithium's guardrails decide, not the client.
enum AgentToolHints {
    enum Effect {
        case reads
        /// Changes something the user can see, nothing a page acts on (a tab selected, a scroll).
        case shows
        /// Can make a page act: submit a form, follow a link, lose what a page held.
        case acts
    }

    private struct Hint {
        let title: String
        let effect: Effect
        var idempotent = false
        var openWorld = true
    }

    private static let table: [String: Hint] = [
        "lithium_status": Hint(title: "Lithium status", effect: .reads, idempotent: true, openWorld: false),
        "tabs_list": Hint(title: "List tabs", effect: .reads, idempotent: true),
        "tab_open": Hint(title: "Open a tab", effect: .acts),
        "tab_close": Hint(title: "Close a tab", effect: .acts, openWorld: false),
        "tab_select": Hint(title: "Show a tab", effect: .shows, idempotent: true),
        "navigate": Hint(title: "Go to an address", effect: .acts),
        "go_back": Hint(title: "Go back", effect: .acts),
        "go_forward": Hint(title: "Go forward", effect: .acts),
        "reload": Hint(title: "Reload", effect: .acts),
        "stop": Hint(title: "Stop loading", effect: .shows, idempotent: true),
        "wait_for": Hint(title: "Wait for the page", effect: .reads, idempotent: true),
        "snapshot": Hint(title: "Read the page’s elements", effect: .reads, idempotent: true),
        "read_text": Hint(title: "Read the page’s text", effect: .reads, idempotent: true),
        "links": Hint(title: "List links", effect: .reads, idempotent: true),
        "forms": Hint(title: "List forms", effect: .reads, idempotent: true),
        "find_text": Hint(title: "Find text", effect: .reads, idempotent: true),
        "element_info": Hint(title: "Describe an element", effect: .reads, idempotent: true),
        "screenshot": Hint(title: "Take a screenshot", effect: .reads, idempotent: true),
        "pdf": Hint(title: "Save the page as PDF", effect: .reads, idempotent: true),
        "click": Hint(title: "Click", effect: .acts),
        "hover": Hint(title: "Hover", effect: .shows),
        "drag": Hint(title: "Drag", effect: .acts),
        "type": Hint(title: "Type text", effect: .acts),
        "press": Hint(title: "Press a key", effect: .acts),
        "select_option": Hint(title: "Choose an option", effect: .acts, idempotent: true),
        "set_checked": Hint(title: "Check or uncheck", effect: .acts, idempotent: true),
        "scroll": Hint(title: "Scroll", effect: .shows),
        "focus": Hint(title: "Focus an element", effect: .shows, idempotent: true),
        "upload_files": Hint(title: "Upload files", effect: .acts),
        "dialog_respond": Hint(title: "Answer a page’s dialog", effect: .acts),
        "fill_form": Hint(title: "Fill a form", effect: .acts, idempotent: true),
        "batch": Hint(title: "Run several steps", effect: .acts),
        "resize": Hint(title: "Resize a page", effect: .shows, idempotent: true),
        "network_log": Hint(title: "List a tab’s requests", effect: .reads, idempotent: true),
        "network_body": Hint(title: "Read a response body", effect: .reads, idempotent: true),
        "console_log": Hint(title: "Read a tab’s console", effect: .reads, idempotent: true),
        "evaluate": Hint(title: "Run a script in a page", effect: .acts),
    ]

    /// Only hints that differ from MCP's defaults: `tools/list` goes to the model with every turn.
    static func annotations(for tool: String) -> JSONValue? {
        guard let hint = table[tool] else { return nil }
        var fields: [String: JSONValue] = ["title": .string(hint.title)]
        if hint.effect == .reads { fields["readOnlyHint"] = true }
        // The spec gives destructiveHint a meaning only for a tool that isn't read-only.
        if hint.effect == .shows { fields["destructiveHint"] = false }
        if hint.idempotent { fields["idempotentHint"] = true }
        if !hint.openWorld { fields["openWorldHint"] = false }
        return .object(fields)
    }
}

extension AgentHub {
    static let parityTools: [AgentTool] = [fillForm, resizeTool]

    static let maxFormFields = 50

    // MARK: Filling a form

    private struct FormStep {
        let ref: String
        let kind: String
        let tool: AgentTool
        let arguments: [String: JSONValue]
    }

    static let fillForm = AgentTool(
        name: "fill_form",
        description: "Fill several fields in turn, stopping at the first that fails.",
        inputSchema: schema([
            "tab": AgentParam.tab,
            "fields": [
                "type": "array", "maxItems": .int(maxFormFields),
                "items": [
                    "type": "object",
                    "properties": [
                        "ref": AgentParam.ref,
                        "type": ["type": "string", "enum": ["textbox", "checkbox", "radio", "combobox"]],
                        "value": ["description": "Text, an option’s label, or true or false"],
                    ],
                    "required": ["ref", "type", "value"],
                ],
            ],
            "timeoutMs": ["type": "integer", "description": "For all fields, default 60000"],
            "diff": AgentParam.flag,
        ], required: ["tab", "fields"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let id = try arguments.string("tab")
        let named = try hub.tab(named: id)
        guard case .array(let fields)? = arguments.value["fields"], (1...maxFormFields).contains(fields.count) else {
            throw Arguments.invalid("fields must list 1 to \(maxFormFields) fields.")
        }
        let steps = try fields.enumerated().map { index, field in try formStep(field, number: index + 1) }
        let timeout = try arguments.timeout(default: 60_000)
        let diff = try arguments.bool("diff", default: true)
        let deadline = ContinuousClock.now + timeout
        var filled: [JSONValue] = []
        var last: [String: JSONValue] = [:]
        for (index, step) in steps.enumerated() {
            let left = Int((deadline - .now) / .milliseconds(1))
            guard left >= 1 else {
                throw AgentToolError(code: "timeout", message: "\(named.id) after \(Int(timeout / .milliseconds(1))) ms: \(index) of \(steps.count) fields filled.")
            }
            var stepArguments = step.arguments
            stepArguments["tab"] = .string(id)
            stepArguments["timeoutMs"] = .int(min(60_000, left))
            // Only the last field's result says what changed, for the whole form.
            stepArguments["diff"] = .bool(diff && index == steps.count - 1)
            let commits = named.tab.commits
            do {
                last = try await step.tool.run(.object(stepArguments), session, hub).structured.object ?? [:]
            } catch let error as AgentToolError {
                let before = index == 0 ? "" : " The \(index) field\(index == 1 ? "" : "s") before it stay filled."
                throw AgentToolError(code: error.code, message: "Field \(index + 1) of \(steps.count) (\(step.ref)): \(error.message)\(before)", tab: error.tab)
            }
            var entry: [String: JSONValue] = ["ref": .string(step.ref), "type": .string(step.kind)]
            if let changed = last["changed"] { entry["changed"] = changed }
            filled.append(.object(entry))
            // A new document leaves nothing to fill; a same-page navigation keeps the refs alive.
            if named.tab.commits > commits, index < steps.count - 1 {
                throw AgentToolError(code: "navigation_failed", message: "Field \(index + 1) of \(steps.count) (\(step.ref)) made \(named.id) load another page: the fields after it weren’t filled.", tab: id)
            }
        }
        var result: [String: JSONValue] = ["tab": .string(id), "filled": .array(filled)]
        for key in ["navigated", "diff", "dialog", "newTabs"] where last[key] != nil { result[key] = last[key] }
        return .object(result)
    }

    private static func formStep(_ field: JSONValue, number: Int) throws -> FormStep {
        let place = "fields[\(number - 1)]"
        guard let ref = field["ref"]?.string, AgentTab.isRef(ref) else { throw Arguments.invalid("\(place).ref must be a ref from snapshot, such as e9.") }
        guard let kind = field["type"]?.string else { throw Arguments.invalid("\(place).type must be textbox, checkbox, radio or combobox.") }
        let value = field["value"]
        switch kind {
        case "textbox":
            guard let text = value?.string else { throw Arguments.invalid("\(place).value must be text for a textbox.") }
            return FormStep(ref: ref, kind: kind, tool: typeTool, arguments: ["ref": .string(ref), "text": .string(text), "clear": true])
        case "combobox":
            guard let label = value?.string, !label.isEmpty else { throw Arguments.invalid("\(place).value must be an option’s label for a combobox.") }
            return FormStep(ref: ref, kind: kind, tool: selectOptionTool, arguments: ["ref": .string(ref), "labels": [.string(label)]])
        case "checkbox", "radio":
            // Clients that send every value as text say "true" and "false".
            let checked: Bool? = switch value {
            case .bool(let flag)?: flag
            case .string("true")?: true
            case .string("false")?: false
            default: nil
            }
            guard let checked else { throw Arguments.invalid("\(place).value must be true or false for a \(kind).") }
            return FormStep(ref: ref, kind: kind, tool: setCheckedTool, arguments: ["ref": .string(ref), "checked": .bool(checked)])
        default:
            throw Arguments.invalid("\(place).type must be textbox, checkbox, radio or combobox.")
        }
    }

    // MARK: Resizing a page

    static let resizeLimits = 200...4000

    static let resizeTool = AgentTool(
        name: "resize",
        description: "Lay a background tab’s page out at a width and height in CSS pixels (200 to 4000).",
        inputSchema: schema([
            "tab": AgentParam.tab,
            "width": AgentParam.integer,
            "height": AgentParam.integer,
            "timeoutMs": AgentParam.timeout,
        ], required: ["tab", "width", "height"])
    ) { arguments, _, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        guard arguments.value["width"] != nil, arguments.value["height"] != nil else { throw Arguments.invalid("width and height are required.") }
        let width = try arguments.int("width", default: 0, in: resizeLimits)
        let height = try arguments.int("height", default: 0, in: resizeLimits)
        let timeout = try arguments.timeout(default: 15_000)
        let deadline = ContinuousClock.now + timeout
        return try await hub.exclusive(named, until: deadline, timeout: timeout) {
            try hub.checkDrivable(named)
            try hub.checkWakeable(named)
            let tab = named.tab
            if tab.loadedWebView?.userWindow != nil {
                throw AgentToolError(code: "unsupported", message: "\(named.id) is shown in Lithium’s window, which agents never resize. Use a tab the user isn’t looking at.")
            }
            guard let state = hub.agentTab(for: tab) else { throw named.closedError }
            state.viewport = CGSize(width: width, height: height)
            tab.wake()
            let webView = hub.staged(tab)
            hub.touch(tab)
            var result: [String: JSONValue] = ["tab": .string(named.id), "width": .int(Int(webView.frame.width)), "height": .int(Int(webView.frame.height))]
            if let laidOut = try await hub.layout(of: named, webView, at: webView.frame.size, until: deadline) {
                result["viewport"] = ["w": .int(laidOut.width), "h": .int(laidOut.height)]
            }
            return .object(result)
        }
    }

    /// WebKit gives the page its new size a moment after the view's: the page answers once its
    /// viewport matches, or after a second. Nil when a busy page can't answer.
    private func layout(of named: NamedTab, _ webView: WKWebView, at size: CGSize, until deadline: ContinuousClock.Instant) async throws -> (width: Int, height: Int)? {
        let zoom = max(0.1, webView.pageZoom)
        let script = """
            const until = Date.now() + 1000;
            while ((innerWidth !== w || innerHeight !== h) && Date.now() < until) await new Promise((done) => setTimeout(done, 16));
            // The page's resize event comes with the next rendering update, before its animation
            // frames: past it, the page (and agent.js, which counts it) has seen the new size.
            await new Promise((done) => { requestAnimationFrame(() => done()); setTimeout(done, 100); });
            return [innerWidth, innerHeight];
            """
        let arguments = ["w": Int((size.width / zoom).rounded()), "h": Int((size.height / zoom).rounded())]
        let answer = PageAnswer<[Int]>()
        Task { answer.result = .success((try? await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: PageProbe.world)) as? [Int] ?? []) }
        guard let measured = try await watch(named, until: min(deadline, .now + .seconds(2)), { try answer.result?.get() }), measured.count == 2 else { return nil }
        return (measured[0], measured[1])
    }
}
