import AppKit
import WebKit

/// What `agent.js` reports about an action's target, after the checks its frame can make.
struct TargetReport: Decodable {
    struct Form: Decodable {
        let id: Int
        var cards: Bool?
        var password: Bool?
    }

    let token: String
    var path: String?
    var gone: Bool?
    /// The point hit a frame: its index in `window.frames`, and its address.
    var frame: Int?
    var src: String?
    var id: Int?
    var role: String?
    var name: String?
    var tag: String?
    var type: String?
    /// `password` or `payment`.
    var field: String?
    var wallet: Bool?
    var form: Form?
    var submit: Bool?
    var editable: Bool?
    var multiline: Bool?
    var readonly: Bool?
    var disabled: Bool?
    var focused: Bool?
    var checked: Bool?
    var draggable: Bool?
    var extensionUI: Bool?
    var hidden: String?
    var box: [Double]?
    var point: [Double]?
    var inViewport: Bool?
    var unstable: Bool?
    var coveredBy: ElementReport.Cover?
    var viewport: PageViewport?
    var counts: [String: Int]?
    var pay: FrameReport.Pay?
    var challenge: String?
    var frames: [String]?
}

/// One frame's payment facts and challenge, for the page's `Guardrails.Page`.
struct PayReport: Decodable, DocumentReport {
    let token: String
    var path: String?
    var pay: FrameReport.Pay?
    var challenge: String?
    var frames: [String]?
}

struct FocusedReport: Decodable, DocumentReport {
    let token: String
    var path: String?
    var id: Int?
    var frame: Int?
    /// The focused frame's address, and its origin when the page knows it.
    var src: String?
    var origin: String?
}

private struct FrameHitReport: Decodable {
    let token: String
    var coveredBy: ElementReport.Cover?
}

private struct SelectReport: Decodable {
    let token: String
    var gone: Bool?
    var notSelect: Bool?
    var missing: [String]?
    var available: [String]?
    var single: Bool?
    var selected: [String]?
}

private struct FocusReport: Decodable {
    let token: String
    var gone: Bool?
    var focused: Bool?
    var names: [String]?
}

/// An action's target, placed: the element (or what the point hits), the frame to ask about it,
/// where to press in the web view, and what Guardrails needs to know.
struct ActionTarget {
    var report: TargetReport
    let address: ElementAddress?
    let frame: FrameTarget
    let ref: String?
    /// Where to press, in top-level viewport CSS pixels and in the web view's points.
    var css: CGPoint
    var point = CGPoint.zero
    /// The window the web view was in, and the prompts the tab had shown the user, when it was
    /// placed: `deliver` places it again if either changed since.
    weak var window: NSWindow?
    var prompts = 0
    var viewport: PageViewport?
    var inPaymentFrame = false
    /// Focus is in a frame Lithium can't read (open before agent access was on): whatever it
    /// holds may be a password field, so text sent there is never logged.
    var inUnreadFrame = false
    /// ... and of an origin nobody knows.
    var inUnknownFrame = false
    var page = Guardrails.Page()

    /// `e9 button "Pay €42.00"`, as messages name it.
    var label: String {
        "\(ref ?? "the element at \(Int(css.x)),\(Int(css.y))") \(report.role ?? "element")" + ((report.name ?? "").isEmpty ? "" : " \(SnapshotNode.quoted(report.name ?? ""))")
    }

    /// “Pay €42.00”, or the role when it has no name, for the caption and the user's prompt.
    var shortName: String {
        let name = report.name ?? ""
        return name.isEmpty ? (report.role ?? "the element") : "“\(name.count > 40 ? String(name.prefix(39)) + "…" : name)”"
    }

    var element: Guardrails.Element {
        Guardrails.Element(role: report.role ?? "text", name: report.name, field: report.field, wallet: report.wallet == true, inPaymentFrame: inPaymentFrame, inUnknownFrame: inUnknownFrame)
    }

    var counts: [String: Int] { report.counts ?? [:] }

    enum Input {
        case click
        case key(NativeKey, NSEvent.ModifierFlags)
    }

    /// What Guardrails weighs before `input` reaches the target, decided the same way for a
    /// click and a key: a click, or Enter or Space on a control, activates it and submits the
    /// form of a submit control; Enter also submits from any input of a form (a checkbox's too)
    /// and a one-line field; a key that types a character types it.
    func guarded(_ input: Input) -> (action: Guardrails.Action, submitting: TargetReport.Form?) {
        guard case .key(let key, let modifiers) = input else { return (.activate, report.submit == true ? report.form : nil) }
        // Decided on the key, not how its name was spelled: Enter and Space with any modifier,
        // and Control+M, which types Enter's carriage return, may still activate or submit.
        let enter = key.isEnter(with: modifiers)
        let activates = (enter || key.isSpace) && Self.activatedByKeys.contains(report.role ?? "")
        if !activates, key.types(with: modifiers) { return (.type, nil) }
        let submits = report.submit == true && activates || enter && (report.submit == true || report.tag == "input" || report.editable == true && report.multiline != true)
        return (activates ? .activate : .press(enter: enter), submits ? report.form : nil)
    }

    private static let activatedByKeys: Set<String> = ["button", "link", "checkbox", "radio", "switch", "menuitem", "tab", "option"]
}

extension Guardrails.Form {
    init(_ form: TargetReport.Form) {
        self.init(cardField: form.cards == true, filledPassword: form.password == true)
    }
}

/// One action call, in its turn in a tab.
@MainActor
struct ActionContext {
    let named: NamedTab
    let webView: WKWebView
    let state: AgentTab
    let session: MCPSession
    let deadline: ContinuousClock.Instant
    let timeout: Duration
}

/// What the page must have seen before an action's result is read: `count` trusted events of
/// `type` in the target's frame.
struct Settle {
    let type: String
    let count: Int
    var scrolled = false
    /// Why the action failed if the page never saw the events; nil when that is no failure (a
    /// page may stop them before Lithium's listener).
    var unseen: String?
}

private struct SettleReport: Decodable {
    let token: String
    let seen: Bool
    var counts: [String: Int]?
}

extension AgentHub {
    static let inputTools: [AgentTool] = [clickTool, hoverTool, dragTool, typeTool, pressTool, selectOptionTool, setCheckedTool, scrollTool, focusTool, uploadFilesTool]

    private static let tabParam: JSONValue = ["type": "string", "description": "A tab id from tabs_list, such as t3."]
    private static let refParam: JSONValue = ["type": "string", "description": "An element ref from snapshot, such as e9 or f2:e7."]
    private static let coordinate: JSONValue = ["type": "number", "description": "Top-level viewport CSS pixels, as snapshot boxes give them; with the other coordinate instead of ref."]
    private static let actionTimeoutParam: JSONValue = ["type": "integer", "minimum": 1, "maximum": 60000, "description": "Milliseconds, 15000 by default, including the user’s answer when Lithium asks them."]
    private static let actionWaitParam: JSONValue = [
        "type": "string", "enum": ["none", "commit", "domcontentloaded", "load", "networkidle"],
        "description": "When the action starts a page load: how far the page must get before the call returns (commit by default). networkidle also waits, load or not, until the page’s requests have been done for 500 ms, such as those a Save button sends.",
    ]
    private static let trusted = "Lithium sends real input events to the page, which can’t tell them from the user’s. The user sees a border, a caption and a pointer dot while it acts, and can take over at any time (user_interrupted)."

    // MARK: Tools

    static let clickTool = AgentTool(
        name: "click",
        description: "Clicks an element (ref) or a point (x, y): the pointer moves there, then presses. It must be visible, enabled and not covered; Lithium scrolls it into view first. The result says whether a page load, new tabs, a dialog or a download followed, with the viewport’s diff. Payment controls, a submit of a filled password and downloads wait for the user’s Allow. \(trusted)",
        inputSchema: schema([
            "tab": tabParam, "ref": refParam, "x": coordinate, "y": coordinate,
            "button": ["type": "string", "enum": ["left", "right", "middle"]],
            "clickCount": ["type": "integer", "minimum": 1, "maximum": 3, "description": "2 for a double click."],
            "modifiers": ["type": "array", "items": ["type": "string", "enum": ["Meta", "Shift", "Alt", "Control"]]],
            "wait": actionWaitParam, "timeoutMs": actionTimeoutParam, "diff": diffParam,
        ], required: ["tab"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        let spec = try arguments.target()
        let button = NativeInput.Button(rawValue: try arguments.choice("button", ["left", "right", "middle"], default: "left")) ?? .left
        let count = try arguments.int("clickCount", default: 1, in: 1...3)
        let modifiers = try arguments.modifiers()
        let (wait, diff, timeout) = (try arguments.wait(default: .commit), try arguments.bool("diff", default: true), try arguments.timeout(default: 15_000))
        return try await hub.action(named, "Clicking", session: session, timeout: timeout) { ctx in
            let target = try await hub.resolve(spec, ctx, checks: button == .left ? [.scroll, .hitTest, .enabled] : button == .right ? [.scroll, .hitTest, .contextMenu] : [.scroll, .hitTest])
            if button == .left, target.report.tag == "select" {
                throw AgentToolError(code: "use_select_option", message: "\(target.label) is a <select>: its menu would open on the user’s screen. Use select_option.")
            }
            if target.report.tag == "input", target.report.type == "file" {
                throw AgentToolError(code: "unsupported", message: "\(target.label) chooses files: use upload_files.")
            }
            if target.report.tag == "input", target.report.type == "color" {
                throw AgentToolError(code: "unsupported", message: "\(target.label) opens the color panel, outside the page. Use type to set its value as text.")
            }
            ctx.state.acting?.caption = "\(button == .right ? "Right-clicking" : count == 2 ? "Double-clicking" : "Clicking") \(target.shortName)"
            let gate = try await hub.gate([(.press(on: [target], button), "click \(target.shortName)")], ctx)
            return try await hub.deliver(ctx, target, gate, wait: wait, diff: diff) { input in
                try input.move(to: target.point, modifiers: modifiers)
                try input.click(at: target.point, button: button, count: count, modifiers: modifiers)
                return Settle(type: "mouseup", count: (target.counts["mouseup"] ?? 0) + count)
            }
        }
    }

    static let hoverTool = AgentTool(
        name: "hover",
        description: "Moves the pointer over an element (ref) or a point (x, y), in a few steps, so the page shows what it shows on hover (menus, tooltips). \(trusted)",
        inputSchema: schema(["tab": tabParam, "ref": refParam, "x": coordinate, "y": coordinate, "timeoutMs": actionTimeoutParam, "diff": diffParam], required: ["tab"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        let spec = try arguments.target()
        let (diff, timeout) = (try arguments.bool("diff", default: true), try arguments.timeout(default: 15_000))
        return try await hub.action(named, "Hovering", session: session, timeout: timeout) { ctx in
            let target = try await hub.resolve(spec, ctx, checks: [.scroll, .hitTest])
            ctx.state.acting?.caption = "Hovering over \(target.shortName)"
            let gate = try await hub.gate([(.pointer, "hover over \(target.shortName)")], ctx)
            return try await hub.deliver(ctx, target, gate, wait: .commit, diff: diff) { input in
                try input.move(to: target.point, steps: 4)
                // WebKit gives pointer moves without a button only to the window the user has
                // in front: a tab out of sight, or Lithium in the background, gets none.
                let unseen = "\(ctx.named.id)’s page didn’t get the pointer: WebKit passes hover only to the page in the window in front of the user. Click instead, or ask the user to bring the tab to the front."
                return Settle(type: "mousemove", count: (target.counts["mousemove"] ?? 0) + 1, unseen: unseen)
            }
        }
    }

    static let dragTool = AgentTool(
        name: "drag",
        description: "Presses on from, moves to to in steps, and lets go: pointer drags such as sliders, sortable lists and canvases. from and to are each a ref or {x, y}. HTML drag and drop (draggable elements) isn’t supported. \(trusted)",
        inputSchema: schema([
            "tab": tabParam,
            "from": ["description": "A ref, or {\"x\": …, \"y\": …} in top-level viewport CSS pixels."],
            "to": ["description": "A ref, or {\"x\": …, \"y\": …} in top-level viewport CSS pixels."],
            "steps": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Moves between the two, 10 by default."],
            "timeoutMs": actionTimeoutParam, "diff": diffParam,
        ], required: ["tab", "from", "to"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        let from = try arguments.target(in: "from")
        let to = try arguments.target(in: "to")
        let steps = try arguments.int("steps", default: 10, in: 1...100)
        let (diff, timeout) = (try arguments.bool("diff", default: true), try arguments.timeout(default: 15_000))
        return try await hub.action(named, "Dragging", session: session, timeout: timeout) { ctx in
            let start = try await hub.resolve(from, ctx, checks: [.scroll, .hitTest])
            if start.report.draggable == true {
                throw AgentToolError(code: "unsupported", message: "\(start.label) is draggable: HTML drag and drop isn’t supported, only pointer drags.")
            }
            // Not scrolled into view: that would move where the drag starts.
            let end = try await hub.resolve(to, ctx, checks: [])
            ctx.state.acting?.caption = "Dragging \(start.shortName)"
            // The press and the release are a click on what each lands on (one element, for a
            // drag that ends where it starts), and the stricter asks.
            let gate = try await hub.gate([(.press(on: [start, end], .left), "drag \(start.shortName)")], ctx)
            return try await hub.deliver(ctx, start, gate, wait: .commit, diff: diff) { input in
                try input.move(to: start.point)
                try input.down(at: start.point)
                // The page reaches a move without a button only in the window in front: what it
                // counted by the press tells whether that first move is one of its own.
                let pressed = try await hub.settle(ctx, start.frame, Settle(type: "mousedown", count: (start.counts["mousedown"] ?? 0) + 1), timeout: 250, frame: false)
                var moves = pressed["mousemove"] ?? start.counts["mousemove"] ?? 0
                for step in 1...steps {
                    let fraction = Double(step) / Double(steps)
                    try input.move(to: CGPoint(x: start.point.x + (end.point.x - start.point.x) * fraction, y: start.point.y + (end.point.y - start.point.y) * fraction))
                    // WebKit sends only the last of the moves queued while the page is busy:
                    // each step waits until the page saw the one before.
                    moves += 1
                    try await hub.settle(ctx, start.frame, Settle(type: "mousemove", count: moves), timeout: 250, frame: false)
                }
                try input.up()
                return Settle(type: "mouseup", count: (start.counts["mouseup"] ?? 0) + 1)
            }
        }
    }

    static let typeTool = AgentTool(
        name: "type",
        description: "Types text into a field (ref), or into the focused element without ref: a click focuses the field first, the caret goes to its end, and each character is a real key press (characters no key types are inserted as an input method would). clear replaces what the field holds; submit presses Enter after. \\n types a line break in a text area or an editable element. Password and card fields wait for the user’s Allow, and what is typed there is never logged. \(trusted)",
        inputSchema: schema([
            "tab": tabParam, "ref": refParam, "text": ["type": "string"],
            "clear": ["type": "boolean", "description": "false by default."], "submit": ["type": "boolean", "description": "false by default: true presses Enter after the text."],
            "wait": actionWaitParam, "timeoutMs": actionTimeoutParam, "diff": diffParam,
        ], required: ["tab", "text"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        guard let text = arguments.value["text"]?.string else { throw Arguments.invalid("text is required and must be a string.") }
        let ref = try arguments.ref()
        let (clear, submit) = (try arguments.bool("clear", default: false), try arguments.bool("submit", default: false))
        if text.unicodeScalars.contains(where: { ($0.value < 0x20 && $0 != "\n") || $0.value == 0x7F }) {
            throw Arguments.invalid("text can’t hold control characters other than \\n. Use press for Tab, Escape and the like.")
        }
        let (wait, diff, timeout) = (try arguments.wait(default: .commit), try arguments.bool("diff", default: true), try arguments.timeout(default: 15_000))
        return try await hub.action(named, "Typing", session: session, timeout: timeout) { ctx in
            let target = try await hub.resolve(ref.map(TargetSpec.ref) ?? .focused, ctx, checks: ref == nil ? [.editable] : [.scroll, .editable, .hitTest])
            if text.contains("\n"), target.report.multiline != true {
                throw Arguments.invalid("\(target.label) holds one line: \\n would submit its form. Use submit: true.")
            }
            ctx.state.acting?.caption = "Typing in \(target.shortName)"
            var steps: [(Delivery, describing: String)] = [(.keys(into: target, .type, submitting: nil), "type into \(target.shortName)" + (submit ? " and submit its form" : ""))]
            if submit { steps.append((.keys(into: target, .press(enter: true), submitting: target.report.form), "submit the form of \(target.shortName)")) }
            if target.report.focused != true { steps.append((.press(on: [target], .left), "click \(target.shortName)")) }
            let gate = try await hub.gate(steps, ctx)
            var into = target
            var result = try await hub.deliver(ctx, target, gate, wait: wait, diff: diff) { input in
                var keys = target.counts["keyup"] ?? 0
                var inserted = target.counts["beforeinput"] ?? 0
                var last = "keyup"
                if target.report.focused != true {
                    try input.move(to: target.point)
                    try input.click(at: target.point, button: .left, count: 1, modifiers: [])
                    try await hub.settle(ctx, target.frame, Settle(type: "mouseup", count: (target.counts["mouseup"] ?? 0) + 1), timeout: 1000, frame: false)
                }
                // The page may move focus on the click (a decoy field that focuses a password
                // field), a moment after it, or while the user answers: the first key goes where
                // focus is right before it, once a gate has weighed that element as typing there
                // asks. A page that keeps moving focus gets nothing.
                for attempt in 1... {
                    if !clear, ref != nil, let address = into.address {
                        _ = try await hub.ask(ctx.named, ctx.webView, into.frame, "caretEnd", ["id": address.id, "token": address.document], until: ctx.deadline)
                    }
                    let focused = try await hub.resolve(.focused, ctx, checks: [.editable])
                    if focused.address == into.address { break }
                    guard attempt < 3, !focused.inUnreadFrame, focused.address?.document == target.address?.document else {
                        AgentHub.callNotes?.noteFields(unguarded: false)
                        throw AgentToolError(code: "not_editable", message: attempt < 3 ? "Focus moved from \(target.label) into another frame. Give the ref of the field to type into." : "The page keeps moving focus away from \(target.label).")
                    }
                    var moved: [(Delivery, describing: String)] = [(.keys(into: focused, .type, submitting: nil), "type into \(focused.shortName)" + (submit ? " and submit its form" : ""))]
                    if submit { moved.append((.keys(into: focused, .press(enter: true), submitting: focused.report.form), "submit the form of \(focused.shortName)")) }
                    _ = try await hub.gate(moved, ctx)
                    into = focused
                    keys = focused.counts["keyup"] ?? 0
                    inserted = focused.counts["beforeinput"] ?? 0
                }
                if clear {
                    ctx.webView.selectAll(nil)
                    try input.key(NativeKey.named["Backspace"]!)
                    keys += 1
                }
                var pending = ""
                for character in text {
                    let key = character == "\n" ? NativeKey.named["Enter"] : NativeKey.typing(character)
                    guard let key else {
                        pending.append(character)
                        continue
                    }
                    try await hub.insert(&pending, input, ctx, into, keys: keys, inserted: &inserted)
                    try input.key(key)
                    keys += 1
                    last = "keyup"
                }
                if !pending.isEmpty {
                    try await hub.insert(&pending, input, ctx, into, keys: keys, inserted: &inserted)
                    last = "beforeinput"
                }
                if submit {
                    try input.key(NativeKey.named["Enter"]!)
                    keys += 1
                    last = "keyup"
                }
                return last == "keyup" ? Settle(type: "keyup", count: keys) : Settle(type: "beforeinput", count: inserted)
            }.object ?? [:]
            if Guardrails.confirmation(for: .type, on: into.element, page: into.page) != nil { result["typed"] = .int(text.count) }
            return .object(result)
        }
    }

    static let pressTool = AgentTool(
        name: "press",
        description: "Presses a key or a combination in the focused element: Enter, Tab, Shift+Tab, Escape, ArrowDown, PageDown, Backspace, F5, Meta+K. Meta+A, Meta+Z and Shift+Meta+Z select all, undo and redo; copy, cut and paste are disabled. Lithium’s own shortcuts never fire. A character typed into a password or card field, and Enter or Space that submits a password or payment form or activates a payment control, wait for the user’s Allow, as type and click do. Character keys are never logged. \(trusted)",
        inputSchema: schema([
            "tab": tabParam, "keys": ["type": "string", "description": "One key, with modifiers joined by +, such as Meta+K."],
            "repeat": ["type": "integer", "minimum": 1, "maximum": 100, "description": "1 by default."],
            "wait": actionWaitParam, "timeoutMs": actionTimeoutParam, "diff": diffParam,
        ], required: ["tab", "keys"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        let combo = try arguments.string("keys")
        guard let parsed = NativeKey.parse(combo) else {
            throw Arguments.invalid("keys must be one key such as Enter, Tab, ArrowDown, F5 or a character, with Meta, Control, Alt or Shift joined by +.")
        }
        let (key, name, modifiers) = parsed
        // A character key is never shown or logged: it may be part of a password.
        let spoken = NativeKey.named[name] != nil ? combo : modifiers.subtracting(.shift).isEmpty ? "a character key" : "a shortcut"
        let command = modifiers.contains(.command) ? name.lowercased() : nil
        if let command, ["c", "x", "v"].contains(command), modifiers.subtracting([.command, .shift]).isEmpty {
            throw AgentToolError(code: "clipboard_disabled", message: "Copy, cut and paste would use the user’s clipboard, which agents can’t reach. Use read_text to read and type to write.")
        }
        // Editing commands the page doesn't get as key equivalents (design section 3, item 13).
        let responder: Selector? = switch (command, modifiers.subtracting(.command)) {
        case ("a", []): #selector(NSResponder.selectAll(_:))
        case ("z", []): Selector(("undo:"))
        case ("z", .shift): Selector(("redo:"))
        default: nil
        }
        let times = try arguments.int("repeat", default: 1, in: 1...100)
        let (wait, diff, timeout) = (try arguments.wait(default: .commit), try arguments.bool("diff", default: true), try arguments.timeout(default: 15_000))
        return try await hub.action(named, "Pressing \(spoken)", session: session, timeout: timeout) { ctx in
            // Only a page's own undo stack is the page's: the window's holds Lithium's edits too.
            if let responder, responder != #selector(NSResponder.selectAll(_:)), !(ctx.webView is PageWebView) {
                throw AgentToolError(code: "unsupported", message: "Undo and redo in \(ctx.named.id) would reach Lithium’s own edits, not just its page’s.")
            }
            let target = try await hub.resolve(.focused, ctx, checks: [])
            let (action, form) = target.guarded(.key(key, modifiers))
            let describing = action == .type ? "type into \(target.shortName)" : "press \(spoken) in \(target.shortName)"
            let gate = try await hub.gate([(.keys(into: target, action, submitting: form), describing)], ctx)
            return try await hub.deliver(ctx, target, gate, wait: wait, diff: diff) { input in
                if let responder {
                    for _ in 0..<times {
                        try hub.checkStillWaitable(ctx.named, ignoringDialog: true)
                        ctx.webView.tryToPerform(responder, with: nil)
                    }
                    return Settle(type: "keyup", count: target.counts["keyup"] ?? 0)
                }
                for _ in 0..<times { try input.key(key, modifiers: modifiers) }
                return Settle(type: "keyup", count: (target.counts["keyup"] ?? 0) + times)
            }
        }
    }

    static let selectOptionTool = AgentTool(
        name: "select_option",
        description: "Chooses options in a <select> by their values or their labels (several for a multiple select). The page gets input and change events that are not trusted: its native menu would open on the user’s screen. Custom dropdowns and listboxes are clicked instead. Card fields wait for the user’s Allow.",
        inputSchema: schema([
            "tab": tabParam, "ref": refParam,
            "values": ["type": "array", "items": ["type": "string"]], "labels": ["type": "array", "items": ["type": "string"]],
            "wait": actionWaitParam, "timeoutMs": actionTimeoutParam, "diff": diffParam,
        ], required: ["tab", "ref"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        guard let ref = try arguments.ref() else { throw Arguments.invalid("ref is required.") }
        let values = try arguments.strings("values")
        let labels = try arguments.strings("labels")
        guard (values == nil) != (labels == nil), !(values ?? labels ?? []).isEmpty else { throw Arguments.invalid("Give values or labels, a list of at least one.") }
        let (wait, diff, timeout) = (try arguments.wait(default: .commit), try arguments.bool("diff", default: true), try arguments.timeout(default: 15_000))
        return try await hub.action(named, "Choosing", session: session, timeout: timeout) { ctx in
            let target = try await hub.resolve(.ref(ref), ctx, checks: [.scroll, .enabled])
            guard target.report.tag == "select", let address = target.address else {
                throw AgentToolError(code: "unsupported", message: "\(target.label) is not a <select>: click it, then click the option.")
            }
            ctx.state.acting?.caption = "Choosing in \(target.shortName)"
            let gate = try await hub.gate([(.change(target, .select), "choose in \(target.shortName)")], ctx)
            var chosen: [String] = []
            let result = try await hub.deliver(ctx, target, gate, wait: wait, diff: diff, fields: ["untrustedEvents": true]) { _ in
                var args: [String: Any] = ["id": address.id, "token": address.document]
                if let values { args["values"] = values } else { args["labels"] = labels ?? [] }
                let report = try PageProbe.decode(SelectReport.self, from: try await hub.ask(ctx.named, ctx.webView, target.frame, "selectOption", args, until: ctx.deadline))
                if report.gone == true { throw await hub.staleRef(ref, in: ctx.named, ctx.webView, until: ctx.deadline) }
                if let missing = report.missing {
                    throw AgentToolError(code: "invalid_params", message: "\(target.label) has no option \(missing.map(SnapshotNode.quoted).joined(separator: ", ")). Its options: \((report.available ?? []).map(SnapshotNode.quoted).joined(separator: ", ")).")
                }
                if report.single == true { throw Arguments.invalid("\(target.label) takes one option.") }
                chosen = report.selected ?? []
                return Settle(type: "keyup", count: target.counts["keyup"] ?? 0)
            }
            var object = result.object ?? [:]
            // A card field's choice (an expiry month) isn't repeated back.
            if target.report.field == nil { object["selected"] = .array(chosen.map(JSONValue.string)) }
            return .object(object)
        }
    }

    static let setCheckedTool = AgentTool(
        name: "set_checked",
        description: "Checks or unchecks a checkbox, switch or radio button with a click, only when its state differs. \(trusted)",
        inputSchema: schema(["tab": tabParam, "ref": refParam, "checked": ["type": "boolean"], "timeoutMs": actionTimeoutParam, "diff": diffParam], required: ["tab", "ref", "checked"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        guard let ref = try arguments.ref() else { throw Arguments.invalid("ref is required.") }
        guard arguments.value["checked"] != nil else { throw Arguments.invalid("checked is required.") }
        let checked = try arguments.bool("checked", default: true)
        let (diff, timeout) = (try arguments.bool("diff", default: true), try arguments.timeout(default: 15_000))
        return try await hub.action(named, "Checking", session: session, timeout: timeout) { ctx in
            let target = try await hub.resolve(.ref(ref), ctx, checks: [.scroll, .hitTest, .enabled])
            guard ["checkbox", "radio", "switch", "menuitemcheckbox", "menuitemradio"].contains(target.report.role ?? "") else {
                throw AgentToolError(code: "unsupported", message: "\(target.label) is not a checkbox, switch or radio button.")
            }
            let isChecked = target.report.checked == true
            if isChecked == checked { return ["tab": .string(ctx.named.id), "ref": .string(ref), "checked": .bool(checked), "changed": false] }
            if !checked, target.report.role == "radio" { throw Arguments.invalid("\(target.label) is a radio button: check another one of its group instead.") }
            ctx.state.acting?.caption = "\(checked ? "Checking" : "Unchecking") \(target.shortName)"
            let describing = "\(checked ? "check" : "uncheck") \(target.shortName)"
            let gate = try await hub.gate([(.change(target, .check), describing), (.press(on: [target], .left), describing)], ctx)
            var result = try await hub.deliver(ctx, target, gate, wait: .commit, diff: diff, fields: ["changed": true]) { input in
                try input.move(to: target.point)
                try input.click(at: target.point, button: .left, count: 1, modifiers: [])
                return Settle(type: "mouseup", count: (target.counts["mouseup"] ?? 0) + 1)
            }.object ?? [:]
            if let address = target.address, result["navigated"] != true,
               let data = try? await hub.ask(ctx.named, ctx.webView, target.frame, "target", ["id": address.id, "token": address.document], until: min(ctx.deadline, .now + .seconds(2))),
               let after = try? PageProbe.decode(TargetReport.self, from: data), after.gone != true {
                result["checked"] = .bool(after.checked == true)
            }
            return .object(result)
        }
    }

    static let scrollTool = AgentTool(
        name: "scroll",
        description: "Scrolls: ref alone brings that element into view; dx and dy (CSS pixels, positive is right and down) scroll with the wheel where the pointer is, at the ref or point given by at, x and y, else the middle of the viewport. \(trusted)",
        inputSchema: schema([
            "tab": tabParam, "ref": refParam,
            "dx": ["type": "number"], "dy": ["type": "number"],
            "at": refParam, "x": coordinate, "y": coordinate,
            "timeoutMs": actionTimeoutParam, "diff": diffParam,
        ], required: ["tab"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        let ref = try arguments.ref()
        let dx = try arguments.number("dx") ?? 0
        let dy = try arguments.number("dy") ?? 0
        let wheel = arguments.value["dx"] != nil || arguments.value["dy"] != nil
        guard wheel || ref != nil else { throw Arguments.invalid("Give ref to scroll an element into view, or dx and dy.") }
        guard !wheel || ref == nil else { throw Arguments.invalid("Give ref alone, or dx and dy with at, x and y.") }
        guard abs(dx) <= 100_000, abs(dy) <= 100_000 else { throw Arguments.invalid("dx and dy must be at most 100000.") }
        let at = try arguments.ref(key: "at").map(TargetSpec.ref) ?? arguments.point()
        let (diff, timeout) = (try arguments.bool("diff", default: true), try arguments.timeout(default: 15_000))
        return try await hub.action(named, "Scrolling", session: session, timeout: timeout) { ctx in
            if let ref {
                let (address, frame) = try await hub.element(ref, in: ctx.named, ctx.webView, until: ctx.deadline)
                let report = try PageProbe.decode(FocusReport.self, from: try await hub.ask(ctx.named, ctx.webView, frame, "scrollTo", ["id": address.id, "token": address.document], until: ctx.deadline))
                if report.gone == true { throw await hub.staleRef(ref, in: ctx.named, ctx.webView, until: ctx.deadline) }
                let page = try await hub.addingDiff(to: ["tab": .string(ctx.named.id), "ref": .string(ref)], of: ctx.named, for: ctx.session, if: diff, until: ctx.deadline)
                return page
            }
            let zoom = max(0.1, ctx.webView.pageZoom)
            let middle = CGPoint(x: ctx.webView.bounds.midX / zoom, y: ctx.webView.bounds.midY / zoom)
            let target = try await hub.resolve(at ?? .point(middle), ctx, checks: [])
            let gate = try await hub.gate([(.pointer, "scroll \(target.shortName)")], ctx)
            return try await hub.deliver(ctx, target, gate, wait: .commit, diff: diff) { input in
                let events = try input.wheel(dx: dx, dy: dy, at: target.point)
                return Settle(type: "wheel", count: (target.counts["wheel"] ?? 0) + events - 1, scrolled: true)
            }
        }
    }

    static let focusTool = AgentTool(
        name: "focus",
        description: "Focuses an element as tabbing into it would, without a click.",
        inputSchema: schema(["tab": tabParam, "ref": refParam, "timeoutMs": actionTimeoutParam, "diff": diffParam], required: ["tab", "ref"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        guard let ref = try arguments.ref() else { throw Arguments.invalid("ref is required.") }
        let (diff, timeout) = (try arguments.bool("diff", default: true), try arguments.timeout(default: 15_000))
        return try await hub.action(named, "Focusing", session: session, timeout: timeout) { ctx in
            let (address, frame) = try await hub.element(ref, in: ctx.named, ctx.webView, until: ctx.deadline)
            let report = try PageProbe.decode(FocusReport.self, from: try await hub.ask(ctx.named, ctx.webView, frame, "focus", ["id": address.id, "token": address.document], until: ctx.deadline))
            if report.gone == true { throw await hub.staleRef(ref, in: ctx.named, ctx.webView, until: ctx.deadline) }
            let page: JSONValue = ["tab": .string(ctx.named.id), "ref": .string(ref), "focused": .bool(report.focused == true)]
            return try await hub.addingDiff(to: page, of: ctx.named, for: ctx.session, if: diff, until: ctx.deadline)
        }
    }

    static let uploadFilesTool = AgentTool(
        name: "upload_files",
        description: "Gives files to a file input, or to the control that opens its chooser (ref): the user is asked first, with the files’ names, sizes and folder, then Lithium clicks it and its chooser gets those files without showing a panel. paths are absolute.",
        inputSchema: schema([
            "tab": tabParam, "ref": refParam,
            "paths": ["type": "array", "items": ["type": "string"], "minItems": 1],
            "timeoutMs": ["type": "integer", "minimum": 1, "maximum": 60000, "description": "Milliseconds, 60000 by default, including the user’s answer."],
            "diff": diffParam,
        ], required: ["tab", "ref", "paths"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        guard let ref = try arguments.ref() else { throw Arguments.invalid("ref is required.") }
        guard let paths = try arguments.strings("paths"), !paths.isEmpty else { throw Arguments.invalid("paths must name at least one file.") }
        let files = try paths.map { path -> URL in
            guard path.hasPrefix("/") else { throw Arguments.invalid("\(path) isn’t an absolute path.") }
            return URL(filePath: path).standardizedFileURL
        }
        let (diff, timeout) = (try arguments.bool("diff", default: true), try arguments.timeout(default: 60_000))
        return try await hub.action(named, "Uploading", session: session, timeout: timeout) { ctx in
            // The input itself is often hidden behind a styled button: only a visible one is clicked.
            let target = try await hub.resolve(.ref(ref), ctx, checks: [.scroll, .hitTest, .enabled])
            ctx.state.acting?.caption = "Uploading \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")"
            // The click that opens the chooser asks as a click there would (a "Pay" button).
            let gate = try await hub.gate([(.press(on: [target], .left), "click \(target.shortName)")], ctx)
            let grant = try await hub.confirmUpload(files, in: ctx.named, session: ctx.session, until: ctx.deadline)
            defer { ctx.state.armedUpload = nil }
            var result = try await hub.deliver(ctx, target, gate, wait: .commit, diff: diff, fields: ["grant": .string(grant.rawValue)]) { input in
                try input.move(to: target.point)
                try input.click(at: target.point, button: .left, count: 1, modifiers: [])
                return Settle(type: "mouseup", count: (target.counts["mouseup"] ?? 0) + 1)
            }.object ?? [:]
            // The chooser asks for its files a moment after the click.
            _ = try await hub.watch(ctx.named, until: min(ctx.deadline, .now + .seconds(2))) { ctx.state.armedUpload == nil ? true : nil }
            guard ctx.state.armedUpload == nil else {
                throw AgentToolError(code: "unsupported", message: "No file chooser opened when Lithium clicked \(target.label). Give the file input’s ref, or the button that opens it.")
            }
            result["files"] = .array(files.map { .string($0.lastPathComponent) })
            if target.report.type == "file", let address = target.address,
               let data = try? await hub.ask(ctx.named, ctx.webView, target.frame, "files", ["id": address.id, "token": address.document], until: min(ctx.deadline, .now + .seconds(2))),
               let names = (try? PageProbe.decode(FocusReport.self, from: data))?.names {
                result["inputFiles"] = .array(names.map(JSONValue.string))
            }
            return .object(result)
        }
    }

    // MARK: Running an action

    /// Runs an action in its turn in the tab (design section 5): a sleeping tab wakes into the
    /// stage, the web view goes where it takes events, and the user sees a border, a caption and
    /// the agent's pointer while it runs. The user editing in Lithium's own UI over the tab, or
    /// pressing in its page, holds it up to 5 seconds, then `user_busy`. Once more when the
    /// user moved the tab into another window before any press (design section 2.7).
    func action(_ named: NamedTab, _ verb: String, session: MCPSession, timeout: Duration, _ body: (ActionContext) async throws -> JSONValue) async throws -> JSONValue {
        let deadline = ContinuousClock.now + timeout
        return try await exclusive(named, until: deadline, timeout: timeout) {
            try checkDrivable(named)
            if let dialog = tabs[named.tab.id]?.dialog { throw dialogOpen(named, dialog) }
            let tab = named.tab
            try await waitWhileUserBusy(named, until: deadline)
            if tab.isAsleep {
                try await checkWakeable(named, until: deadline)
                _ = try await navigation(in: named, wait: .domcontentloaded, deadline: deadline, timeout: timeout, landedWithinPage: nil) {
                    tab.wake()
                    // A page that finishes loading before its web view is in a window stays blank.
                    _ = self.staged(tab)
                }
            }
            if tab.pdf != nil {
                throw AgentToolError(code: "unsupported", message: "\(named.id) shows a PDF in Lithium’s viewer, which has no elements to act on.")
            }
            guard let state = agentTab(for: tab) else { throw named.closedError }
            state.acting = AgentActing(session: session.id, caption: verb)
            state.opened = []
            defer {
                state.acting = nil
                state.opened = []
                state.answered = [:]
            }
            touch(tab)
            for attempt in 1...2 {
                AgentHub.callNotes?.startAttempt()
                let webView = staged(tab)
                // The stage keeps it however long the user takes to answer.
                stage.hold(webView)
                defer { stage.letGo(webView) }
                do {
                    return try await body(ActionContext(named: named, webView: webView, state: state, session: session, deadline: deadline, timeout: timeout))
                } catch let change as NativeInput.WindowChanged where !change.afterPress {
                    if attempt == 2 { break }
                }
            }
            throw AgentToolError(code: "user_interrupted", message: "\(named.id) moved between windows, or its page changed, while the agent acted in it.")
        }
    }

    /// The tab's web view in a window that takes events: its own (the selected tab, the video
    /// pop-out), else the stage.
    @discardableResult
    func staged(_ tab: Tab) -> WKWebView {
        let webView = sizedWebView(of: tab)
        if webView.userWindow == nil {
            stage.host(webView, size: pageAreaSize)
            fitViewport(of: webView, in: tab)
        }
        return webView
    }

    private func waitWhileUserBusy(_ named: NamedTab, until deadline: ContinuousClock.Instant) async throws {
        let limit = min(deadline, .now + .seconds(5))
        while let doing = userBusy(in: named.tab) {
            guard ContinuousClock.now < limit else {
                throw AgentToolError(code: "user_busy", message: "The user is \(doing). Try again in a moment.")
            }
            // Nothing to observe: AppKit's first responder and pressed buttons aren't observable.
            try await Task.sleep(for: .milliseconds(100))
            try checkStillWaitable(named)
        }
    }

    /// What the user is doing over the tab shown, if it holds an agent's action up.
    func userBusy(in tab: Tab) -> String? {
        guard let webView = tab.loadedWebView, let window = webView.userWindow else { return nil }
        if (webView as? PageWebView)?.isUserPressing == true { return "pressing in \(id(for: tab))’s page" }
        guard tab.id == browser?.selectedTabID else { return nil }
        if browser?.renamingTabID != nil { return "renaming a tab in Lithium" }
        if let editor = window.firstResponder as? NSTextView, !editor.isDescendant(of: webView) { return "typing in Lithium’s address bar or another field of its own" }
        return nil
    }

    // MARK: Targets

    enum TargetSpec {
        case ref(String)
        case point(CGPoint)
        /// The focused element, in whichever frame focus went into.
        case focused
    }

    struct Checks: OptionSet {
        let rawValue: Int
        static let scroll = Checks(rawValue: 1)
        static let hitTest = Checks(rawValue: 2)
        static let enabled = Checks(rawValue: 4)
        static let editable = Checks(rawValue: 8)
        /// A right click follows: the page gets `contextmenu` and no native menu opens.
        static let contextMenu = Checks(rawValue: 16)
    }

    /// The action's target with every check of design section 5.1, in its order, and the
    /// payment facts of the page; each fails with the first error.
    func resolve(_ spec: TargetSpec, _ ctx: ActionContext, checks: Checks) async throws -> ActionTarget {
        var target: ActionTarget
        switch spec {
        case .ref(let ref):
            target = try await resolveRef(ref, ctx, checks: checks)
        case .point(let point):
            target = try await resolvePoint(point, ctx, menu: checks.contains(.contextMenu))
        case .focused:
            target = try await resolveFocused(ctx, checks: checks)
        }
        try await addPageFacts(to: &target, ctx)
        guard let viewport = target.viewport else { throw AgentHub.frameGone(target.ref) }
        target.point = AgentScreenshot.viewRect(CGRect(origin: target.css, size: .zero), viewport: viewport, zoom: ctx.webView.pageZoom).origin
        target.window = ctx.webView.window
        target.prompts = ctx.state.prompts
        return target
    }

    private func resolveRef(_ ref: String, _ ctx: ActionContext, checks: Checks) async throws -> ActionTarget {
        let (address, frame) = try await element(ref, in: ctx.named, ctx.webView, until: ctx.deadline)
        var args: [String: Any] = ["id": address.id, "token": address.document, "scroll": checks.contains(.scroll), "menu": checks.contains(.contextMenu)]
        if case .main = frame, let box = ctx.state.shown[ref]?.box { args["known"] = box }
        let report = try PageProbe.decode(TargetReport.self, from: try await ask(ctx.named, ctx.webView, frame, "target", args, until: ctx.deadline))
        if report.gone == true { throw await staleRef(ref, in: ctx.named, ctx.webView, until: ctx.deadline) }
        var target = ActionTarget(report: report, address: address, frame: frame, ref: ref, css: CGPoint(report.point), viewport: report.viewport)
        try check(target, checks, ctx)
        if case .child = frame { try await placeInFrame(&target, ctx, hitTest: checks.contains(.hitTest)) }
        return target
    }

    /// The checks `agent.js` answered for, in the order of design section 5.1.
    private func check(_ target: ActionTarget, _ checks: Checks, _ ctx: ActionContext) throws {
        let report = target.report
        if report.extensionUI == true {
            throw AgentToolError(code: "blocked_extension_ui", message: "\(target.label) belongs to an extension’s UI, which agents can’t use.")
        }
        if let hidden = report.hidden { throw AgentToolError(code: "not_visible", message: "\(target.label) has \(hidden).") }
        if report.inViewport == false {
            throw AgentToolError(code: "not_in_viewport", message: "\(target.label) stays outside the viewport after scrolling (a fixed or clipped element). Scroll its container, or use x and y.")
        }
        if report.unstable == true { throw AgentToolError(code: "unstable", message: "\(target.label) is animating. Try again once it stops, or wait_for it.") }
        if checks.contains(.enabled) || checks.contains(.editable), report.disabled == true {
            throw AgentToolError(code: "disabled", message: "\(target.label) is disabled.")
        }
        if checks.contains(.editable) {
            if report.readonly == true { throw AgentToolError(code: "readonly", message: "\(target.label) is read-only.") }
            if report.editable != true { throw AgentToolError(code: "not_editable", message: "\(target.label) isn’t a field text can be typed into.") }
        }
        if checks.contains(.hitTest), let cover = report.coveredBy { throw covered(target, by: cover, in: report.token, ctx) }
    }

    private func covered(_ target: ActionTarget, by cover: ElementReport.Cover, in document: String, _ ctx: ActionContext) -> AgentToolError {
        if cover.extension == true {
            return AgentToolError(code: "blocked_extension_ui", message: "\(target.label) is covered by an extension’s UI, which agents can’t use.")
        }
        let ref = ctx.state.ref(for: ElementAddress(document: document, id: cover.id))
        let text = cover.text.isEmpty ? "" : " \(SnapshotNode.quoted(cover.text))"
        // `DIV#cookie-banner`: the tag as CSS writes it, the id as the page does.
        let tag = cover.tag.split(separator: "#", maxSplits: 1).enumerated().map { $0.offset == 0 ? $0.element.uppercased() : String($0.element) }.joined(separator: "#")
        return AgentToolError(code: "covered", message: "\(target.label) is covered by \(tag)\(text) (\(ref)). Close or scroll past it first.")
    }

    /// A target in a child frame: its point in the top-level viewport, each frame above letting
    /// it through, and whether a payment provider's frame or a challenge holds it. Keys, which
    /// reach the focused element wherever it is, take one out of view (`onScreen` false).
    private func placeInFrame(_ target: inout ActionTarget, _ ctx: ActionContext, hitTest: Bool, onScreen: Bool = true) async throws {
        guard let address = target.address else { return }
        let layout = try await self.layout(of: ctx.named, ctx.webView, until: ctx.deadline, placing: address)
        guard let path = layout.children.values.first(where: { $0.token == address.document })?.path, let placement = layout.placement(of: path) else {
            throw AgentHub.frameGone(target.ref)
        }
        let local = target.css
        target.css = CGPoint(x: placement.origin.x + local.x * placement.scale, y: placement.origin.y + local.y * placement.scale)
        target.viewport = layout.main.viewport
        let viewport = CGRect(x: 0, y: 0, width: layout.main.viewport.w, height: layout.main.viewport.h)
        guard !onScreen || placement.clip.contains(target.css) && viewport.contains(target.css) else {
            throw AgentToolError(code: "not_in_viewport", message: "\(target.label) is outside the part of its frame the page shows. Scroll the page so the frame shows it.")
        }
        var components = path.split(separator: ".").map(String.init)
        while let last = components.popLast() {
            let parentPath = components.joined(separator: ".")
            let childPath = parentPath.isEmpty ? last : "\(parentPath).\(last)"
            guard let parent = parentPath.isEmpty ? layout.main : layout.children[parentPath], let index = Int(last), let above = layout.placement(of: parentPath) else {
                throw AgentHub.frameGone(target.ref)
            }
            let src = parent.frames.first { $0.index == index }?.src ?? ""
            try note(frame: src, origin: layout.children[childPath].flatMap { origin(of: $0.token, ctx) }, in: &target)
            guard hitTest, let frame = ctx.state.target(for: parent.token) else { continue }
            let x = (target.css.x - above.origin.x) / above.scale
            let y = (target.css.y - above.origin.y) / above.scale
            let hit = try PageProbe.decode(FrameHitReport.self, from: try await ask(ctx.named, ctx.webView, frame, "frameHit", ["x": x, "y": y, "index": index], until: ctx.deadline))
            if let cover = hit.coveredBy { throw covered(target, by: cover, in: parent.token, ctx) }
        }
    }

    /// What a point hits, down into the frames it lands on that Lithium can read.
    private func resolvePoint(_ css: CGPoint, _ ctx: ActionContext, menu: Bool) async throws -> ActionTarget {
        var frame = FrameTarget.main
        var local = css
        var path = ""
        var layout: FrameLayout?
        var inPaymentFrame = false
        var viewport: PageViewport?
        while true {
            let report = try PageProbe.decode(TargetReport.self, from: try await ask(ctx.named, ctx.webView, frame, "target", ["x": local.x, "y": local.y, "menu": menu], until: ctx.deadline))
            if viewport == nil {
                viewport = report.viewport
                guard let viewport, css.x >= 0, css.y >= 0, css.x < viewport.w, css.y < viewport.h else {
                    throw AgentToolError(code: "not_in_viewport", message: "\(Int(css.x)),\(Int(css.y)) is outside \(ctx.named.id)’s viewport (\(Int(report.viewport?.w ?? 0))x\(Int(report.viewport?.h ?? 0))).")
                }
            }
            guard report.gone != true, let id = report.id else {
                throw AgentToolError(code: "not_in_viewport", message: "Nothing of \(ctx.named.id)’s page is at \(Int(css.x)),\(Int(css.y)).")
            }
            let address = ElementAddress(document: report.token, id: id)
            var target = ActionTarget(report: report, address: address, frame: frame, ref: ctx.state.ref(for: address), css: css, viewport: viewport, inPaymentFrame: inPaymentFrame)
            if let src = report.src { try note(frame: src, origin: nil, in: &target) }
            if report.extensionUI == true {
                throw AgentToolError(code: "blocked_extension_ui", message: "\(Int(css.x)),\(Int(css.y)) is on an extension’s UI, which agents can’t use.")
            }
            inPaymentFrame = target.inPaymentFrame
            guard let index = report.frame else { return target }
            if layout == nil { layout = try await self.layout(of: ctx.named, ctx.webView, until: ctx.deadline) }
            let childPath = path.isEmpty ? "\(index)" : "\(path).\(index)"
            // A frame that never said hello (open before agent access was on) is acted on as a whole.
            guard let layout, let child = layout.children[childPath], let placement = layout.placement(of: childPath), let next = ctx.state.target(for: child.token) else { return target }
            try note(frame: "", origin: origin(of: child.token, ctx), in: &target)
            inPaymentFrame = target.inPaymentFrame
            local = CGPoint(x: (css.x - placement.origin.x) / placement.scale, y: (css.y - placement.origin.y) / placement.scale)
            frame = next
            path = childPath
        }
    }

    /// The focused element, down the frames focus went into; the page itself when none has focus.
    private func resolveFocused(_ ctx: ActionContext, checks: Checks) async throws -> ActionTarget {
        let frames = try await askEveryFrame(ctx.named, ctx.webView, "focused", [:], FocusedReport.self, until: ctx.deadline)
        var report = frames.reports[0].0
        var above: [FocusedReport] = []
        while let index = report.frame {
            let path = (report.path ?? "").isEmpty ? "\(index)" : "\(report.path ?? "").\(index)"
            guard index >= 0, let child = frames.reports.first(where: { $0.0.path == path })?.0 else { break }
            above.append(report)
            report = child
        }
        guard let id = report.id, let frame = ctx.state.target(for: report.token) else {
            let unread = report.frame != nil
            if checks.contains(.editable), !unread { throw AgentToolError(code: "not_editable", message: "Nothing is focused in \(ctx.named.id): give the field’s ref.") }
            let main = try PageProbe.decode(TargetReport.self, from: try await ask(ctx.named, ctx.webView, .main, "target", ["x": 0, "y": 0], until: ctx.deadline))
            var target = ActionTarget(report: TargetReport(token: main.token, path: "", role: unread ? "frame" : "page", focused: unread ? true : nil, viewport: main.viewport, counts: main.counts, pay: main.pay, challenge: main.challenge, frames: main.frames), address: nil, frame: .main, ref: nil, css: .zero, viewport: main.viewport)
            guard unread else { return target }
            // Focus went into a frame that never said hello (open before agent access was on):
            // keys go to it whatever it holds. The frames on the way decide as for a point, and
            // one whose origin nobody knows asks.
            for (parent, child) in zip(above, above.dropFirst() + [report]) {
                try note(frame: parent.src ?? "", origin: origin(of: child.token, ctx), in: &target)
            }
            try note(frame: report.src ?? "", origin: report.origin, in: &target)
            target.inUnreadFrame = true
            target.inUnknownFrame = (report.origin ?? "null") == "null"
            return target
        }
        let address = ElementAddress(document: report.token, id: id)
        let target = try PageProbe.decode(TargetReport.self, from: try await ask(ctx.named, ctx.webView, frame, "target", ["id": id, "token": report.token, "scroll": false], until: ctx.deadline))
        if target.gone == true { throw AgentHub.frameGone(nil) }
        var placed = ActionTarget(report: target, address: address, frame: frame, ref: ctx.state.ref(for: address), css: CGPoint(target.point), viewport: target.viewport)
        // Keys reach the focused element wherever it is scrolled: only what it is matters.
        if target.extensionUI == true {
            throw AgentToolError(code: "blocked_extension_ui", message: "The focused element belongs to an extension’s UI, which agents can’t use.")
        }
        if checks.contains(.editable) {
            if target.disabled == true { throw AgentToolError(code: "disabled", message: "\(placed.label) is disabled.") }
            if target.readonly == true { throw AgentToolError(code: "readonly", message: "\(placed.label) is read-only.") }
            if target.editable != true { throw AgentToolError(code: "not_editable", message: "\(placed.label) isn’t a field text can be typed into.") }
        }
        if case .child = frame { try await placeInFrame(&placed, ctx, hitTest: false, onScreen: false) }
        return placed
    }

    /// A frame on the target's way down: a payment provider's makes every action in it a
    /// payment; a challenge's is the user's to solve.
    private func note(frame src: String, origin: String?, in target: inout ActionTarget) throws {
        if paymentProviders.contains(address: src) || paymentProviders.contains(address: origin) { target.inPaymentFrame = true }
        if let kind = AgentChallenge.kind(of: src) ?? origin.flatMap(AgentChallenge.kind(of:)) {
            throw challengeError(AgentChallenge(kind: kind, page: AgentChallenge.pageKinds.contains(kind)))
        }
    }

    private func origin(of document: String, _ ctx: ActionContext) -> String? {
        ctx.state.frames[document].map { "\($0.securityOrigin.protocol)://\($0.securityOrigin.host)\($0.securityOrigin.port == 0 ? "" : ":\($0.securityOrigin.port)")" }
    }

    /// The page's payment facts, every frame together, and a challenge the whole page is.
    private func addPageFacts(to target: inout ActionTarget, _ ctx: ActionContext) async throws {
        var reports = [PayReport(token: target.report.token, path: target.report.path, pay: target.report.pay, challenge: target.report.challenge, frames: target.report.frames)]
        if !ctx.state.frames.isEmpty {
            reports = try await askEveryFrame(ctx.named, ctx.webView, "pay", [:], PayReport.self, until: ctx.deadline).reports.map(\.0)
        }
        let origins = ctx.state.frames.values.map { "\($0.securityOrigin.protocol)://\($0.securityOrigin.host)\($0.securityOrigin.port == 0 ? "" : ":\($0.securityOrigin.port)")" }
        target.page = Guardrails.Page(
            url: ctx.named.tab.url,
            cardField: reports.contains { $0.pay?.cards == true },
            paymentFrame: reports.contains { ($0.frames ?? []).contains { paymentProviders.contains(address: $0) } } || origins.contains { paymentProviders.contains(address: $0) },
            wallet: reports.contains { $0.pay?.wallet == true },
            providers: paymentProviders
        )
        if let kind = reports.first(where: { ($0.path ?? "") == "" })?.challenge {
            throw challengeError(AgentChallenge(kind: kind, page: true))
        }
    }

    private func challengeError(_ challenge: AgentChallenge) -> AgentToolError {
        AgentToolError(code: "challenge_requires_user", message: "That is a \(challenge.label). Lithium doesn’t solve these: ask the user to complete it in Lithium, then call wait_for (text, url or load) and go on.")
    }

    private static func frameGone(_ ref: String?) -> AgentToolError {
        AgentToolError(code: "frame_gone", message: "The frame \(ref ?? "the element") is in has gone. Call snapshot for current refs.")
    }

    // MARK: Guardrails

    /// What an action's events do to the page, as Guardrails weighs them.
    enum Delivery {
        /// Pointer moves and the wheel: nothing is pressed.
        case pointer
        /// A button pressed and let go: a click on what it lands on, whatever the tool. A drag's
        /// press and release land on two elements, and the stricter decides. A right click
        /// opens the page's menu and activates nothing.
        case press(on: [ActionTarget], NativeInput.Button)
        /// Keys or text into the target, `action` as `ActionTarget.guarded` decides it.
        case keys(into: ActionTarget, Guardrails.Action, submitting: TargetReport.Form?)
        /// A change made without input events: an option chosen.
        case change(ActionTarget, Guardrails.Action)
    }

    /// What `gate` let an action send, and how the user allowed it.
    struct Gate {
        var sends: NativeInput.Sends = []
        var grant: JSONValue = .null
    }

    /// The one way to an action's events (design section 7.3): each step of `steps` asks the
    /// user's Allow when Guardrails decides it needs one, as `click` and `type` decide it, before
    /// any event; and text is logged only once every field it goes to is one typing there
    /// wouldn't ask for, in a frame Lithium can read. One Allow covers the steps of an action
    /// (typing a password, then submitting its form), but a payment submit always asks.
    func gate(_ steps: [(Delivery, describing: String)], _ ctx: ActionContext) async throws -> Gate {
        var gate = Gate()
        var asked: Set<ConfirmationKind> = []
        // Decided on the fields alone, before any Allow: a key the user denies is logged as one
        // they allowed would be. An option chosen is logged as text typed there would be.
        let fields = steps.compactMap { step -> ActionTarget? in
            switch step.0 {
            case .keys(let target, _, _), .change(let target, .select): target
            default: nil
            }
        }
        if !fields.isEmpty {
            AgentHub.callNotes?.noteFields(unguarded: fields.allSatisfy { !$0.inUnreadFrame && Guardrails.confirmation(for: .type, on: $0.element, page: $0.page) == nil })
        }
        for (delivery, describing) in steps {
            let weighed: [(action: Guardrails.Action, target: ActionTarget, form: TargetReport.Form?)]
            switch delivery {
            case .pointer:
                gate.sends.insert(.pointer)
                continue
            case .press(let targets, let button):
                gate.sends.formUnion([.pointer, .buttons])
                guard button != .right else { continue }
                weighed = targets.map { ($0.guarded(.click).action, $0, $0.guarded(.click).submitting) }
            case .keys(let target, let action, let form):
                gate.sends.insert(.keys)
                weighed = [(action, target, form)]
            case .change(let target, let action):
                weighed = [(action, target, nil)]
            }
            let kinds = weighed.map { Guardrails.confirmation(for: $0.action, on: $0.target.element, page: $0.target.page, submitting: $0.form.map(Guardrails.Form.init)) }
            guard let strictest = kinds.indices.max(by: { Self.strictness(kinds[$0]) < Self.strictness(kinds[$1]) }), let kind = kinds[strictest] else { continue }
            let (action, target, form) = weighed[strictest]
            if asked.contains(kind), kind != .payment || form == nil { continue }
            let grant = try await allow(action, on: target, submitting: form, describing, ctx)
            asked.insert(kind)
            if grant != .null { gate.grant = grant }
        }
        return gate
    }

    private static func strictness(_ kind: ConfirmationKind?) -> Int {
        switch kind {
        case .payment: 2
        case nil: 0
        default: 1
        }
    }

    /// The user's Allow for `action` on `target` when Guardrails asks for one (design section
    /// 7.3), before any event. Null when the action is free, else how it was allowed: once, by a
    /// site grant, or by the Allow given on the same form in the last 2 minutes (typing into a
    /// card number, then its expiry and CVC).
    private func allow(_ action: Guardrails.Action, on target: ActionTarget, submitting form: TargetReport.Form?, _ describing: String, _ ctx: ActionContext) async throws -> JSONValue {
        let submitted = form.map(Guardrails.Form.init)
        guard let kind = Guardrails.confirmation(for: action, on: target.element, page: target.page, submitting: submitted) else { return .null }
        let fieldEntry: Bool = switch action {
        case .type, .select, .check: true
        case .press(let enter): !enter
        case .activate: false
        }
        let form = target.report.form.map { ElementAddress(document: target.report.token, id: $0.id) }
        let host = ctx.named.tab.url?.host() ?? ""
        let (asking, subject) = (describing + (host.isEmpty ? "" : " on \(host)"), "\(describing) \(target.label)")
        let prompt = AgentTab.prompt(kind, asking, subject: subject)
        // The action run again (`AgentHub.action`) takes the answer its last attempt got, once,
        // not the form cover that answer made.
        if let grant = ctx.state.answered.removeValue(forKey: prompt) { return .string(grant.rawValue) }
        ctx.state.formCovers.removeAll { $0.until <= .now }
        if fieldEntry, let form, ctx.state.formCovers.contains(where: { $0.form == form && $0.session == ctx.session.id && $0.kind == kind }) {
            return "form"
        }
        let grant = try await confirm(kind, asking, subject: subject, site: host.isEmpty ? nil : SiteInfo.registrable(host), in: ctx.named, session: ctx.session, until: ctx.deadline)
        if fieldEntry, let form { ctx.state.formCovers.append(FormCover(form: form, session: ctx.session.id, kind: kind, until: .now + .seconds(120))) }
        ctx.state.answered[prompt] = grant
        return .string(grant.rawValue)
    }

    // MARK: Delivering

    /// Sends the action's events, then waits until the page has handled them (design section
    /// 5.3): it counted the last of them, then one rendering update. A page load they started
    /// within 50 ms is followed as far as `wait`; new tabs, a dialog, a download and a file
    /// chooser the action caused are in the result, with the viewport's diff. Only what `gate`
    /// let through is sent.
    func deliver(_ ctx: ActionContext, _ target: ActionTarget, _ gate: Gate, wait: LoadWait, diff: Bool, fields: [String: JSONValue] = [:], _ send: (NativeInput) async throws -> Settle) async throws -> JSONValue {
        // While the user answered, the page may have moved the element, or the user selected the
        // tab and its web view left the stage: the action places its target again, every check
        // with it, and their answers stand.
        guard ctx.webView.window === target.window, ctx.state.prompts == target.prompts else { throw NativeInput.WindowChanged(afterPress: false) }
        try checkNetworkIdle(wait)
        let tab = ctx.named.tab
        let since = LoadProgress(of: tab, ctx.state)
        let choosers = ctx.state.fileChoosersCancelled
        // A download the events start is the agent's, and asks the user.
        ctx.state.drive = AgentDrive(session: ctx.session, marks: tab.loadMarks, deadline: ctx.deadline)
        defer { if !tab.isLoading { ctx.state.drive = nil } }
        let input = try NativeInput(webView: ctx.webView, sends: gate.sends, check: { try self.checkStillWaitable(ctx.named, ignoringDialog: true) }, onPointer: { point in
            ctx.state.acting?.pointer = point
        })
        var settle: Settle?
        do {
            settle = try await send(input)
        } catch let change as NativeInput.WindowChanged where change.afterPress {
            // The press went through before the user moved the tab: the action happened.
        } catch {
            input.release()
            throw error
        }
        var result = fields.filter { $0.value != .null }
        if gate.grant != .null { result["grant"] = gate.grant }
        result["tab"] = .string(ctx.named.id)
        if let ref = target.ref { result["ref"] = .string(ref) }
        do {
            // A load the events start within 50 ms is followed: the page holds its answer that
            // long, timed in the page, as a timer of Lithium's in the background fires late.
            if let settle { try await self.settle(ctx, target.frame, settle, timeout: 1000, frame: true, hold: 50, since: since) }
            var page: JSONValue?
            if since.hasMoved(tab, ctx.state) {
                do {
                    // `none`: the load has started, and nothing more is known, as for navigate.
                    page = wait == .none ? self.page(ctx.named, reached: LoadWait.none) : try await follow(since, in: ctx.named, wait: wait, deadline: ctx.deadline, timeout: ctx.timeout, landedWithinPage: nil)
                } catch let error as AgentToolError where error.code == "navigation_cancelled" {
                    // The load the events started was given up before it showed anything (a 204
                    // answer): the action happened, and the page stayed.
                    guard case .dropped? = tab.lastUnshownLoad else { throw error }
                }
            }
            // The requests the action sent (a Save button's fetch), which WebKit reports a moment
            // after the page handled the events: quiet is counted from now, not from before.
            if page == nil, wait == .networkidle {
                try await waitForNetworkIdle(ctx.named, after: .now, deadline: ctx.deadline, timeout: ctx.timeout)
            }
            if let page {
                result.merge(page.object ?? [:]) { _, new in new }
                result["navigated"] = .bool(page["download"] == nil)
                if diff, wait > .commit, page["download"] == nil { result = try await addingDiff(to: .object(result), of: ctx.named, for: ctx.session, if: true, until: ctx.deadline).object ?? result }
            } else {
                result["navigated"] = .bool(tab.sameDocumentNavigations > since.moves)
                if diff { result = try await addingDiff(to: .object(result), of: ctx.named, for: ctx.session, if: true, until: ctx.deadline).object ?? result }
            }
        } catch let error as AgentToolError where error.code == "dialog_open" {
            // The page opened a dialog in answer: the action is done, and its result names it.
        }
        if let dialog = ctx.state.dialog { result["dialog"] = dialog.json }
        let opened = ctx.state.opened.filter(isOpen)
        if !opened.isEmpty {
            result["newTabs"] = .array(opened.map { ["tab": .string(id(for: $0)), "url": .string($0.url?.absoluteString ?? ""), "openedBy": .string(ctx.named.id)] })
        }
        if ctx.state.fileChoosersCancelled > choosers, ctx.state.armedUpload == nil {
            throw AgentToolError(code: "file_chooser_opened", message: "The action opened a file chooser, which Lithium cancelled: use upload_files.")
        }
        touch(tab)
        return .object(result)
    }

    /// Waits in the page until it has seen the events `settle` names; with `frame`, then one
    /// rendering update. A page that never sees them (it stopped them before Lithium's listener)
    /// holds the action no longer than `timeout` milliseconds. A document on its way out never
    /// answers: a load that started `since` ends the wait, as does the frame going.
    /// Returns the frame's counts of trusted events once it answered.
    @discardableResult
    func settle(_ ctx: ActionContext, _ frame: FrameTarget, _ settle: Settle, timeout: Int, frame rendered: Bool, hold: Int = 0, since: LoadProgress? = nil) async throws -> [String: Int] {
        let args: [String: Any] = ["type": settle.type, "count": settle.count, "timeoutMs": timeout, "scrolled": settle.scrolled, "frame": rendered, "hold": hold]
        let pending = start(ctx.webView, frame, "settle", args)
        let (tab, state) = (ctx.named.tab, ctx.state)
        let done = try await watch(ctx.named, until: ctx.deadline) { () -> Bool? in
            if pending.result != nil { return true }
            // A load under way before the action that commits takes the document too.
            return since.map { $0.hasMoved(tab, state) || tab.commits > $0.commits } == true ? true : nil
        }
        if done == nil { throw timedOut(ctx.named, after: ctx.timeout, "its page didn’t handle the agent’s input: a script may be keeping it busy") }
        let report = (try? pending.result?.get()).flatMap { try? PageProbe.decode(SettleReport.self, from: $0) }
        if let unseen = settle.unseen, report?.seen == false {
            throw AgentToolError(code: "unsupported", message: unseen)
        }
        return report?.counts ?? [:]
    }

    /// Text no key types, inserted once the page has seen the keys typed before it: an
    /// insertion overtakes key events still queued (design section 3, item 12). `inserted`
    /// becomes the page's `beforeinput` count once it has the text, counted from what the keys
    /// before it fired, as a key that types fires one too.
    func insert(_ pending: inout String, _ input: NativeInput, _ ctx: ActionContext, _ target: ActionTarget, keys: Int, inserted: inout Int) async throws {
        guard !pending.isEmpty else { return }
        let counts = try await settle(ctx, target.frame, Settle(type: "keyup", count: keys), timeout: 1000, frame: false)
        try input.insert(pending)
        inserted = max(inserted, counts["beforeinput"] ?? 0) + 1
        pending = ""
        try await settle(ctx, target.frame, Settle(type: "beforeinput", count: inserted), timeout: 1000, frame: false)
    }

    /// The size of the page area the user sees, which background pages are laid out at.
    var pageAreaSize: CGSize {
        browser?.selectedTab?.loadedWebView.flatMap { $0.userWindow == nil ? nil : $0.bounds.size } ?? CGSize(width: 1280, height: 800)
    }
}

private extension CGPoint {
    init(_ values: [Double]?) {
        self.init(x: values?.first ?? 0, y: values?.dropFirst().first ?? 0)
    }
}

extension Arguments {
    func number(_ key: String) throws -> Double? {
        guard let field = value[key], field != .null else { return nil }
        switch field {
        case .int(let number): return Double(number)
        case .double(let number) where number.isFinite: return number
        default: throw Self.invalid("\(key) must be a number.")
        }
    }

    func strings(_ key: String) throws -> [String]? {
        guard let field = value[key], field != .null else { return nil }
        guard case .array(let items) = field, items.allSatisfy({ $0.string != nil }) else { throw Self.invalid("\(key) must be a list of strings.") }
        return items.compactMap(\.string)
    }

    func ref(key: String = "ref") throws -> String? {
        guard let ref = try optionalString(key) else { return nil }
        guard AgentTab.isRef(ref) else { throw Self.invalid("\(key) must be a ref from snapshot, such as e9 or f2:e7.") }
        return ref
    }

    func point() throws -> AgentHub.TargetSpec? {
        let x = try number("x")
        let y = try number("y")
        guard x != nil || y != nil else { return nil }
        guard let x, let y else { throw Self.invalid("Give both x and y.") }
        return .point(CGPoint(x: x, y: y))
    }

    /// `ref`, or `x` and `y`, at the top level or in the object under `key` (drag's from and to),
    /// which may also be a ref string.
    func target(in key: String? = nil) throws -> AgentHub.TargetSpec {
        if let key {
            guard let field = value[key] else { throw Self.invalid("\(key) is required: a ref, or {\"x\": …, \"y\": …}.") }
            if let ref = field.string {
                guard AgentTab.isRef(ref) else { throw Self.invalid("\(key) must be a ref from snapshot, such as e9, or {\"x\": …, \"y\": …}.") }
                return .ref(ref)
            }
            guard field.object != nil else { throw Self.invalid("\(key) must be a ref, or {\"x\": …, \"y\": …}.") }
            return try Arguments(value: field).target()
        }
        let ref = try self.ref()
        let point = try self.point()
        switch (ref, point) {
        case (let ref?, nil): return .ref(ref)
        case (nil, let point?): return point
        case (nil, nil): throw Self.invalid("Give ref, or x and y.")
        default: throw Self.invalid("Give ref or x and y, not both.")
        }
    }

    func modifiers() throws -> NSEvent.ModifierFlags {
        guard let names = try strings("modifiers") else { return [] }
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name {
            case "Meta": flags.insert(.command)
            case "Shift": flags.insert(.shift)
            case "Alt": flags.insert(.option)
            case "Control": flags.insert(.control)
            default: throw Self.invalid("modifiers must be among Meta, Shift, Alt and Control.")
            }
        }
        return flags
    }
}
