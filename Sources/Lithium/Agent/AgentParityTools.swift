import Foundation
import WebKit

/// What MCP clients show and weigh before calling a tool (`annotations` in `tools/list`): a
/// title, and hints of what the tool does. Hints only: Lithium's guardrails decide, not the client.
enum AgentToolHints {
    enum Effect {
        /// Reads the browser or a page, changes nothing.
        case reads
        /// Changes something the user can see, nothing a page acts on (a tab selected, a scroll).
        case shows
        /// Can make a page act: submit a form, follow a link, lose what a page held.
        case acts
    }

    private struct Hint {
        let title: String
        let effect: Effect
        /// Calling it twice with the same arguments does no more than once.
        var idempotent = false
        /// Talks to websites, whose content is untrusted.
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
        "resize": Hint(title: "Resize a page", effect: .shows, idempotent: true),
    ]

    /// Nil for a tool the table doesn't know, which then goes without.
    static func annotations(for tool: String) -> JSONValue? {
        guard let hint = table[tool] else { return nil }
        var fields: [String: JSONValue] = [
            "title": .string(hint.title),
            "readOnlyHint": .bool(hint.effect == .reads),
            "idempotentHint": .bool(hint.idempotent),
            "openWorldHint": .bool(hint.openWorld),
        ]
        // The spec gives destructiveHint a meaning only for a tool that isn't read-only.
        if hint.effect != .reads { fields["destructiveHint"] = .bool(hint.effect == .acts) }
        return .object(fields)
    }
}

extension AgentHub {
    static let parityTools: [AgentTool] = [fillForm, resizeTool]

    private static let tabArgument: JSONValue = ["type": "string", "description": "A tab id from tabs_list, such as t3."]
    static let maxFormFields = 50

    // MARK: Filling a form

    /// One field of `fill_form`, as the tool that fills it would be called.
    private struct FormStep {
        let ref: String
        let kind: String
        let tool: AgentTool
        let arguments: [String: JSONValue]
    }

    static let fillForm = AgentTool(
        name: "fill_form",
        description: "Fills several fields in turn, as type (with clear), select_option and set_checked would one by one: textbox values are typed with real key presses, combobox values choose a <select> option by its label, checkbox and radio values (true or false) click when the state differs. It stops at the first field that fails and says which; the fields before it stay filled. Password and card fields wait for the user’s Allow, and no value is ever logged.",
        inputSchema: schema([
            "tab": tabArgument,
            "fields": [
                "type": "array", "minItems": 1, "maxItems": .int(maxFormFields),
                "items": [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "string", "description": "The field’s ref from snapshot or forms."],
                        "type": ["type": "string", "enum": ["textbox", "checkbox", "radio", "combobox"]],
                        "value": ["description": "Text for a textbox, an option’s label for a combobox, true or false for a checkbox or radio."],
                    ],
                    "required": ["ref", "type", "value"],
                    "additionalProperties": false,
                ],
            ],
            "timeoutMs": ["type": "integer", "minimum": 1, "maximum": 60000, "description": "Milliseconds for all the fields, 60000 by default, including the user’s answers."],
            "diff": diffParam,
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
            if let grant = last["grant"] { entry["grant"] = grant }
            if let changed = last["changed"] { entry["changed"] = changed }
            filled.append(.object(entry))
            // A field that brought another document leaves nothing to fill; one that only moved
            // within the page (a filter writing its state in the address) keeps the refs alive.
            if named.tab.commits > commits, index < steps.count - 1 {
                throw AgentToolError(code: "navigation_failed", message: "Field \(index + 1) of \(steps.count) (\(step.ref)) made \(named.id) load another page: the fields after it weren’t filled.", tab: id)
            }
        }
        var result: [String: JSONValue] = ["tab": .string(id), "filled": .array(filled)]
        for key in ["navigated", "diff", "dialog", "newTabs"] where last[key] != nil { result[key] = last[key] }
        return .object(result)
    }

    /// Checked before any field is touched, so a wrong one answers `invalid_params` at once.
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
        description: "Lays a tab’s page out at a size, in CSS pixels at zoom 1, as a window of that size would show it: to see a site at a phone’s or a small laptop’s width. Only for a tab the user isn’t looking at: Lithium never resizes the user’s window. The size holds until the user shows the tab, which gives the page the window’s size again.",
        inputSchema: schema([
            "tab": tabArgument,
            "width": ["type": "integer", "minimum": .int(resizeLimits.lowerBound), "maximum": .int(resizeLimits.upperBound)],
            "height": ["type": "integer", "minimum": .int(resizeLimits.lowerBound), "maximum": .int(resizeLimits.upperBound)],
            "timeoutMs": ["type": "integer", "minimum": 1, "maximum": 60000, "description": "Milliseconds, 15000 by default."],
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
            try await hub.checkWakeable(named, until: deadline)
            let tab = named.tab
            if tab.loadedWebView?.userWindow != nil {
                throw AgentToolError(code: "unsupported", message: "\(named.id) is shown in Lithium’s window, which agents never resize. Use a tab the user isn’t looking at.")
            }
            guard let state = hub.agentTab(for: tab) else { throw named.closedError }
            state.viewport = CGSize(width: width, height: height)
            tab.wake()
            // In the stage, so the page lays out and renders at that size now.
            let webView = hub.staged(tab)
            hub.touch(tab)
            var result: [String: JSONValue] = ["tab": .string(named.id), "width": .int(Int(webView.frame.width)), "height": .int(Int(webView.frame.height))]
            if let laidOut = try await hub.layout(of: named, webView, at: webView.frame.size, until: deadline) {
                result["viewport"] = ["w": .int(laidOut.width), "h": .int(laidOut.height)]
            }
            return .object(result)
        }
    }

    /// WebKit gives the page its new size a moment after the view's: the page is asked, and
    /// answers once its viewport matches (or after a second, as it is). The answer races the
    /// deadline and the tab's interruptions, as a busy page can't answer. Nil without one.
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
        // A page that can't answer (between documents) answers empty.
        let answer = PageAnswer<[Int]>()
        Task { answer.result = .success((try? await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: PageProbe.world)) as? [Int] ?? []) }
        guard let measured = try await watch(named, until: min(deadline, .now + .seconds(2)), { try answer.result?.get() }), measured.count == 2 else { return nil }
        return (measured[0], measured[1])
    }
}
