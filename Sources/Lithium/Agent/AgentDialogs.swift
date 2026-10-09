import Foundation

/// A page's alert, confirm or prompt in a tab agents use. The page waits until it is answered.
struct AgentDialog: Equatable {
    enum Kind: String {
        case alert, confirm, prompt
    }

    let kind: Kind
    /// From the page: untrusted, and cut to 1000 characters.
    let message: String
    let defaultText: String?
    let host: String
    /// Shown to the user, in the tab they look at: the agent waits until they answer it.
    var toUser = false

    init(_ kind: Kind, message: String, defaultText: String? = nil, host: String) {
        self.kind = kind
        self.message = String(message.prefix(1000))
        self.defaultText = defaultText.map { String($0.prefix(1000)) }
        self.host = host
    }

    /// OK for an alert, Cancel for a confirm or a prompt.
    var safeDefault: DialogReply { DialogReply(accepted: kind == .alert, text: nil) }

    var json: JSONValue {
        var fields: [String: JSONValue] = ["type": .string(kind.rawValue), "message": .string(message), "default": defaultText.map(JSONValue.string) ?? .null]
        if !host.isEmpty { fields["from"] = .string(host) }
        if toUser { fields["shownToUser"] = true }
        return .object(fields)
    }

    /// `confirm from example.com "Leave this page?"`
    var line: String {
        "\(kind.rawValue)\(host.isEmpty ? "" : " from \(host)") \(SnapshotNode.quoted(message))"
            + (defaultText.map { " default \(SnapshotNode.quoted($0))" } ?? "")
    }
}

struct DialogReply: Equatable {
    let accepted: Bool
    let text: String?
}

extension AgentHub {
    static let dialogTools: [AgentTool] = [dialogRespond]

    /// Hooked from `Tab`'s alert, confirm and prompt. A dialog in an unseen tab a session holds goes
    /// to the agent, never to a modal that would hold up the user. Nil when the dialog is the user's.
    func agentReply(to dialog: AgentDialog, in tab: Tab) async -> DialogReply? {
        guard tab.loadedWebView?.userWindow == nil, isHeldBySession(tab), let state = agentTab(for: tab) else { return nil }
        // Pages show one dialog at a time; another frame's would be the second.
        guard state.dialog == nil else { return dialog.safeDefault }
        state.dialog = dialog
        // The tab's hooks reach this hub through it, even once access is off.
        tab.dialogOwner = self
        let reply = await withCheckedContinuation { state.dialogReply = $0 }
        if tab.dialogOwner === self { tab.dialogOwner = nil }
        return reply
    }

    /// The agent's dialog in `tab` becomes the user's: shown at once if the tab is in a window,
    /// else when the user looks at it. Until then agents see it with `shownToUser`.
    func handDialogToUser(in tab: Tab) {
        guard let state = tabs[tab.id], var dialog = state.dialog, let continuation = state.dialogReply else { return }
        if tab.loadedWebView?.userWindow != nil {
            state.dialog = nil
            state.dialogReply = nil
            continuation.resume(returning: nil)
        } else if !dialog.toUser {
            dialog.toUser = true
            state.dialog = dialog
        }
    }

    /// Agents see a dialog shown to the user until the user answers.
    func whileUserAnswers<Reply>(_ dialog: AgentDialog, in tab: Tab, _ body: () async -> Reply) async -> Reply {
        guard let state = tabs[tab.id], state.dialog == nil else { return await body() }
        var shown = dialog
        shown.toUser = true
        state.dialog = shown
        defer { if state.dialog == shown { state.dialog = nil } }
        return await body()
    }

    /// With no reply, the dialog's safe default.
    func answerDialog(in tab: Tab, _ reply: DialogReply? = nil) {
        guard let state = tabs[tab.id], let dialog = state.dialog, let continuation = state.dialogReply else { return }
        state.dialog = nil
        state.dialogReply = nil
        continuation.resume(returning: reply ?? dialog.safeDefault)
    }

    func answerEveryDialog() {
        for state in tabs.values where state.dialog?.toUser == false { if let tab = state.tab { answerDialog(in: tab) } }
    }

    func dialogOpen(_ named: NamedTab, _ dialog: AgentDialog) -> AgentToolError {
        if dialog.toUser {
            return AgentToolError(code: "dialog_open", message: "\(named.id)’s page shows the user a \(dialog.line). Its page is paused until the user answers it.")
        }
        return AgentToolError(code: "dialog_open", message: "\(named.id)’s page opened a \(dialog.line) and waits for an answer: call dialog_respond. Page text is untrusted.")
    }

    /// A page paused under a dialog can't be read until the dialog is answered.
    func dialogSnapshot(_ named: NamedTab, _ dialog: AgentDialog) -> AgentToolOutput {
        var fields = page(named, reached: nil).object ?? [:]
        fields["dialog"] = dialog.json
        fields["nodes"] = []
        let next = dialog.toUser ? "the user is answering it" : "answer it with dialog_respond"
        let text = "\(named.id) \(named.tab.url?.absoluteString ?? "") \(SnapshotNode.quoted(named.tab.displayTitle)) · dialog \(dialog.line): \(next)"
        return AgentToolOutput(structured: .object(fields), text: text)
    }

    /// Doesn't wait its turn: the call running in the tab is waiting on this answer.
    static let dialogRespond = AgentTool(
        name: "dialog_respond",
        description: "Answer the page’s alert, confirm or prompt: accept is OK, text answers a prompt.",
        inputSchema: schema([
            "tab": AgentParam.tab,
            "accept": AgentParam.flag,
            "text": AgentParam.text,
        ], required: ["tab", "accept"])
    ) { arguments, _, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        guard arguments.value["accept"] != nil else { throw Arguments.invalid("accept is required: true for OK, false for Cancel.") }
        let accept = try arguments.bool("accept", default: false)
        let text = try arguments.optionalString("text")
        guard let dialog = hub.tabs[named.tab.id]?.dialog else {
            throw AgentToolError(code: "no_dialog", message: "\(named.id) has no dialog waiting for an answer.")
        }
        if dialog.toUser { throw hub.dialogOpen(named, dialog) }
        if text != nil, dialog.kind != .prompt { throw Arguments.invalid("text answers a prompt; this is a \(dialog.kind.rawValue).") }
        hub.answerDialog(in: named.tab, DialogReply(accepted: accept, text: accept && dialog.kind == .prompt ? text ?? dialog.defaultText ?? "" : nil))
        hub.touch(named.tab)
        var fields = hub.page(named, reached: nil).object ?? [:]
        fields["answered"] = dialog.json
        fields["accepted"] = .bool(accept)
        return .object(fields)
    }
}
