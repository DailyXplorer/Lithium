import AppKit
import Observation
import WebKit

/// Agents' short names for tabs: `t1`, `t2`, … in the order agents first see them, never reused
/// during a run. Keyed by `Tab.id`, which a tab keeps while it sleeps.
struct AgentTabIDs {
    private var next = 1
    private var ids: [Tab.ID: String] = [:]
    private var tabs: [String: Tab.ID] = [:]
    private(set) var closed: [String: Date] = [:]
    /// Kept once they close: the log never says where they went.
    private var ephemeral: Set<String> = []

    mutating func id(for tab: Tab.ID, isEphemeral: Bool = false) -> String {
        if let id = ids[tab] { return id }
        let id = "t\(next)"
        next += 1
        ids[tab] = id
        tabs[id] = tab
        if isEphemeral { ephemeral.insert(id) }
        return id
    }

    func isEphemeral(_ id: String) -> Bool {
        ephemeral.contains(id)
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

/// A tab with the id the agent named it by, kept for the whole call, since a closed tab's id is retired.
@MainActor
struct NamedTab {
    let tab: Tab
    let id: String

    var closedError: AgentToolError {
        AgentToolError(code: "tab_closed", message: "\(id) was closed while the agent waited on it.")
    }
}

enum AgentInterruption {
    /// The user navigated the tab (address bar, Back, Forward, Reload, Stop).
    case user
    case agentStop
    /// The user clicked, typed or scrolled in the tab during an agent action.
    case userInput
}

enum LoadWait: String, Comparable, CaseIterable {
    /// `networkidle`: loaded, then no request of the page in flight for 500 ms.
    case none, commit, domcontentloaded, load, networkidle

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// A wrong or missing argument is `invalid_params`.
struct Arguments {
    let value: JSONValue

    func bool(_ key: String, default fallback: Bool) throws -> Bool {
        guard let field = value[key], field != .null else { return fallback }
        guard case .bool(let flag) = field else { throw Self.invalid("\(key) must be true or false.") }
        return flag
    }

    func int(_ key: String, default fallback: Int, in range: ClosedRange<Int>) throws -> Int {
        guard let field = value[key], field != .null else { return fallback }
        let number: Int? = switch field {
        case .int(let value): value
        case .double(let value): Int(exactly: value.rounded())
        default: nil
        }
        guard let number, range.contains(number) else { throw Self.invalid("\(key) must be a number from \(range.lowerBound) to \(range.upperBound).") }
        return number
    }

    func choice(_ key: String, _ choices: [String], default fallback: String) throws -> String {
        guard let choice = try optionalString(key) else { return fallback }
        guard choices.contains(choice) else { throw Self.invalid("\(key) must be one of \(choices.joined(separator: ", ")).") }
        return choice
    }

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
        guard let wait = LoadWait(rawValue: name) else { throw Self.invalid("wait must be none, commit, domcontentloaded, load or networkidle.") }
        return wait
    }

    static func invalid(_ message: String) -> AgentToolError {
        AgentToolError(code: "invalid_params", message: message)
    }
}

/// Kept terse: `tools/list` goes to the model every turn (its budget is tested); the rules behind
/// these parameters are in `AgentHub.instructions`.
enum AgentParam {
    static let tab: JSONValue = ["type": "string"]
    static let ref: JSONValue = ["type": "string"]
    static let wait: JSONValue = ["type": "string", "enum": .array(LoadWait.allCases.map { .string($0.rawValue) })]
    static let integer: JSONValue = ["type": "integer"]
    static let timeout = integer
    static let flag: JSONValue = ["type": "boolean"]
    static let text: JSONValue = ["type": "string"]
    static let number: JSONValue = ["type": "number"]
    static let strings: JSONValue = ["type": "array", "items": ["type": "string"]]
}

extension AgentHub {
    static let tabTools: [AgentTool] = [tabsList, tabOpen, tabClose, tabSelect, navigate, goBack, goForward, reload, stopTool, waitFor]

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }), "additionalProperties": false]
    }

    // MARK: Listing

    static let tabsList = AgentTool(
        name: "tabs_list",
        description: "List the windows and every open tab, the user’s and the agent’s, with their ids.",
        inputSchema: schema([:])
    ) { _, _, hub in
        guard let browser = hub.browser else { return ["tabs": []] }
        // Named w1, w2… in the order opened; the ids hold only until a window closes.
        let windowIDs = Dictionary(browser.windows.enumerated().map { ($1.id, "w\($0 + 1)") }, uniquingKeysWith: { first, _ in first })
        let windows: [JSONValue] = browser.windows.map { window in
            var fields: [String: JSONValue] = ["id": .string(windowIDs[window.id] ?? ""), "key": .bool(window === browser.commandWindow)]
            if let frame = (window.nsWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain })?.frame {
                fields["width"] = .int(Int(frame.width))
                fields["height"] = .int(Int(frame.height))
            }
            return .object(fields)
        }
        let open = Set(browser.tabs.map { ObjectIdentifier($0) })
        let tabs: [JSONValue] = browser.navigationOrder.map { tab in
            var fields: [String: JSONValue] = [
                "tab": .string(hub.id(for: tab)),
                "window": .string(windowIDs[tab.windowID] ?? ""),
                "title": .string(tab.displayTitle),
                "url": .string(tab.url?.absoluteString ?? ""),
                "selected": .bool(tab.id == browser.window(of: tab).selectedTabID),
                "favorite": .bool(tab.pinID != nil),
                "asleep": .bool(tab.isAsleep),
                "loading": .bool(tab.isLoading),
                "ephemeral": .bool(tab.isEphemeral),
                "agentTouched": .bool(hub.isTouched(tab)),
                "agentGroup": .bool(tab.isInAgentGroup),
            ]
            if let dialog = hub.tabs[tab.id]?.dialog { fields["dialog"] = dialog.json }
            if let opener = tab.opener, open.contains(ObjectIdentifier(opener)) { fields["openedBy"] = .string(hub.id(for: opener)) }
            return .object(fields)
        }
        return ["windows": .array(windows), "tabs": .array(tabs)]
    }

    // MARK: Opening, closing, selecting

    static let tabOpen = AgentTool(
        name: "tab_open",
        description: "Open a tab in the background (Agent group) and return its page’s snapshot, or run steps in it as a batch.",
        inputSchema: schema([
            "url": AgentParam.text,
            "ephemeral": ["type": "boolean", "description": "Private tab: own cookies, none of the user’s, nothing saved"],
            "snapshot": ["type": "boolean", "description": "Default true: the page’s snapshot as diff, once its document is ready"],
            "wait": AgentParam.wait,
            "timeoutMs": AgentParam.timeout,
            "steps": ["type": "array", "maxItems": .int(maxBatchSteps), "description": "As batch’s steps, run once the page is ready"],
            "readyTimeoutMs": AgentParam.integer,
        ])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let ephemeral = try arguments.bool("ephemeral", default: false)
        let url = try arguments.optionalString("url").map { _ in try arguments.url("url") }
        if let url { try hub.checkOpenable(url) }
        let snapshot = try arguments.bool("snapshot", default: true)
        let given = arguments.value["steps"]
        let steps = try given == nil || given == .null ? nil : hub.batchSteps(given, tab: nil)
        var wait = try arguments.wait(default: .commit)
        // Steps act on the page's document, which a commit alone doesn't have yet.
        if steps != nil { wait = max(wait, .domcontentloaded) }
        let timeout = try arguments.timeout(default: steps == nil ? 15_000 : 60_000)
        let ready = try arguments.readyTimeout()
        let deadline = ContinuousClock.now + timeout
        let named = try hub.openAgentTab(ephemeral: ephemeral, session: session)
        var page = hub.page(named, reached: .load)
        if let url { page = try await hub.load(url, in: named, wait: wait, snapshot: snapshot && steps == nil, session: session, deadline: deadline, timeout: timeout) }
        guard let steps else { return page }
        var opened = page.object ?? [:]
        if url != nil {
            let prepared = try await hub.readyForSteps(named, within: ready, session: session, deadline: deadline)
            if prepared["note"] == nil, wait < .load { opened["state"] = .string(LoadWait.load.rawValue) }
            opened.merge(prepared) { $1 }
        }
        let batch = try await hub.runBatch(steps, in: named, stopOnError: true, diff: snapshot, ready: ready, deadline: deadline, timeout: timeout, session: session)
        // The batch reads the page the steps left; the first load's status may not be its.
        opened["status"] = nil
        return .object(opened.merging(batch) { $1 })
    }

    func openAgentTab(ephemeral: Bool, session: MCPSession) throws -> NamedTab {
        guard let browser else { throw AgentToolError(code: "unsupported", message: "Lithium has no window to open a tab in.") }
        let tab = browser.newAgentTab(session: session.label, privateStore: ephemeral ? .nonPersistent() : nil)
        let named = NamedTab(tab: tab, id: id(for: tab))
        touch(tab)
        return named
    }

    func load(_ url: URL, in named: NamedTab, wait: LoadWait, snapshot: Bool, session: MCPSession, deadline: ContinuousClock.Instant, timeout: Duration) async throws -> JSONValue {
        try await exclusive(named, until: deadline, timeout: timeout) {
            var page = try await navigation(in: named, wait: wait, deadline: deadline, timeout: timeout, landedWithinPage: nil) { named.tab.go(to: url) }
            guard snapshot, wait > .none, page["download"] == nil else { return page }
            // A page slower than the call answers without a snapshot rather than failing, so the
            // agent doesn't open the tab again.
            if wait < .domcontentloaded {
                do {
                    try await waitForLoad(of: named, .domcontentloaded, deadline: deadline, timeout: timeout)
                    page = self.page(named, reached: .domcontentloaded)
                } catch let error as AgentToolError where error.code == "timeout" {
                    guard var fields = page.object else { return page }
                    fields["diff"] = .null
                    fields["diffNote"] = .string("No diff: the page was still loading. Call snapshot.")
                    return .object(fields)
                }
            }
            return try await addingDiff(to: page, of: named, for: session, if: true, until: deadline)
        }
    }

    static let tabClose = AgentTool(
        name: "tab_close",
        description: "Close a tab (the user can reopen it).",
        inputSchema: schema(["tab": AgentParam.tab], required: ["tab"])
    ) { arguments, _, hub in
        let named = try hub.tab(named: try Arguments(value: arguments).string("tab"))
        hub.browser?.close(named.tab)
        return ["closed": .string(named.id)]
    }

    static let tabSelect = AgentTool(
        name: "tab_select",
        description: "Show a tab to the user in Lithium’s window; Lithium is never brought to the front.",
        inputSchema: schema(["tab": AgentParam.tab], required: ["tab"])
    ) { arguments, _, hub in
        let named = try hub.tab(named: try Arguments(value: arguments).string("tab"))
        // Lithium's own pages are shown to the user, never to the agent: those can wake.
        if !AgentURLs.isBlocked(named.tab.url) { try hub.checkWakeable(named) }
        // Not the user's pick, so their typing in the address bar goes on.
        hub.browser?.select(named.tab, picked: false)
        hub.touch(named.tab)
        return hub.page(named, reached: nil)
    }

    // MARK: Navigation

    static let navigate = AgentTool(
        name: "navigate",
        description: "Go to a URL in a tab.",
        inputSchema: schema(["tab": AgentParam.tab, "url": AgentParam.text, "wait": AgentParam.wait, "timeoutMs": AgentParam.timeout, "diff": AgentParam.flag], required: ["tab", "url"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        let url = try arguments.url("url")
        try hub.checkOpenable(url)
        let wait = try arguments.wait(default: .load)
        let timeout = try arguments.timeout(default: 15_000)
        let diff = try arguments.bool("diff", default: true)
        let deadline = ContinuousClock.now + timeout
        return try await hub.exclusive(named, until: deadline, timeout: timeout) {
            try hub.checkDrivable(named)
            let tab = named.tab
            var landedWithinPage: (@MainActor () -> Bool)?
            if !tab.isAsleep, AgentURLs.isMoveWithinPage(from: tab.url, to: url) {
                landedWithinPage = { tab.url?.fragment == url.fragment }
            }
            let page = try await hub.navigation(in: named, wait: wait, deadline: deadline, timeout: timeout, landedWithinPage: landedWithinPage) {
                // Waking with its history would show the page it slept on first, which an agent may not open.
                if tab.isAsleep, let old = tab.url, AgentURLs.verdict(for: old) != .allowed { tab.load(url) } else { tab.go(to: url) }
            }
            return try await hub.addingDiff(to: page, of: named, for: session, if: diff && wait > .commit, until: deadline)
        }
    }

    static let goBack = historyTool(name: "go_back", description: "Go back in a tab’s history.", forward: false)
    static let goForward = historyTool(name: "go_forward", description: "Go forward in a tab’s history.", forward: true)

    private static func historyTool(name: String, description: String, forward: Bool) -> AgentTool {
        AgentTool(name: name, description: description, inputSchema: schema(["tab": AgentParam.tab, "wait": AgentParam.wait, "timeoutMs": AgentParam.timeout, "diff": AgentParam.flag], required: ["tab"])) { arguments, session, hub in
            let arguments = Arguments(value: arguments)
            let named = try hub.tab(named: try arguments.string("tab"))
            let wait = try arguments.wait(default: .load)
            let timeout = try arguments.timeout(default: 15_000)
            let diff = try arguments.bool("diff", default: true)
            let deadline = ContinuousClock.now + timeout
            return try await hub.exclusive(named, until: deadline, timeout: timeout) {
                try hub.checkDrivable(named)
                try hub.checkWakeable(named)
                let tab = named.tab
                tab.wake()
                let list = tab.webView.backForwardList
                guard let item = forward ? list.forwardItem : list.backItem else {
                    throw AgentToolError(code: "navigation_failed", message: "\(named.id) has no page to go \(forward ? "forward" : "back") to.")
                }
                try hub.checkOpenable(item.url)
                // Only a same-origin entry can be in the document shown (an anchor, a `pushState`).
                var landedWithinPage: (@MainActor () -> Bool)?
                if let current = tab.url, AgentURLs.sameOrigin(current, item.url) {
                    landedWithinPage = { tab.url == item.url }
                }
                let page = try await hub.navigation(in: named, wait: wait, deadline: deadline, timeout: timeout, landedWithinPage: landedWithinPage) {
                    tab.webView.go(to: item)
                }
                return try await hub.addingDiff(to: page, of: named, for: session, if: diff && wait > .commit, until: deadline)
            }
        }
    }

    static let reload = AgentTool(
        name: "reload",
        description: "Reload a tab’s page.",
        inputSchema: schema(["tab": AgentParam.tab, "wait": AgentParam.wait, "timeoutMs": AgentParam.timeout, "diff": AgentParam.flag], required: ["tab"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        let wait = try arguments.wait(default: .load)
        let timeout = try arguments.timeout(default: 15_000)
        let diff = try arguments.bool("diff", default: true)
        let deadline = ContinuousClock.now + timeout
        return try await hub.exclusive(named, until: deadline, timeout: timeout) {
            try hub.checkDrivable(named)
            let tab = named.tab
            guard let url = tab.url else { throw AgentToolError(code: "navigation_failed", message: "\(named.id) has no page to reload.") }
            try hub.checkOpenable(url)
            let page = try await hub.navigation(in: named, wait: wait, deadline: deadline, timeout: timeout, landedWithinPage: nil) {
                if tab.isAsleep { tab.wake() } else { tab.reload() }
            }
            return try await hub.addingDiff(to: page, of: named, for: session, if: diff && wait > .commit, until: deadline)
        }
    }

    /// Doesn't wait its turn behind the call it is there to interrupt.
    static let stopTool = AgentTool(
        name: "stop",
        description: "Stop a tab loading and end the agent call waiting on it.",
        inputSchema: schema(["tab": AgentParam.tab], required: ["tab"])
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
        description: "Wait for load, url, ref in a state, text or textGone (same-origin frames too), networkIdle or time.",
        inputSchema: schema([
            "tab": AgentParam.tab,
            "load": ["type": "string", "enum": ["domcontentloaded", "load"]],
            "url": ["type": "string", "description": "Glob on the whole URL (* and ?)"],
            "ref": AgentParam.ref,
            "state": ["type": "string", "enum": ["visible", "hidden", "enabled", "attached", "detached"]],
            "text": AgentParam.text,
            "present": ["type": "boolean", "description": "With text: false waits for it to go"],
            "textGone": AgentParam.text,
            "networkIdle": ["type": "integer", "description": "ms with no request in flight"],
            "time": ["type": "integer", "description": "ms to wait"],
            "timeoutMs": ["type": "integer", "description": "Default 10000"],
            "diff": AgentParam.flag,
        ], required: ["tab"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        let tab = named.tab
        let time = arguments.value["time"] == nil ? nil : try arguments.int("time", default: 0, in: 1...59_000)
        let timeout = try arguments.timeout(default: time.map { min(60_000, $0 + 10_000) } ?? 10_000)
        if let time, .milliseconds(time) >= timeout { throw Arguments.invalid("time must be shorter than timeoutMs.") }
        let diff = try arguments.bool("diff", default: true)
        let load = try arguments.optionalString("load")
        let pattern = try arguments.optionalString("url")
        let element = try arguments.optionalString("ref")
        let text = try arguments.optionalString("text")
        let textGone = try arguments.optionalString("textGone")
        // `true` is the quiet half second `wait: networkidle` means.
        let idle = try arguments.value["networkIdle"].flatMap { $0 == .null || $0 == .bool(false) ? nil : $0 == .bool(true) ? 500 : try arguments.int("networkIdle", default: 500, in: 0...30_000) }
        guard [load, pattern, element, text, textGone, idle.map(String.init), time.map(String.init)].compactMap({ $0 }).count == 1 else {
            throw Arguments.invalid("Give exactly one condition: load, url, ref, text, textGone, networkIdle or time.")
        }
        if idle != nil { try hub.checkNetworkIdle(.networkidle) }
        let condition = try DOMCondition(ref: element, text: text ?? textGone, gone: textGone != nil, arguments: arguments)
        let state = try load.map { load in
            guard let state = LoadWait(rawValue: load), state >= .domcontentloaded else { throw Arguments.invalid("load must be domcontentloaded or load.") }
            return state
        }
        let matches = try pattern.map { pattern in
            guard let matches = AgentURLs.matcher(for: pattern) else {
                throw Arguments.invalid("url is a glob (* any characters, ? one character); /regex/ patterns aren’t supported.")
            }
            return matches
        }
        let started = ContinuousClock.now
        let deadline = started + timeout
        return try await hub.exclusive(named, until: deadline, timeout: timeout) {
            var note: String?
            try hub.checkDrivable(named)
            try hub.checkWakeable(named)
            if let pattern, let matches {
                tab.wake()
                let met = try await hub.watch(named, until: deadline) { matches(tab.url?.absoluteString ?? "") ? true : nil }
                guard met != nil else {
                    throw hub.timedOut(named, after: timeout, "its address \(tab.url?.absoluteString ?? "none") doesn’t match \(pattern)")
                }
            } else if let state {
                if tab.isAsleep {
                    _ = try await hub.navigation(in: named, wait: state, deadline: deadline, timeout: timeout, landedWithinPage: nil) { tab.wake() }
                } else {
                    try await hub.waitForLoad(of: named, state, deadline: deadline, timeout: timeout)
                }
            } else if let condition {
                note = try await hub.wait(for: condition, in: named, deadline: deadline, timeout: timeout)
            } else if let idle {
                // A sleeping tab has sent nothing yet: the quiet counts from its page's load.
                var loaded: ContinuousClock.Instant?
                if tab.isAsleep {
                    _ = try await hub.navigation(in: named, wait: .load, deadline: deadline, timeout: timeout, landedWithinPage: nil) { tab.wake() }
                    loaded = .now
                }
                try await hub.waitForNetworkIdle(named, quiet: .milliseconds(idle), after: loaded, deadline: deadline, timeout: timeout)
            } else if let time {
                // Counted from the call's turn in the tab; the wait in line may have used the margin.
                let end = ContinuousClock.now + .milliseconds(time)
                guard end < deadline else { throw hub.timedOut(named, after: timeout, "its turn came too late to wait \(time) ms") }
                _ = try await hub.watch(named, until: end) { nil as Bool? }
            }
            var result = hub.page(named, reached: nil).object ?? [:]
            result["met"] = true
            if let note { result["note"] = .string(note) }
            result["elapsedMs"] = .int(Int((ContinuousClock.now - started) / .milliseconds(1)))
            return try await hub.addingDiff(to: .object(result), of: named, for: session, if: diff, until: deadline)
        }
    }

    // MARK: Helpers

    /// Lithium's or an extension's page can be listed, selected and closed, nothing more.
    func checkDrivable(_ named: NamedTab) throws {
        guard AgentURLs.isBlocked(named.tab.url) else { return }
        throw AgentToolError(code: "blocked_page", message: "\(named.id) shows one of Lithium’s own or an extension’s pages, out of reach for agents.")
    }

    /// Waking loads the page the tab slept on, which must pass `checkOpenable` like any other.
    func checkWakeable(_ named: NamedTab) throws {
        guard named.tab.isAsleep, let url = named.tab.url else { return }
        try checkOpenable(url)
    }

    func page(_ named: NamedTab, reached: LoadWait?) -> JSONValue {
        let tab = named.tab
        var fields: [String: JSONValue] = [
            "tab": .string(named.id),
            "url": .string(tab.url?.absoluteString ?? ""),
            "title": .string(tab.displayTitle),
            "loading": .bool(tab.isLoading),
        ]
        if let reached { fields["state"] = .string(reached == LoadWait.none ? "started" : reached.rawValue) }
        if let status = tab.httpStatus { fields["status"] = .int(status) }
        // Before the commit, the failures known are the page before's.
        if !tab.isAwaitingCommit, let failed = failedScripts(in: tab) { fields["failedScripts"] = failed }
        return .object(fields)
    }

    /// So an agent knows why a button may be dead.
    func failedScripts(in tab: Tab) -> JSONValue? {
        let failed = tabs[tab.id]?.capture?.failedScripts ?? []
        guard !failed.isEmpty else { return nil }
        return .array(failed.prefix(5).map { entry in
            var fields: [String: JSONValue] = ["url": .string(entry.url)]
            if let status = entry.status { fields["status"] = .int(status) } else { fields["error"] = .string(entry.error ?? "failed") }
            return .object(fields)
        })
    }

    /// Re-checks `check` as the tab changes, inside `exclusive`.
    func watch<Value>(_ named: NamedTab, until deadline: ContinuousClock.Instant, _ check: @escaping @MainActor () throws -> Value?) async throws -> Value? {
        try await AgentWait.until(deadline) {
            try self.checkStillWaitable(named)
            return try check()
        }
    }

    /// `ignoringDialog`: an action's events go on under a dialog; the page handles them once it is answered.
    func checkStillWaitable(_ named: NamedTab, ignoringDialog: Bool = false) throws {
        guard isOpen(named.tab) else { throw named.closedError }
        // The page is paused until its dialog is answered: nothing it does can end a wait.
        if !ignoringDialog, let dialog = tabs[named.tab.id]?.dialog { throw dialogOpen(named, dialog) }
        // `exclusive` clears it when the call ends, so any interruption is this call's.
        switch tabs[named.tab.id]?.interruption {
        case nil: return
        case .user: throw AgentToolError(code: "user_interrupted", message: "The user navigated \(named.id) while the agent waited on it.")
        case .agentStop: throw AgentToolError(code: "stopped", message: "A stop call stopped \(named.id) while this call waited on it.")
        case .userInput: throw AgentToolError(code: "user_interrupted", message: "The user clicked, typed or scrolled in \(named.id) while the agent acted in it. Check the page before trying again.")
        }
    }

    /// Starts a navigation, then waits until the next document the tab commits gets as far as
    /// `wait`. A move within the document shown commits nothing: `landedWithinPage` tells it
    /// from a move the page's own script made meanwhile. A load that becomes a download answers with its file.
    func navigation(in named: NamedTab, wait: LoadWait, deadline: ContinuousClock.Instant, timeout: Duration, landedWithinPage: (@MainActor () -> Bool)?, _ start: () -> Void) async throws -> JSONValue {
        try checkNetworkIdle(wait)
        let tab = named.tab
        let since = LoadProgress(of: tab, agentTab(for: tab))
        let state = agentTab(for: tab)
        if Self.callSession != nil { state?.drive = AgentDrive(marks: tab.loadMarks, deadline: deadline) }
        defer { if wait > .none, !tab.isLoading { state?.drive = nil } }
        start()
        // Laid out at the size the user would see it, not in an empty viewport.
        if !tab.isAsleep, tab.loadedWebView != nil { _ = sizedWebView(of: tab) }
        touch(tab)
        guard wait > .none else { return page(named, reached: LoadWait.none) }
        return try await follow(since, in: named, wait: wait, deadline: deadline, timeout: timeout, landedWithinPage: landedWithinPage)
    }

    /// How far a tab's loads had got when an agent's input began, to tell its load from earlier ones.
    struct LoadProgress {
        var commits: Int
        let starts: Int
        let moves: Int
        let unshown: Int
        /// The load before may have failed with its error page still on its way: that page
        /// committing is not this call's answer.
        let earlierError: NSError?

        @MainActor
        init(of tab: Tab, _ state: AgentTab?) {
            (commits, starts, moves, unshown) = (tab.commits, tab.loadStarts, tab.sameDocumentNavigations, tab.unshownLoads)
            earlierError = tab.loadError
        }

        /// A load already under way doesn't count.
        @MainActor
        func hasMoved(_ tab: Tab, _ state: AgentTab?) -> Bool {
            tab.loadStarts > starts || tab.unshownLoads > unshown
        }
    }

    func follow(_ since: LoadProgress, in named: NamedTab, wait: LoadWait, deadline: ContinuousClock.Instant, timeout: Duration, landedWithinPage: (@MainActor () -> Bool)?) async throws -> JSONValue {
        enum Outcome { case document, withinPage, download(String?) }
        let tab = named.tab
        var commits = since.commits
        let (moves, unshown, earlierError) = (since.moves, since.unshown, since.earlierError)
        let state = agentTab(for: tab)
        let outcome = try await AgentWait.until(deadline) { () -> Outcome? in
            // Before the tab closing: a tab opened just for a file closes once its download starts.
            if tab.unshownLoads > unshown, let load = tab.lastUnshownLoad {
                switch load {
                case .download(let fileName): return .download(fileName)
                case .refused(let scheme):
                    throw AgentToolError(code: "navigation_cancelled", message: "\(named.id)’s page led to a \(scheme): address, which Lithium doesn’t open in a tab.")
                case .dropped:
                    throw AgentToolError(code: "navigation_cancelled", message: "\(named.id)’s load stopped before it showed a page: the server answered with no content (204), or the load was stopped.")
                }
            }
            try self.checkStillWaitable(named)
            if tab.commits > commits {
                guard let error = tab.loadError else { return .document }
                if error === earlierError {
                    commits = tab.commits
                    state?.drive?.marks = tab.loadMarks
                    return nil
                }
                throw AgentToolError(code: "navigation_failed", message: "\(named.id) couldn’t open its page: \(error.localizedDescription)")
            }
            guard let landedWithinPage, tab.sameDocumentNavigations > moves else { return nil }
            return landedWithinPage() ? .withinPage : nil
        }
        switch outcome {
        case nil:
            throw timedOut(named, after: timeout, "no page had started to show")
        case .download(let fileName):
            var fields = page(named, reached: nil).object ?? [:]
            fields["download"] = .object(try await downloaded(fileName, in: tab, until: deadline))
            fields["loading"] = false
            return .object(fields)
        case .document:
            if wait > .commit { try await waitForLoad(of: named, min(wait, .load), deadline: deadline, timeout: timeout) }
        case .withinPage:
            break
        }
        if wait == .networkidle { try await waitForNetworkIdle(named, deadline: deadline, timeout: timeout) }
        return page(named, reached: wait)
    }

    /// What a download the agent started tells it: where the file went, and whether it is all
    /// there. Waits for the file within the call's own time, since a file half written is no use;
    /// one still coming then is `done: false`.
    private func downloaded(_ fileName: String?, in tab: Tab, until deadline: ContinuousClock.Instant) async throws -> [String: JSONValue] {
        var download: [String: JSONValue] = ["file": fileName.map(JSONValue.string) ?? .null]
        guard let item = tab.lastDownload else { return download }
        _ = try await AgentWait.until(deadline) { item.state == .downloading ? nil : true }
        if let path = item.destination?.path(percentEncoded: false) { download["path"] = .string(path) }
        switch item.state {
        case .downloading: download["done"] = false
        case .finished: download["done"] = true
        case .failed(let reason): download["error"] = .string(reason)
        case .cancelled: download["error"] = "cancelled"
        }
        return download
    }

    func waitForLoad(of named: NamedTab, _ state: LoadWait, deadline: ContinuousClock.Instant, timeout: Duration) async throws {
        let tab = named.tab
        let failed: @MainActor () throws -> Void = { try self.checkPageShown(named, before: "its page loaded") }
        if state == .domcontentloaded {
            // No delegate call marks DOMContentLoaded, so the page is asked. A busy script can
            // hold the answer, so it races the deadline, Stop, the user and the load ending.
            while ContinuousClock.now < deadline {
                if tab.isAwaitingCommit {
                    // The document shown is on its way out, and long since ready.
                    guard try await watch(named, until: deadline, { try failed(); return tab.isAwaitingCommit ? nil : true }) != nil else { break }
                    continue
                }
                try failed()
                let answer = PageAnswer<Bool>()
                Task { answer.result = .success(await documentIsReady(tab, within: deadline - .now)) }
                let ready = try await watch(named, until: deadline) { () -> Bool? in
                    try failed()
                    return tab.isLoading ? try answer.result?.get() : true
                }
                guard let ready else { break }
                if ready { return try await waitForTitle(of: named, until: deadline) }
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
        try await waitForTitle(of: named, until: deadline)
    }

    /// WebKit can report a load finished before its title, so a document with a title waits up
    /// to a second for WebKit to report it.
    private func waitForTitle(of named: NamedTab, until deadline: ContinuousClock.Instant) async throws {
        let tab = named.tab
        guard tab.title.isEmpty, !tab.isAsleep, let webView = tab.loadedWebView else { return }
        let answer = PageAnswer<Bool>()
        Task { answer.result = .success(((try? await webView.callAsyncJavaScript("return document.title", contentWorld: PageProbe.world)) as? String ?? "").isEmpty) }
        _ = try await watch(named, until: min(deadline, .now + .seconds(1))) { () -> Bool? in
            guard tab.title.isEmpty else { return true }
            return try answer.result?.get() == true ? true : nil
        }
    }

    func checkPageShown(_ named: NamedTab, before event: String) throws {
        let tab = named.tab
        if tab.isAsleep { throw AgentToolError(code: "navigation_failed", message: "\(named.id) went to sleep before \(event). Call navigate or reload to load it again.") }
        if let error = tab.loadError, !tab.isLoading { throw AgentToolError(code: "navigation_failed", message: "\(named.id) couldn’t open its page: \(error.localizedDescription)") }
    }

    /// Asked in Lithium's own content world, which the page can't see or touch.
    private func documentIsReady(_ tab: Tab, within limit: Duration) async -> Bool {
        guard !tab.isAsleep, let webView = tab.loadedWebView else { return false }
        let milliseconds = max(1, Int(limit / .milliseconds(1)))
        let script = """
            if (document.readyState === 'loading') {
              await new Promise((resolve) => { document.addEventListener('DOMContentLoaded', resolve, { once: true }); setTimeout(resolve, \(milliseconds)); });
            }
            return document.readyState !== 'loading';
            """
        let ready = try? await webView.callAsyncJavaScript(script, contentWorld: PageProbe.world) as? Bool
        return ready == true
    }

    func timedOut(_ named: NamedTab, after timeout: Duration, _ state: String) -> AgentToolError {
        AgentToolError(code: "timeout", message: "\(named.id) after \(Int(timeout / .milliseconds(1))) ms: \(state).")
    }
}
