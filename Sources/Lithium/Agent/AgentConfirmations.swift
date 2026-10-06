import AppKit
import Observation

/// One Allow or Deny the user is asked, in a banner over the page (design section 7.3).
struct AgentConfirmation: Identifiable, Equatable {
    let id = UUID()
    let kind: ConfirmationKind
    /// The session that asked, by its `Mcp-Session-Id`, its label and its self-reported name.
    let session: String
    let sessionLabel: String
    let client: String
    /// The tab it is about; nil for a tab not open yet (`tab_open` of a file).
    let tabID: Tab.ID?
    /// What the user is asked to allow, as the banner says it: "open notes.html".
    let action: String
    /// The registrable domain a site grant covers; nil for a `file:` address, which has none.
    let site: String?

    var offersSiteGrant: Bool { kind.allowsSiteGrant && site != nil }
}

/// "Allow on this site until the agent stops": one kind of action, on one site, for one session.
struct AgentGrant: Identifiable, Hashable {
    let session: String
    let sessionLabel: String
    let site: String
    let kind: ConfirmationKind

    var id: String { "\(session) \(site) \(kind.rawValue)" }
}

enum ConfirmationAnswer: Equatable {
    case allowOnce, allowOnSite, deny
    /// The user navigated or closed the tab, or the session ended: nobody needs the answer.
    case cancelled
}

/// The prompts waiting for the user and the site grants given, in memory only: grants end with
/// their session, on Stop, and when Lithium quits. One banner per tab at a time; the rest wait
/// their turn. Modeled on `SitePermissions`, but nothing here is remembered.
@MainActor
@Observable
final class AgentConfirmations {
    /// A confirmation no call waits on (a download after `wait: none`) is denied after this.
    static let timeout: Duration = .seconds(120)

    private(set) var pending: [AgentConfirmation] = []
    private(set) var grants: [AgentGrant] = []
    /// Answers given, until the wait on each takes it.
    private(set) var answers: [AgentConfirmation.ID: ConfirmationAnswer] = [:]

    func grant(for kind: ConfirmationKind, site: String?, session: String) -> AgentGrant? {
        guard kind.allowsSiteGrant, let site else { return nil }
        return grants.first { $0.session == session && $0.site == site && $0.kind == kind }
    }

    func ask(_ confirmation: AgentConfirmation) {
        pending.append(confirmation)
    }

    /// The user's answer, or one Lithium gives for them. Only the first counts.
    func answer(_ id: AgentConfirmation.ID, _ answer: ConfirmationAnswer) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let confirmation = pending.remove(at: index)
        answers[id] = answer
        if answer == .allowOnSite, confirmation.offersSiteGrant, let site = confirmation.site {
            let grant = AgentGrant(session: confirmation.session, sessionLabel: confirmation.sessionLabel, site: site, kind: confirmation.kind)
            if !grants.contains(grant) { grants.append(grant) }
        }
    }

    /// The wait on it is over, answered or not.
    func finish(_ id: AgentConfirmation.ID) {
        pending.removeAll { $0.id == id }
        answers[id] = nil
    }

    func cancel(tab: Tab.ID) {
        pending.filter { $0.tabID == tab }.forEach { answer($0.id, .cancelled) }
    }

    /// The session ended (Stop, disconnect, access off): its grants go, its prompts are cancelled.
    func end(session: String) {
        grants.removeAll { $0.session == session }
        pending.filter { $0.session == session }.forEach { answer($0.id, .cancelled) }
    }

    func revoke(_ grant: AgentGrant) {
        grants.removeAll { $0 == grant }
    }

    /// The banner shows the selected tab's first prompt, else the oldest.
    func front(selected: Tab.ID?) -> AgentConfirmation? {
        pending.first { $0.tabID != nil && $0.tabID == selected } ?? pending.first
    }

    func isAsking(about tab: Tab.ID, _ kind: ConfirmationKind) -> Bool {
        pending.contains { $0.tabID == tab && $0.kind == kind }
    }
}

/// How an action was allowed: once, or by a site grant.
enum ConfirmationGrant: String {
    case once, site
}

/// What a file chooser opened in a tab the agent drives gets instead of the user's panel.
enum AgentOpenPanel: Equatable {
    case files([URL])
    case cancelled
}

extension AgentHub {
    /// Asks the user to allow `action`, unless the session's grant for the site covers it, and
    /// waits for the answer within `deadline` and `AgentConfirmations.timeout`. Deny is
    /// `denied_by_user`, no answer `confirmation_timeout`; the tab closing, the user navigating it,
    /// Stop and the session ending end the wait as they end any other. Every prompt and its
    /// answer goes in the log. In benchmark mode a `script` prompt is answered Allow once
    /// without a banner, and logged as such.
    func confirm(_ kind: ConfirmationKind, _ action: String, subject: String, site: String?, in named: NamedTab?, session: MCPSession, until deadline: ContinuousClock.Instant) async throws -> ConfirmationGrant {
        let started = Date()
        var logged: (answer: String, grant: ConfirmationGrant?) = ("cancelled", nil)
        var benchmark = false
        defer {
            let entry = confirmationEntry(kind, subject: subject, site: site, tab: named?.id, session: session, answer: logged, benchmark: benchmark, waited: Date().timeIntervalSince(started))
            Task { await self.log.append(entry, at: started) }
        }
        // Stop, or the session ending, refuses whatever it would still ask.
        guard sessions.contains(where: { $0.id == session.id }) else {
            logged.answer = "agent_stopped"
            throw AgentToolError(code: "agent_stopped", message: "This agent session has ended.")
        }
        if confirmations.grant(for: kind, site: site, session: session.id) != nil {
            logged = ("allow", .site)
            return .site
        }
        if kind == .script, scriptsAutoAllowedUntil() != nil {
            (logged, benchmark) = (("allow", .once), true)
            return .once
        }
        let request = AgentConfirmation(
            kind: kind, session: session.id, sessionLabel: session.label, client: session.clientName,
            tabID: named?.tab.id, action: action, site: kind.allowsSiteGrant ? site : nil
        )
        confirmations.ask(request)
        if let named { tabs[named.tab.id]?.prompts += 1 }
        defer { confirmations.finish(request.id) }
        if NSApp?.isActive == false, NSApp.activationPolicy() == .regular { NSApp.requestUserAttention(.informationalRequest) }
        let limit = min(deadline, .now + AgentConfirmations.timeout)
        let answer: ConfirmationAnswer?
        do {
            answer = try await AgentWait.until(limit) { () -> ConfirmationAnswer? in
                if let named { try self.checkStillWaitable(named) }
                return self.confirmations.answers[request.id]
            }
        } catch let error as AgentToolError {
            logged.answer = error.code
            throw error
        } catch {
            logged.answer = "stopped"
            throw error
        }
        let waited = Int(Date().timeIntervalSince(started))
        switch answer {
        case .allowOnce:
            logged = ("allow", .once)
            return .once
        case .allowOnSite:
            logged = ("allow", kind.allowsSiteGrant && site != nil ? .site : .once)
            return logged.grant ?? .once
        case .deny:
            logged.answer = "deny"
            throw AgentToolError(code: "denied_by_user", message: "The user denied: \(action).")
        case .cancelled:
            if let named { try checkStillWaitable(named) }
            throw AgentToolError(code: "user_interrupted", message: "The user moved on before answering: \(action).")
        case nil:
            logged.answer = "timeout"
            throw AgentToolError(code: "confirmation_timeout", message: "The user didn’t answer within \(waited) s: \(action). Ask the user, then try again with a longer timeoutMs.")
        }
    }

    private func confirmationEntry(_ kind: ConfirmationKind, subject: String, site: String?, tab: String?, session: MCPSession, answer: (answer: String, grant: ConfirmationGrant?), benchmark: Bool, waited: TimeInterval) -> [String: JSONValue] {
        var confirmation: [String: JSONValue] = ["kind": .string(kind.rawValue), "answer": .string(answer.answer), "waitedMs": .int(Int(waited * 1000))]
        if let grant = answer.grant { confirmation["grant"] = .string(grant.rawValue) }
        if benchmark { confirmation["allowedBy"] = "benchmark mode" }
        var entry: [String: JSONValue] = [
            "event": "confirmation",
            "session": ["id": .string(session.label), "client": .string(session.clientName), "version": .string(session.clientVersion), "selfReported": true],
            "subject": .string(AgentURLs.redacted(subject)),
            "confirmation": .object(confirmation),
        ]
        if let site { entry["site"] = .string(site) }
        if let tab { entry["tab"] = ["id": .string(tab)] }
        noteInPanel(AgentLogLine(date: Date().addingTimeInterval(-waited), session: session.label, tool: "confirm \(kind.rawValue)" + (benchmark ? " (benchmark mode)" : ""), tab: tab, host: site, error: answer.answer == "allow" ? nil : answer.answer))
        return entry
    }

    /// `file:` addresses ask each time; other addresses agents may open go through, and the
    /// rest are `blocked_page`. `named` is the tab the address loads in, nil for a tab not open yet.
    func checkOpenable(_ url: URL, in named: NamedTab?, session: MCPSession? = AgentHub.callSession, until deadline: ContinuousClock.Instant) async throws {
        try checkNotBlocked(url)
        guard AgentURLs.verdict(for: url) == .needsConfirmation else { return }
        guard let session else { throw AgentToolError(code: "denied_by_user", message: "file: addresses need the user’s Allow.") }
        let name = url.lastPathComponent.isEmpty ? url.path() : url.lastPathComponent
        _ = try await confirm(.file, "open the local file “\(name)” (its folder becomes readable to the page)", subject: url.absoluteString, site: nil, in: named, session: session, until: deadline)
    }

    func checkNotBlocked(_ url: URL) throws {
        if case .blocked(let reason) = AgentURLs.verdict(for: url) { throw AgentToolError(code: "blocked_page", message: reason) }
    }

    // MARK: Downloads

    /// Hooked from `Tab` before a download starts. One the agent started (its navigation still
    /// under way, and from PR 5 its input, for a session still connected) waits for the user's
    /// Allow: true to download, false to cancel. Nil: not the agent's, so Lithium goes on as for
    /// the user's own. The call that started it, if it still waits, learns the answer.
    func confirmDownload(in tab: Tab, fileName: String?, size: Int64?, from url: URL?) async -> Bool? {
        guard let state = tabs[tab.id], let drive = drive(of: tab) else { return nil }
        let named = NamedTab(tab: tab, id: id(for: tab))
        let host = url?.host() ?? ""
        let file = fileName.map { "“\($0)”" } ?? "a file"
        let bytes = size.flatMap { $0 > 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil }.map { " (\($0))" } ?? ""
        let action = "download \(file)\(bytes)" + (host.isEmpty ? "" : " from \(host)")
        let deadline = state.isBusy && drive.deadline > .now ? drive.deadline : .now + AgentConfirmations.timeout
        let outcome: Result<ConfirmationGrant, AgentToolError>
        do {
            outcome = .success(try await confirm(.download, action, subject: url?.absoluteString ?? "", site: host.isEmpty ? nil : SiteInfo.registrable(host), in: named, session: drive.session, until: deadline))
        } catch let error as AgentToolError {
            outcome = .failure(error)
        } catch {
            outcome = .failure(AgentToolError(code: "agent_stopped", message: "The user stopped agents in Lithium."))
        }
        state.downloadAnswer = outcome
        state.downloadAnswers += 1
        return (try? outcome.get()) != nil
    }

    // MARK: Uploads

    /// Asks the user to let the page have `files` (design section 5.4) and arms the tab's file
    /// chooser with them, for one use within 5 seconds. `upload_files` (PR 5) clicks the input next.
    func confirmUpload(_ files: [URL], in named: NamedTab, session: MCPSession, until deadline: ContinuousClock.Instant) async throws -> ConfirmationGrant {
        guard !files.isEmpty else { throw Arguments.invalid("paths must name at least one file.") }
        var described: [String] = []
        for file in files {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey])
            guard file.isFileURL, values?.isRegularFile == true, values?.isReadable == true else {
                throw Arguments.invalid("\(file.path()) isn’t a file Lithium can read.")
            }
            described.append("\(file.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)))")
        }
        let folders = Set(files.map { $0.deletingLastPathComponent().path(percentEncoded: false) })
        let host = named.tab.url?.host() ?? ""
        let action = "upload \(described.joined(separator: ", ")) from \(folders.sorted().joined(separator: ", "))" + (host.isEmpty ? "" : " to \(host)")
        let subject = files.map(\.lastPathComponent).joined(separator: ", ")
        let state = agentTab(for: named.tab)
        // The action run again (`AgentHub.action`) takes the answer its last attempt got, once.
        let prompt = AgentTab.prompt(.upload, action, subject: subject)
        let grant: ConfirmationGrant
        if let given = state?.answered.removeValue(forKey: prompt) {
            grant = given
        } else {
            grant = try await confirm(.upload, action, subject: subject, site: host.isEmpty ? nil : SiteInfo.registrable(host), in: named, session: session, until: deadline)
            state?.answered[prompt] = grant
        }
        state?.armedUpload = (files, .now + .seconds(5))
        return grant
    }

    /// Hooked from `Tab.runOpenPanelWith`. Files the user allowed for the agent answer it once,
    /// within 5 seconds of the Allow. A chooser the agent's own action opened without them is
    /// cancelled and noted, never shown: an agent can't use the user's panel. Nil: the user's
    /// chooser, shown as before.
    func openPanel(for tab: Tab) -> AgentOpenPanel? {
        guard let state = tabs[tab.id] else { return nil }
        if let armed = state.armedUpload {
            state.armedUpload = nil
            if armed.expires > .now { return .files(armed.files) }
        }
        // The user can't click in a tab out of sight; in the one shown, only the agent's input counts.
        let unseen = state.isBusy && tab.loadedWebView?.userWindow == nil
        guard unseen || drive(of: tab) != nil else { return nil }
        state.fileChoosersCancelled += 1
        return .cancelled
    }
}
