import AppKit
import Observation
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
    /// The user clicked, typed or scrolled in the tab during an agent action.
    case userInput
}

/// How far a navigation has to get before the tool answers.
enum LoadWait: String, Comparable, CaseIterable {
    /// `networkidle`: loaded, then no request of the page in flight for 500 ms.
    case none, commit, domcontentloaded, load, networkidle

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// A tool's arguments, checked at the boundary: a wrong or missing one is `invalid_params`.
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
        guard let wait = LoadWait(rawValue: name) else { throw Self.invalid("wait must be none, commit, domcontentloaded, load or networkidle.") }
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
        "type": "string", "enum": ["none", "commit", "domcontentloaded", "load", "networkidle"],
        "description": "How far the page must get before the call returns. A page that fails to open is navigation_failed. none returns at once, with state started, before anything is known: call wait_for to learn whether the page opened. networkidle waits for load, then until none of the page’s requests has been in flight for 500 ms.",
    ]
    private static let timeoutParam: JSONValue = ["type": "integer", "minimum": 1, "maximum": 60000, "description": "Milliseconds, 15000 by default."]
    static let diffParam: JSONValue = [
        "type": "boolean",
        "description": "true by default: once the page has loaded as far as domcontentloaded, the result’s diff says what changed in the viewport since this session’s last default snapshot of the page, viewport scope and 300 nodes (the whole viewport snapshot for a new page or when there was none), as snapshot text.",
    ]

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
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
                "agentGroup": .bool(tab.isInAgentGroup),
            ]
            if let dialog = hub.tabs[tab.id]?.dialog { fields["dialog"] = dialog.json }
            if let opener = tab.opener, open.contains(ObjectIdentifier(opener)) { fields["openedBy"] = .string(hub.id(for: opener)) }
            return .object(fields)
        }
        return ["window": .object(window), "tabs": .array(tabs)]
    }

    // MARK: Opening, closing, selecting

    static let tabOpen = AgentTool(
        name: "tab_open",
        description: "Opens a tab in the background, in the sidebar’s Agent group. The user’s selected tab and focus stay as they are; call tab_select to show it. If its page fails to load, the tab stays open, showing the error, and the error names it.",
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
        if let url { try hub.checkNotBlocked(url) }
        let wait = try arguments.wait(default: .commit)
        let timeout = try arguments.timeout(default: 15_000)
        let deadline = ContinuousClock.now + timeout
        guard let browser = hub.browser else { throw AgentToolError(code: "unsupported", message: "Lithium has no window to open a tab in.") }
        // Asked before the tab opens: a file the user denies leaves no tab behind.
        if let url { try await hub.checkOpenable(url, in: nil, until: deadline) }
        let tab = browser.newAgentTab(session: session.label)
        let named = NamedTab(tab: tab, id: hub.id(for: tab))
        hub.touch(tab)
        guard let url else { return hub.page(named, reached: .load) }
        return try await hub.exclusive(named, until: deadline, timeout: timeout) {
            try await hub.navigation(in: named, wait: wait, deadline: deadline, timeout: timeout, landedWithinPage: nil) { tab.go(to: url) }
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
        // Lithium's own pages are shown to the user, never to the agent: those can wake.
        if !AgentURLs.isBlocked(named.tab.url) { try await hub.checkWakeable(named, until: .now + AgentConfirmations.timeout) }
        hub.browser?.select(named.tab)
        hub.touch(named.tab)
        return hub.page(named, reached: nil)
    }

    // MARK: Navigation

    static let navigate = AgentTool(
        name: "navigate",
        description: "Opens an address in a tab and waits for it to load as far as wait says. A sleeping tab wakes, with its history.",
        inputSchema: schema(["tab": tabParam, "url": ["type": "string"], "wait": waitParam, "timeoutMs": timeoutParam, "diff": diffParam], required: ["tab", "url"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        let url = try arguments.url("url")
        try hub.checkNotBlocked(url)
        let wait = try arguments.wait(default: .load)
        let timeout = try arguments.timeout(default: 15_000)
        let diff = try arguments.bool("diff", default: true)
        let deadline = ContinuousClock.now + timeout
        return try await hub.exclusive(named, until: deadline, timeout: timeout) {
            try hub.checkDrivable(named)
            try await hub.checkOpenable(url, in: named, until: deadline)
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

    static let goBack = historyTool(name: "go_back", description: "Goes one page back in a tab’s history.", forward: false)
    static let goForward = historyTool(name: "go_forward", description: "Goes one page forward in a tab’s history.", forward: true)

    private static func historyTool(name: String, description: String, forward: Bool) -> AgentTool {
        AgentTool(name: name, description: description, inputSchema: schema(["tab": tabParam, "wait": waitParam, "timeoutMs": timeoutParam, "diff": diffParam], required: ["tab"])) { arguments, session, hub in
            let arguments = Arguments(value: arguments)
            let named = try hub.tab(named: try arguments.string("tab"))
            let wait = try arguments.wait(default: .load)
            let timeout = try arguments.timeout(default: 15_000)
            let diff = try arguments.bool("diff", default: true)
            let deadline = ContinuousClock.now + timeout
            return try await hub.exclusive(named, until: deadline, timeout: timeout) {
                try hub.checkDrivable(named)
                try await hub.checkWakeable(named, until: deadline)
                let tab = named.tab
                tab.wake()
                let list = tab.webView.backForwardList
                guard let item = forward ? list.forwardItem : list.backItem else {
                    throw AgentToolError(code: "navigation_failed", message: "\(named.id) has no page to go \(forward ? "forward" : "back") to.")
                }
                try await hub.checkOpenable(item.url, in: named, until: deadline)
                // Only an entry of the same site can be in the document shown (an anchor, a
                // `pushState`); the move counts once the tab is on that entry.
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
        description: "Reloads a tab’s page. A sleeping tab wakes, which loads it.",
        inputSchema: schema(["tab": tabParam, "wait": waitParam, "timeoutMs": timeoutParam, "diff": diffParam], required: ["tab"])
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
            try await hub.checkOpenable(url, in: named, until: deadline)
            let page = try await hub.navigation(in: named, wait: wait, deadline: deadline, timeout: timeout, landedWithinPage: nil) {
                if tab.isAsleep { tab.wake() } else { tab.reload() }
            }
            return try await hub.addingDiff(to: page, of: named, for: session, if: diff && wait > .commit, until: deadline)
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
        description: "Waits until a tab’s page has loaded (load: domcontentloaded or load), its address matches url (a glob such as https://example.com/done*), an element reaches a state (ref with state), text shows or goes (text with present), or none of the page’s requests has been in flight for networkIdle ms. Give exactly one of load, url, ref, text and networkIdle. A sleeping tab wakes, which loads its page. Text waits read the main frame and go on across its navigations.",
        inputSchema: schema([
            "tab": tabParam,
            "load": ["type": "string", "enum": ["domcontentloaded", "load"]],
            "url": ["type": "string", "description": "A glob (* any characters, ? one) matched against the whole address. Regular expressions aren’t supported."],
            "ref": ["type": "string", "description": "An element ref from snapshot, such as e9."],
            "state": ["type": "string", "enum": ["visible", "hidden", "enabled", "attached", "detached"], "description": "With ref; visible by default."],
            "text": ["type": "string", "description": "Text to wait for on the page, as a snapshot would show it; case and spacing don’t matter."],
            "present": ["type": "boolean", "description": "With text: true (default) waits until it shows, false until it is gone."],
            "networkIdle": ["type": "integer", "minimum": 0, "maximum": 30000, "description": "Milliseconds with no request of the page in flight, such as 500."],
            "timeoutMs": ["type": "integer", "minimum": 1, "maximum": 60000, "description": "Milliseconds, 10000 by default."],
            "diff": diffParam,
        ], required: ["tab"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let named = try hub.tab(named: try arguments.string("tab"))
        let tab = named.tab
        let timeout = try arguments.timeout(default: 10_000)
        let diff = try arguments.bool("diff", default: true)
        let load = try arguments.optionalString("load")
        let pattern = try arguments.optionalString("url")
        let element = try arguments.optionalString("ref")
        let text = try arguments.optionalString("text")
        let idle = try arguments.value["networkIdle"].flatMap { $0 == .null ? nil : try arguments.int("networkIdle", default: 500, in: 0...30_000) }
        guard [load, pattern, element, text, idle.map(String.init)].compactMap({ $0 }).count == 1 else { throw Arguments.invalid("Give exactly one condition: load, url, ref, text or networkIdle.") }
        if idle != nil { try hub.checkNetworkIdle(.networkidle) }
        let condition = try DOMCondition(ref: element, text: text, arguments: arguments)
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
            try hub.checkDrivable(named)
            try await hub.checkWakeable(named, until: deadline)
            if let pattern, let matches {
                tab.wake()
                let met = try await hub.watch(named, until: deadline) { matches(tab.url?.absoluteString ?? "") ? true : nil }
                guard met != nil else {
                    throw hub.timedOut(named, after: timeout, "its address \(tab.url?.absoluteString ?? "none") doesn’t match \(pattern)")
                }
            } else if let state {
                // A sleeping tab loads its page once woken: that load is the one to wait for.
                if tab.isAsleep {
                    _ = try await hub.navigation(in: named, wait: state, deadline: deadline, timeout: timeout, landedWithinPage: nil) { tab.wake() }
                } else {
                    try await hub.waitForLoad(of: named, state, deadline: deadline, timeout: timeout)
                }
            } else if let condition {
                try await hub.wait(for: condition, in: named, deadline: deadline, timeout: timeout)
            } else if let idle {
                tab.wake()
                try await hub.waitForNetworkIdle(named, quiet: .milliseconds(idle), deadline: deadline, timeout: timeout)
            }
            var result = hub.page(named, reached: nil).object ?? [:]
            result["met"] = true
            result["elapsedMs"] = .int(Int((ContinuousClock.now - started) / .milliseconds(1)))
            return try await hub.addingDiff(to: .object(result), of: named, for: session, if: diff, until: deadline)
        }
    }

    // MARK: Helpers

    /// A tab showing Lithium's or an extension's page can be listed, selected and closed, nothing more.
    func checkDrivable(_ named: NamedTab) throws {
        guard AgentURLs.isBlocked(named.tab.url) else { return }
        throw AgentToolError(code: "blocked_page", message: "\(named.id) shows one of Lithium’s own or an extension’s pages, out of reach for agents.")
    }

    /// Waking a sleeping tab loads the page it slept on: every page an agent's call loads, named
    /// or not (Back, Forward, Reload, waking), goes through `checkOpenable`.
    func checkWakeable(_ named: NamedTab, until deadline: ContinuousClock.Instant) async throws {
        guard named.tab.isAsleep, let url = named.tab.url else { return }
        try await checkOpenable(url, in: named, until: deadline)
    }

    /// What every navigation tool returns: where the tab is now and how far its page got.
    func page(_ named: NamedTab, reached: LoadWait?) -> JSONValue {
        let tab = named.tab
        var fields: [String: JSONValue] = [
            "tab": .string(named.id),
            "url": .string(tab.url?.absoluteString ?? ""),
            "title": .string(tab.displayTitle),
            "loading": .bool(tab.isLoading),
        ]
        // `none`: the navigation has started, and nothing more is known; wait_for tells how it ends.
        if let reached { fields["state"] = .string(reached == LoadWait.none ? "started" : reached.rawValue) }
        if let status = tab.httpStatus { fields["status"] = .int(status) }
        return .object(fields)
    }

    /// Re-checks `check` as the tab changes, inside `exclusive`. The tab closing, the user
    /// navigating it, or an agent's `stop`, ends the wait with the error the agent reads.
    func watch<Value>(_ named: NamedTab, until deadline: ContinuousClock.Instant, _ check: @escaping @MainActor () throws -> Value?) async throws -> Value? {
        try await AgentWait.until(deadline) {
            try self.checkStillWaitable(named)
            return try check()
        }
    }

    /// `ignoringDialog`: an action's events go on under a dialog the page opened; the page
    /// handles them once it is answered, and the result names the dialog.
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

    /// Starts a navigation, then waits until the page it leads to (the next document the tab
    /// commits, never the one before) gets as far as `wait`. A move within the document shown
    /// (an anchor, Back to a `pushState` entry) commits nothing, and its document has loaded:
    /// when the call may be one, `landedWithinPage` tells it from a move the page's own script
    /// made meanwhile. Without it only a commit ends the wait. Lithium's error page committing
    /// for it is `navigation_failed`, whatever `wait`; a load that leads to another app's scheme
    /// is `navigation_cancelled`, as is one given up before it showed anything (a 204 answer, a
    /// stopped load); `none` answers before anything is known. A load that becomes a
    /// download asks the user (`confirmDownload`): allowed, the result names the file instead of
    /// a state; denied or unanswered, the call fails with the user's answer.
    func navigation(in named: NamedTab, wait: LoadWait, deadline: ContinuousClock.Instant, timeout: Duration, landedWithinPage: (@MainActor () -> Bool)?, _ start: () -> Void) async throws -> JSONValue {
        try checkNetworkIdle(wait)
        let tab = named.tab
        let since = LoadProgress(of: tab, agentTab(for: tab))
        let state = agentTab(for: tab)
        if let session = Self.callSession { state?.drive = AgentDrive(session: session, marks: tab.loadMarks, deadline: deadline) }
        // A call that ends with nothing loading, however it ends, leaves no load of the agent's.
        defer { if wait > .none, !tab.isLoading { state?.drive = nil } }
        start()
        // Laid out at the size the user would see it, not in an empty viewport.
        if !tab.isAsleep, tab.loadedWebView != nil { _ = sizedWebView(of: tab) }
        touch(tab)
        guard wait > .none else { return page(named, reached: LoadWait.none) }
        return try await follow(since, in: named, wait: wait, deadline: deadline, timeout: timeout, landedWithinPage: landedWithinPage)
    }

    /// How far a tab's loads had got when an agent's input began, so the load it started is told
    /// from the ones before.
    struct LoadProgress {
        var commits: Int
        let starts: Int
        let moves: Int
        let unshown: Int
        /// The load before may have failed with its error page still on its way: that page
        /// committing is not this call's answer.
        let earlierError: NSError?
        let answers: Int

        @MainActor
        init(of tab: Tab, _ state: AgentTab?) {
            (commits, starts, moves, unshown) = (tab.commits, tab.loadStarts, tab.sameDocumentNavigations, tab.unshownLoads)
            earlierError = tab.loadError
            answers = state?.downloadAnswers ?? 0
        }

        /// A load started since, ended without a page (a download, a refused scheme), or asked
        /// the user. A load already under way isn't one.
        @MainActor
        func hasMoved(_ tab: Tab, _ state: AgentTab?) -> Bool {
            tab.loadStarts > starts || tab.unshownLoads > unshown || (state?.downloadAnswers ?? 0) > answers
        }
    }

    /// Waits until the load the agent started gets as far as `wait` (see `navigation`).
    func follow(_ since: LoadProgress, in named: NamedTab, wait: LoadWait, deadline: ContinuousClock.Instant, timeout: Duration, landedWithinPage: (@MainActor () -> Bool)?) async throws -> JSONValue {
        enum Outcome { case document, withinPage, download(String?) }
        let tab = named.tab
        var commits = since.commits
        let (moves, unshown, earlierError, answers) = (since.moves, since.unshown, since.earlierError, since.answers)
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
            if let state, state.downloadAnswers > answers, case .failure(let error) = state.downloadAnswer { throw error }
            try self.checkStillWaitable(named)
            if tab.commits > commits {
                guard let error = tab.loadError else { return .document }
                if error === earlierError {
                    commits = tab.commits
                    // Still this call's load under way.
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
            if confirmations.isAsking(about: tab.id, .download) {
                throw AgentToolError(code: "confirmation_timeout", message: "\(named.id)’s page became a download, and the user didn’t answer within \(Int(timeout / .seconds(1))) s. Ask the user, then try again with a longer timeoutMs.")
            }
            throw timedOut(named, after: timeout, "no page had started to show")
        case .download(let fileName):
            var fields = page(named, reached: nil).object ?? [:]
            var download: [String: JSONValue] = ["file": fileName.map(JSONValue.string) ?? .null]
            if let state, state.downloadAnswers > answers, case .success(let grant) = state.downloadAnswer { download["grant"] = .string(grant.rawValue) }
            fields["download"] = .object(download)
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

    /// The tab's current document reaching `state`. Lithium's error page standing in for the
    /// page is `navigation_failed`.
    func waitForLoad(of named: NamedTab, _ state: LoadWait, deadline: ContinuousClock.Instant, timeout: Duration) async throws {
        let tab = named.tab
        let failed: @MainActor () throws -> Void = { try self.checkPageShown(named, before: "its page loaded") }
        if state == .domcontentloaded {
            // No delegate call marks DOMContentLoaded: the page is asked. A page script can keep
            // the page from answering for as long as it runs, so the answer races the deadline,
            // Stop, the user and the load ending, and the first of them ends the wait. An answer
            // still pending then comes once the script lets go, to nobody; no other is asked meanwhile.
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

    /// WebKit can report a load finished before its document's title, and the answer would name
    /// the page by its host. A document with a title waits up to a second for WebKit to report
    /// it. Asked as `documentIsReady` is, racing the wait, since a busy page can't answer.
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

    /// Lithium put the tab to sleep (its page stopped working, or memory ran short) or shows its
    /// error page: nothing is loading in it any more.
    func checkPageShown(_ named: NamedTab, before event: String) throws {
        let tab = named.tab
        if tab.isAsleep { throw AgentToolError(code: "navigation_failed", message: "\(named.id) went to sleep before \(event). Call navigate or reload to load it again.") }
        if let error = tab.loadError, !tab.isLoading { throw AgentToolError(code: "navigation_failed", message: "\(named.id) couldn’t open its page: \(error.localizedDescription)") }
    }

    /// Asked in a content world of Lithium's own, which the page can't see or touch. A tab
    /// without a page isn't given an empty one to ask.
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
