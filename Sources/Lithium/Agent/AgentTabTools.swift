import AppKit
import WebKit

/// Agents' short names for tabs: `t1`, `t2`, … in the order agents first see them, never reused
/// during a run. Keyed by `Tab.id`, which a tab keeps while it sleeps.
struct AgentTabIDs {
    private var next = 1
    private var ids: [Tab.ID: String] = [:]
    private var tabs: [String: Tab.ID] = [:]
    /// When each closed tab went, for the error a later call gets.
    private(set) var closed: [String: Date] = [:]

    mutating func id(for tab: Tab.ID) -> String {
        if let id = ids[tab] { return id }
        let id = "t\(next)"
        next += 1
        ids[tab] = id
        tabs[id] = tab
        return id
    }

    func tabID(for id: String) -> Tab.ID? {
        tabs[id]
    }

    mutating func retire(_ tab: Tab.ID, at date: Date) {
        guard let id = ids.removeValue(forKey: tab) else { return }
        tabs[id] = nil
        closed[id] = date
    }
}

/// A tab with the id the agent named it by, kept for the whole call: once the tab closes its id
/// is retired, and every message about it still names the id the agent knows.
@MainActor
struct NamedTab {
    let tab: Tab
    let id: String

    var closedError: AgentToolError {
        AgentToolError(code: "tab_closed", message: "\(id) was closed while the agent waited on it.")
    }
}

/// What ends an agent call running in a tab before it is done.
enum AgentInterruption {
    /// The user navigated the tab (address bar, Back, Forward, Reload, Stop).
    case user
    /// An agent called `stop` on the tab.
    case agentStop
}

/// How far a navigation has to get before the tool answers.
enum LoadWait: String, Comparable, CaseIterable {
    case none, commit, domcontentloaded, load

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// A tool's arguments, checked at the boundary: a wrong or missing one is `invalid_params`.
private struct Arguments {
    let value: JSONValue

    func string(_ key: String) throws -> String {
        guard let string = value[key]?.string, !string.isEmpty else { throw Self.invalid("\(key) is required and must be a string.") }
        return string
    }

    func optionalString(_ key: String) throws -> String? {
        guard let field = value[key], field != .null else { return nil }
        guard let string = field.string else { throw Self.invalid("\(key) must be a string.") }
        return string
    }

    func url(_ key: String) throws -> URL {
        let string = try string(key)
        guard let url = URL(string: string) else { throw Self.invalid("\(key) is not a valid URL: \(string)") }
        return url
    }

    /// `timeoutMs`, at most a minute.
    func timeout(default milliseconds: Int) throws -> Duration {
        guard let field = value["timeoutMs"], field != .null else { return .milliseconds(milliseconds) }
        let number: Int? = switch field {
        case .int(let value): value
        case .double(let value): Int(exactly: value.rounded())
        default: nil
        }
        guard let number, (1...60_000).contains(number) else { throw Self.invalid("timeoutMs must be a number from 1 to 60000.") }
        return .milliseconds(number)
    }

    func wait(default fallback: LoadWait) throws -> LoadWait {
        guard let name = try optionalString("wait") else { return fallback }
        if name == "networkidle" {
            throw AgentToolError(code: "unsupported", message: "wait: networkidle needs the network log, which this version of Lithium doesn't have yet. Use load.")
        }
        guard let wait = LoadWait(rawValue: name) else { throw Self.invalid("wait must be none, commit, domcontentloaded or load.") }
        return wait
    }

    static func invalid(_ message: String) -> AgentToolError {
        AgentToolError(code: "invalid_params", message: message)
    }
}

extension AgentHub {
    static let tabTools: [AgentTool] = [tabsList, tabOpen, tabClose, tabSelect, navigate, goBack, goForward, reload, stopTool, waitFor]

    private static let tabParam: JSONValue = ["type": "string", "description": "A tab id from tabs_list, such as t3."]
    private static let waitParam: JSONValue = [
        "type": "string", "enum": ["none", "commit", "domcontentloaded", "load"],
        "description": "How far the page must get before the call returns.",
    ]
    private static let timeoutParam: JSONValue = ["type": "integer", "minimum": 1, "maximum": 60000, "description": "Milliseconds, 15000 by default."]

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }), "additionalProperties": false]
    }

    // MARK: Listing

    static let tabsList = AgentTool(
        name: "tabs_list",
        description: "Lists Lithium’s window and every open tab, the user’s own and the agent’s, with the ids other tools take. Titles and addresses come from websites and are untrusted.",
        inputSchema: schema([:])
    ) { _, _, hub in
        guard let browser = hub.browser else { return ["tabs": []] }
        var window: [String: JSONValue] = ["id": "w1"]
        if let frame = (browser.selectedTab?.loadedWebView?.window ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain })?.frame {
            window["width"] = .int(Int(frame.width))
            window["height"] = .int(Int(frame.height))
        }
        let open = Set(browser.tabs.map { ObjectIdentifier($0) })
        let tabs: [JSONValue] = browser.navigationOrder.map { tab in
            var fields: [String: JSONValue] = [
                "tab": .string(hub.id(for: tab)),
                "title": .string(tab.displayTitle),
                "url": .string(tab.url?.absoluteString ?? ""),
                "selected": .bool(tab.id == browser.selectedTabID),
                "favorite": .bool(tab.pinID != nil),
                "asleep": .bool(tab.isAsleep),
                "loading": .bool(tab.isLoading),
                "ephemeral": false,
                "agentTouched": .bool(hub.isTouched(tab)),
                "agentGroup": .bool(tab.openedByAgent != nil),
            ]
            if let opener = tab.opener, open.contains(ObjectIdentifier(opener)) { fields["openedBy"] = .string(hub.id(for: opener)) }
            return .object(fields)
        }
        return ["window": .object(window), "tabs": .array(tabs)]
    }

    // MARK: Opening, closing, selecting

    static let tabOpen = AgentTool(
        name: "tab_open",
        description: "Opens a tab in the background, in the sidebar’s Agent group. The user’s selected tab and focus stay as they are; call tab_select to show it.",
        inputSchema: schema([
            "url": ["type": "string", "description": "An http or https address. Without one the tab opens empty."],
            "ephemeral": ["type": "boolean", "description": "Not supported yet; must be false."],
            "wait": waitParam,
            "timeoutMs": timeoutParam,
        ])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        if arguments.value["ephemeral"] == true {
            throw AgentToolError(code: "unsupported", message: "Ephemeral tabs aren’t available in this version of Lithium.")
        }
        let url = try arguments.optionalString("url").map { _ in try arguments.url("url") }
        if let url { try hub.checkOpenable(url) }
        let wait = try arguments.wait(default: .commit)
        let timeout = try arguments.timeout(default: 15_000)
        let deadline = ContinuousClock.now + timeout
        guard let browser = hub.browser else { throw AgentToolError(code: "unsupported", message: "Lithium has no window to open a tab in.") }
        let tab = browser.newAgentTab(session: session.label)
        let named = NamedTab(tab: tab, id: hub.id(for: tab))
        hub.touch(tab)
        guard let url else { return hub.page(named, reached: .load) }
        return try await hub.exclusive(named, until: deadline, timeout: timeout) {
            try await hub.navigation(in: named, wait: wait, deadline: deadline, timeout: timeout) { tab.go(to: url) }
        }
    }

    static let tabClose = AgentTool(
        name: "tab_close",
        description: "Closes a tab. The user can reopen it with ⇧⌘T, as any closed tab.",
        inputSchema: schema(["tab": tabParam], required: ["tab"])
    ) { arguments, _, hub in
        let named = try hub.tab(named: try Arguments(value: arguments).string("tab"))
        hub.browser?.close(named.tab)
        return ["closed": .string(named.id)]
    }

    static let tabSelect = AgentTool(
        name: "tab_select",
        description: "Shows a tab in Lithium’s window, waking it if it sleeps. Lithium stays where it is among the user’s apps: it is never brought to the front.",
        inputSchema: schema(["tab": tabParam], required: ["tab"])
    ) { arguments, _, hub in
        let named = try hub.tab(named: try Arguments(value: arguments).string("tab"))
        hub.browser?.select(named.tab)
        hub.touch(named.tab)
        return hub.page(named, reached: nil)
    }

    // MARK: Navigation

    static let navigate = AgentTool(
        name: "navigate",
        description: "Opens an address in a tab and waits for it to load as far as wait says. A sleeping tab wakes, with its history.",
        inputSchema: schema(["tab": tabParam, "url": ["type": "string"], "wait": waitParam, "timeoutMs": timeoutParam], required: ["tab", "url"])
    ) { arguments, _, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        let url = try arguments.url("url")
        try hub.checkOpenable(url)
        let wait = try arguments.wait(default: .load)
        let timeout = try arguments.timeout(default: 15_000)
        let deadline = ContinuousClock.now + timeout
        return try await hub.exclusive(named, until: deadline, timeout: timeout) {
            try hub.checkDrivable(named)
            return try await hub.navigation(in: named, wait: wait, deadline: deadline, timeout: timeout) { named.tab.go(to: url) }
        }
    }

    static let goBack = historyTool(name: "go_back", description: "Goes one page back in a tab’s history.", forward: false)
    static let goForward = historyTool(name: "go_forward", description: "Goes one page forward in a tab’s history.", forward: true)

    private static func historyTool(name: String, description: String, forward: Bool) -> AgentTool {
        AgentTool(name: name, description: description, inputSchema: schema(["tab": tabParam, "wait": waitParam, "timeoutMs": timeoutParam], required: ["tab"])) { arguments, _, hub in
            let arguments = Arguments(value: arguments)
            let named = try hub.tab(named: try arguments.string("tab"))
            let wait = try arguments.wait(default: .load)
            let timeout = try arguments.timeout(default: 15_000)
            let deadline = ContinuousClock.now + timeout
            return try await hub.exclusive(named, until: deadline, timeout: timeout) {
                try hub.checkDrivable(named)
                let tab = named.tab
                tab.wake()
                let list = tab.webView.backForwardList
                guard let item = forward ? list.forwardItem : list.backItem else {
                    throw AgentToolError(code: "navigation_failed", message: "\(named.id) has no page to go \(forward ? "forward" : "back") to.")
                }
                if AgentURLs.isBlocked(item.url) {
                    throw AgentToolError(code: "blocked_page", message: "That page is one of Lithium’s own or an extension’s, out of reach for agents.")
                }
                return try await hub.navigation(in: named, wait: wait, deadline: deadline, timeout: timeout) { tab.webView.go(to: item) }
            }
        }
    }

    static let reload = AgentTool(
        name: "reload",
        description: "Reloads a tab’s page. A sleeping tab wakes, which loads it.",
        inputSchema: schema(["tab": tabParam, "wait": waitParam, "timeoutMs": timeoutParam], required: ["tab"])
    ) { arguments, _, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        let wait = try arguments.wait(default: .load)
        let timeout = try arguments.timeout(default: 15_000)
        let deadline = ContinuousClock.now + timeout
        return try await hub.exclusive(named, until: deadline, timeout: timeout) {
            try hub.checkDrivable(named)
            let tab = named.tab
            guard tab.url != nil else { throw AgentToolError(code: "navigation_failed", message: "\(named.id) has no page to reload.") }
            return try await hub.navigation(in: named, wait: wait, deadline: deadline, timeout: timeout) {
                if tab.isAsleep { tab.wake() } else { tab.reload() }
            }
        }
    }

    /// Doesn't wait its turn behind the call it is there to interrupt.
    static let stopTool = AgentTool(
        name: "stop",
        description: "Stops a tab’s page loading at once, and ends the agent call waiting on it (that call answers stopped). It keeps whatever has loaded.",
        inputSchema: schema(["tab": tabParam], required: ["tab"])
    ) { arguments, _, hub in
        let named = try hub.tab(named: try Arguments(value: arguments).string("tab"))
        try hub.checkDrivable(named)
        hub.agentStopped(named.tab)
        if !named.tab.isAsleep { named.tab.stopLoading() }
        hub.touch(named.tab)
        return hub.page(named, reached: nil)
    }

    // MARK: Waiting

    static let waitFor = AgentTool(
        name: "wait_for",
        description: "Waits until a tab’s page has loaded (load: domcontentloaded or load) or its address matches url (a glob such as https://example.com/done* or a /regex/). Give exactly one of load and url.",
        inputSchema: schema([
            "tab": tabParam,
            "load": ["type": "string", "enum": ["domcontentloaded", "load"]],
            "url": ["type": "string", "description": "A glob (* any characters, ? one) matched against the whole address, or /regex/."],
            "timeoutMs": ["type": "integer", "minimum": 1, "maximum": 60000, "description": "Milliseconds, 10000 by default."],
        ], required: ["tab"])
    ) { arguments, _, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        let tab = named.tab
        let timeout = try arguments.timeout(default: 10_000)
        for key in ["ref", "text", "networkIdle"] where arguments.value[key] != nil {
            throw AgentToolError(code: "unsupported", message: "wait_for \(key) isn’t available in this version of Lithium. Wait for load or url.")
        }
        let load = try arguments.optionalString("load")
        let pattern = try arguments.optionalString("url")
        guard (load == nil) != (pattern == nil) else { throw Arguments.invalid("Give exactly one condition: load or url.") }
        let started = ContinuousClock.now
        let deadline = started + timeout
        return try await hub.exclusive(named, until: deadline, timeout: timeout) {
            try hub.checkDrivable(named)
            if let pattern {
                let matches: (String) -> Bool
                do { matches = try AgentURLs.matcher(for: pattern) } catch { throw Arguments.invalid("url is not a valid pattern: \(error.localizedDescription)") }
                let met = try await hub.watch(named, until: deadline) { matches(tab.url?.absoluteString ?? "") ? true : nil }
                guard met != nil else {
                    throw hub.timedOut(named, after: timeout, "its address \(tab.url?.absoluteString ?? "none") doesn’t match \(pattern)")
                }
            } else {
                guard let state = load.flatMap(LoadWait.init(rawValue:)), state >= .domcontentloaded else {
                    throw Arguments.invalid("load must be domcontentloaded or load.")
                }
                try await hub.waitForLoad(of: named, state, deadline: deadline, timeout: timeout)
            }
            var result = hub.page(named, reached: nil).object ?? [:]
            result["met"] = true
            result["elapsedMs"] = .int(Int((ContinuousClock.now - started) / .milliseconds(1)))
            return .object(result)
        }
    }

    // MARK: Helpers

    /// `tab_open` and `navigate` only open the web; `file:` waits for confirmations.
    private func checkOpenable(_ url: URL) throws {
        switch AgentURLs.verdict(for: url) {
        case .allowed: return
        case .needsConfirmation:
            // TODO(PR 4): ask the user (Allow or Deny) through AgentConfirmations instead of refusing.
            throw AgentToolError(code: "unsupported", message: "file: addresses need the user’s Allow, which this version of Lithium can’t ask for yet. Ask the user to open the file.")
        case .blocked(let reason):
            throw AgentToolError(code: "blocked_page", message: reason)
        }
    }

    /// A tab showing Lithium's or an extension's page can be listed, selected and closed, nothing more.
    private func checkDrivable(_ named: NamedTab) throws {
        guard AgentURLs.isBlocked(named.tab.url) else { return }
        throw AgentToolError(code: "blocked_page", message: "\(named.id) shows one of Lithium’s own or an extension’s pages, out of reach for agents.")
    }

    /// What every navigation tool returns: where the tab is now and how far its page got.
    private func page(_ named: NamedTab, reached: LoadWait?) -> JSONValue {
        let tab = named.tab
        var fields: [String: JSONValue] = [
            "tab": .string(named.id),
            "url": .string(tab.url?.absoluteString ?? ""),
            "title": .string(tab.displayTitle),
            "loading": .bool(tab.isLoading),
        ]
        if let reached, reached != .none { fields["state"] = .string(reached.rawValue) }
        if let status = tab.httpStatus { fields["status"] = .int(status) }
        return .object(fields)
    }

    /// Re-checks `check` as the tab changes, inside `exclusive`. The tab closing, the user
    /// navigating it, or an agent's `stop`, ends the wait with the error the agent reads.
    private func watch<Value>(_ named: NamedTab, until deadline: ContinuousClock.Instant, _ check: @escaping @MainActor () throws -> Value?) async throws -> Value? {
        try await AgentWait.until(deadline) {
            try self.checkStillWaitable(named)
            return try check()
        }
    }

    private func checkStillWaitable(_ named: NamedTab) throws {
        guard isOpen(named.tab) else { throw named.closedError }
        // `exclusive` clears it when the call ends, so any interruption is this call's.
        switch interruptions[named.tab.id] {
        case nil: return
        case .user: throw AgentToolError(code: "user_interrupted", message: "The user navigated \(named.id) while the agent waited on it.")
        case .agentStop: throw AgentToolError(code: "stopped", message: "A stop call stopped \(named.id) while this call waited on it.")
        }
    }

    /// Starts a navigation, then waits until the page it leads to (the next document the tab
    /// commits, never the one before) gets as far as `wait`.
    private func navigation(in named: NamedTab, wait: LoadWait, deadline: ContinuousClock.Instant, timeout: Duration, _ start: () -> Void) async throws -> JSONValue {
        let tab = named.tab
        let before = tab.commits
        start()
        touch(tab)
        guard wait > .none else { return page(named, reached: nil) }
        let committed = try await watch(named, until: deadline) { tab.commits > before ? true : nil }
        guard committed != nil else { throw timedOut(named, after: timeout, "no page had started to show") }
        if wait > .commit { try await waitForLoad(of: named, wait, deadline: deadline, timeout: timeout) }
        return page(named, reached: wait)
    }

    /// The tab's current document reaching `state`. Lithium's error page standing in for the
    /// page is `navigation_failed`.
    private func waitForLoad(of named: NamedTab, _ state: LoadWait, deadline: ContinuousClock.Instant, timeout: Duration) async throws {
        let tab = named.tab
        let failed: @MainActor () throws -> Void = {
            if tab.isAsleep { throw AgentToolError(code: "navigation_failed", message: "\(named.id)’s page stopped working and the tab went to sleep.") }
            if let error = tab.loadError, !tab.isLoading { throw AgentToolError(code: "navigation_failed", message: error.localizedDescription) }
        }
        if state == .domcontentloaded {
            // No delegate call marks DOMContentLoaded: the page is asked, in short rounds so Stop and the deadline still apply.
            while ContinuousClock.now < deadline {
                try checkStillWaitable(named)
                try failed()
                if !tab.isLoading { return }
                if await documentIsReady(tab, within: min(.milliseconds(250), deadline - .now)) {
                    // What happened while the page was asked counts first.
                    try checkStillWaitable(named)
                    return
                }
                // A page between documents answers at once, with an error.
                try await Task.sleep(for: .milliseconds(20))
            }
            throw timedOut(named, after: timeout, "the page was still loading")
        }
        let loaded = try await watch(named, until: deadline) { () -> Bool? in
            try failed()
            return tab.isLoading ? nil : true
        }
        guard loaded != nil else { throw timedOut(named, after: timeout, "the page was still loading") }
    }

    /// Asked in a content world of Lithium's own, which the page can't see or touch.
    private func documentIsReady(_ tab: Tab, within limit: Duration) async -> Bool {
        let milliseconds = max(1, Int(limit / .milliseconds(1)))
        let script = """
            if (document.readyState === 'loading') {
              await new Promise((resolve) => { document.addEventListener('DOMContentLoaded', resolve, { once: true }); setTimeout(resolve, \(milliseconds)); });
            }
            return document.readyState !== 'loading';
            """
        let ready = try? await tab.webView.callAsyncJavaScript(script, contentWorld: Self.agentWorld) as? Bool
        return ready == true
    }

    static let agentWorld = WKContentWorld.world(name: "lithium-agent")

    private func timedOut(_ named: NamedTab, after timeout: Duration, _ state: String) -> AgentToolError {
        AgentToolError(code: "timeout", message: "\(named.id) after \(Int(timeout / .milliseconds(1))) ms: \(state).")
    }
}
