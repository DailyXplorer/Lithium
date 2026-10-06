import Foundation

/// One step of `batch` (or of `tab_open`'s `steps`), checked before any step runs. The tab it
/// acts in is the batch's unless it names one, filled in when it runs: a batch given `url` has
/// no tab yet when its steps are checked.
struct BatchStep {
    let tool: String
    let arguments: [String: JSONValue]
    let takesTab: Bool
}

/// How a step of `batch` ended, as the result lists it.
private enum BatchOutcome {
    case done([String: JSONValue])
    case failed(AgentToolError)
    case skipped

    func json(_ tool: String) -> JSONValue {
        var fields: [String: JSONValue] = ["tool": .string(tool)]
        switch self {
        case .done(let result):
            fields.merge(result) { kept, _ in kept }
            fields["ok"] = true
        case .failed(let error):
            fields["ok"] = false
            fields["code"] = .string(error.code)
            fields["message"] = .string(error.message)
        case .skipped:
            fields["skipped"] = true
        }
        return .object(fields)
    }
}

extension AgentHub {
    static let batchTools: [AgentTool] = [batchTool]
    static let maxBatchSteps = 20

    /// Tools a batch never runs: itself, and pictures, which can't come back in its result.
    private static let refusedInBatch: Set<String> = ["batch", "screenshot", "pdf"]

    /// Several calls in one round trip, for sequences an agent can predict (fill and submit, add
    /// three todos): each step runs as the tool alone would, through its own checks, prompts,
    /// redaction and log line, and the batch answers with each step's small fields and one diff.
    /// Other calls may run in the tab between two steps. Given `url` rather than `tab`, it opens
    /// a background tab for its steps, and `close` closes it at the end, so a whole task that
    /// reads a page and reports is one call.
    static let batchTool = AgentTool(
        name: "batch",
        description: "Run up to 20 tool calls in order, each as if called alone, with one diff at the end.",
        inputSchema: schema([
            "tab": AgentParam.tab,
            "url": ["type": "string", "description": "Instead of tab: open a background tab here first"],
            "ephemeral": ["type": "boolean", "description": "With url: a private tab"],
            "close": ["type": "boolean", "description": "With url: close the tab at the end, even on error"],
            "steps": [
                "type": "array", "maxItems": .int(maxBatchSteps),
                "items": [
                    "type": "object",
                    "properties": ["tool": AgentParam.text, "args": ["type": "object", "description": "The tool’s arguments; tab defaults to the batch’s"]],
                    "required": ["tool"],
                ],
            ],
            "stopOnError": ["type": "boolean", "description": "Default true: skip the steps after a failure"],
            "timeoutMs": ["type": "integer", "description": "For all steps, default 60000"],
            "diff": AgentParam.flag,
        ], required: ["steps"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let id = try arguments.optionalString("tab")
        let url = try arguments.optionalString("url").map { _ in try arguments.url("url") }
        guard (id == nil) != (url == nil) else { throw Arguments.invalid("Give tab, or url to open a tab for the batch, not both.") }
        let named = try id.map { try hub.tab(named: $0) }
        let steps = try hub.batchSteps(arguments.value["steps"], tab: id)
        let stopOnError = try arguments.bool("stopOnError", default: true)
        let diff = try arguments.bool("diff", default: true)
        let ephemeral = try arguments.bool("ephemeral", default: false)
        let close = try arguments.bool("close", default: false)
        if url == nil, ephemeral || close { throw Arguments.invalid("ephemeral and close go with url: a batch closes only the tab it opened.") }
        if let url { try hub.checkNotBlocked(url) }
        let timeout = try arguments.timeout(default: 60_000)
        let deadline = ContinuousClock.now + timeout
        if let named {
            return .object(try await hub.runBatch(steps, in: named, stopOnError: stopOnError, diff: diff, deadline: deadline, timeout: timeout, session: session))
        }
        guard let url else { throw Arguments.invalid("Give tab or url.") }
        let opened = try await hub.openAgentTab(url, ephemeral: ephemeral, session: session, until: deadline)
        // On every way out, a cancellation (Stop) included.
        defer { if close, hub.isOpen(opened.tab) { hub.browser?.close(opened.tab) } }
        do {
            _ = try await hub.load(url, in: opened, wait: .domcontentloaded, snapshot: false, session: session, deadline: deadline, timeout: timeout)
            var result = try await hub.runBatch(steps, in: opened, stopOnError: stopOnError, diff: diff, deadline: deadline, timeout: timeout, session: session)
            if close { result["closed"] = true }
            return .object(result)
        } catch let error as AgentToolError where close {
            throw AgentToolError(code: error.code, message: "\(error.message) Lithium closed the tab.", tab: error.tab)
        }
    }

    /// Runs `steps` in `named`, in order, each within what is left of `deadline`, and reads one
    /// diff of the tab after the last.
    func runBatch(_ steps: [BatchStep], in named: NamedTab, stopOnError: Bool, diff: Bool, deadline: ContinuousClock.Instant, timeout: Duration, session: MCPSession) async throws -> [String: JSONValue] {
        var outcomes: [BatchOutcome] = []
        for step in steps {
            if outcomes.contains(where: { if case .failed = $0 { stopOnError } else { false } }) {
                outcomes.append(.skipped)
                continue
            }
            let left = Int((deadline - .now) / .milliseconds(1))
            // A step that waits a set time needs it whole: less fails as the batch's timeout.
            var needs = 1
            if step.tool == "wait_for", case .int(let time)? = step.arguments["time"] { needs = time + 1 }
            if step.tool == "evaluate" { needs = Self.scriptTimeouts.lowerBound }
            guard left >= needs else {
                let ranOut = left < 1 ? "ran out before this step" : "had \(left) ms left, less than this step’s time"
                outcomes.append(.failed(AgentToolError(code: "timeout", message: "The batch’s \(Int(timeout / .milliseconds(1))) ms \(ranOut).")))
                continue
            }
            var stepArguments = step.arguments
            if step.takesTab, stepArguments["tab"] == nil { stepArguments["tab"] = .string(named.id) }
            if tool(named: step.tool)?.takes("timeoutMs") == true {
                stepArguments["timeoutMs"] = .int(min(Self.ownTimeout(of: step), left))
            }
            switch try await self.step(step.tool, .object(stepArguments), session: session) {
            case .success(let output):
                var fields = output.structured.object ?? [:]
                // The batch's one diff says what changed; the tab is the batch's unless named.
                for key in ["diff", "diffNote"] { fields[key] = nil }
                if fields["tab"] == .string(named.id) { fields["tab"] = nil }
                outcomes.append(.done(fields))
            case .failure(let error):
                outcomes.append(.failed(error))
            }
        }
        var result: [String: JSONValue] = [
            "tab": .string(named.id),
            "steps": .array(zip(steps, outcomes).map { $1.json($0.tool) }),
            "ok": .int(outcomes.filter { if case .done = $0 { true } else { false } }.count),
        ]
        if diff, isOpen(named.tab) {
            // A page read once after the last step; a page too busy to answer leaves it out.
            do {
                let until = max(deadline, .now + .seconds(3))
                result = try await exclusive(named, until: until, timeout: .seconds(3)) {
                    try await addingDiff(to: .object(result), of: named, for: session, if: true, until: until)
                }.object ?? result
            } catch let error as AgentToolError {
                result["diffNote"] = .string("No diff: \(error.message) Call snapshot.")
            }
        }
        // The page a step may have gone to, not the one the batch began on.
        return result.merging(page(named, reached: nil).object ?? [:]) { _, now in now }
    }

    /// The steps of a batch, refused before anything runs when one can't: an unknown tool, one a
    /// batch never runs, `evaluate` while the user hasn't turned scripts on, `tab_close` of the
    /// batch's own tab. `tab` is the batch's, nil when it opens one.
    func batchSteps(_ value: JSONValue?, tab: String?) throws -> [BatchStep] {
        guard case .array(let list)? = value, (1...Self.maxBatchSteps).contains(list.count) else {
            throw Arguments.invalid("steps must list 1 to \(Self.maxBatchSteps) steps.")
        }
        return try list.enumerated().map { index, step in try batchStep(step, place: "steps[\(index)]", tab: tab) }
    }

    private func batchStep(_ step: JSONValue, place: String, tab: String?) throws -> BatchStep {
        guard let name = step["tool"]?.string else { throw Arguments.invalid("\(place).tool must be a tool name.") }
        if Self.refusedInBatch.contains(name) { throw Arguments.invalid("\(place): \(name) can’t run inside a batch. Call it on its own.") }
        guard let tool = tool(named: name) else { throw Arguments.invalid("\(place).tool: there is no tool \(name).") }
        guard tool.isListed(self) else {
            throw AgentToolError(code: "unsupported", message: "\(place): the user hasn’t turned \(name) on in Lithium’s settings.")
        }
        var arguments: [String: JSONValue] = [:]
        if let given = step["args"], given != .null {
            guard let object = given.object else { throw Arguments.invalid("\(place).args must be an object.") }
            arguments = object
        }
        let ownTab = arguments["tab"] == nil || arguments["tab"] == tab.map { .string($0) }
        if name == "tab_close", ownTab { throw Arguments.invalid("\(place): a batch can’t close its own tab\(tab.map { " \($0)" } ?? "").") }
        // Only the batch's one diff is read; a tab a step opens is read by snapshot when needed.
        for key in ["diff", "snapshot"] where tool.takes(key) { arguments[key] = false }
        return BatchStep(tool: name, arguments: arguments, takesTab: tool.takes("tab"))
    }

    /// What the step's tool gives itself alone, so a step in a batch never waits longer than it
    /// would on its own.
    private static func ownTimeout(of step: BatchStep) -> Int {
        if let given = step.arguments["timeoutMs"], case .int(let milliseconds) = given { return milliseconds }
        switch step.tool {
        case "fill_form", "upload_files": return 60_000
        case "evaluate": return 5000
        case "wait_for":
            if case .int(let time)? = step.arguments["time"] { return min(60_000, time + 10_000) }
            return 10_000
        default: return 15_000
        }
    }
}

extension AgentTool {
    /// The tool's schema lists the argument.
    func takes(_ argument: String) -> Bool {
        inputSchema["properties"]?[argument] != nil
    }
}
