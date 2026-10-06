import Foundation

/// One step of `batch`, checked before any step runs.
private struct BatchStep {
    let tool: String
    let arguments: [String: JSONValue]
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

    /// Tools a batch never runs: itself, a script, and pictures, which can't come back in its result.
    private static let refusedInBatch: Set<String> = ["batch", "evaluate", "screenshot", "pdf"]

    /// Several calls in one round trip, for sequences an agent can predict (fill and submit, add
    /// three todos): each step runs as the tool alone would, through its own checks, prompts,
    /// redaction and log line, and the batch answers with each step's small fields and one diff.
    /// Other calls may run in the tab between two steps.
    static let batchTool = AgentTool(
        name: "batch",
        description: "Run up to 20 tool calls in order, each as if called alone, with one diff at the end.",
        inputSchema: schema([
            "tab": AgentParam.tab,
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
        ], required: ["tab", "steps"])
    ) { arguments, session, hub in
        let arguments = Arguments(value: arguments)
        let id = try arguments.string("tab")
        let named = try hub.tab(named: id)
        guard case .array(let list)? = arguments.value["steps"], (1...maxBatchSteps).contains(list.count) else {
            throw Arguments.invalid("steps must list 1 to \(maxBatchSteps) steps.")
        }
        let steps = try list.enumerated().map { index, step in try hub.batchStep(step, number: index + 1, tab: id) }
        let stopOnError = try arguments.bool("stopOnError", default: true)
        let diff = try arguments.bool("diff", default: true)
        let timeout = try arguments.timeout(default: 60_000)
        let deadline = ContinuousClock.now + timeout
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
            guard left >= needs else {
                let ranOut = left < 1 ? "ran out before this step" : "had \(left) ms left, less than this step’s time"
                outcomes.append(.failed(AgentToolError(code: "timeout", message: "The batch’s \(Int(timeout / .milliseconds(1))) ms \(ranOut).")))
                continue
            }
            var stepArguments = step.arguments
            if hub.tool(named: step.tool)?.takes("timeoutMs") == true {
                stepArguments["timeoutMs"] = .int(min(AgentHub.ownTimeout(of: step), left))
            }
            switch try await hub.step(step.tool, .object(stepArguments), session: session) {
            case .success(let output):
                var fields = output.structured.object ?? [:]
                // The batch's one diff says what changed; the tab is the batch's unless named.
                for key in ["diff", "diffNote"] { fields[key] = nil }
                if fields["tab"] == .string(id) { fields["tab"] = nil }
                outcomes.append(.done(fields))
            case .failure(let error):
                outcomes.append(.failed(error))
            }
        }
        var result: [String: JSONValue] = [
            "tab": .string(id),
            "steps": .array(zip(steps, outcomes).map { $1.json($0.tool) }),
            "ok": .int(outcomes.filter { if case .done = $0 { true } else { false } }.count),
        ]
        guard diff, hub.isOpen(named.tab) else { return .object(result) }
        // A page read once after the last step; a page too busy to answer leaves it out.
        do {
            let until = max(deadline, .now + .seconds(3))
            result = try await hub.exclusive(named, until: until, timeout: .seconds(3)) {
                try await hub.addingDiff(to: .object(result), of: named, for: session, if: true, until: until)
            }.object ?? result
        } catch let error as AgentToolError {
            result["diffNote"] = .string("No diff: \(error.message) Call snapshot.")
        }
        return .object(result)
    }

    /// A step's tool and arguments, refused before anything runs when the batch can't run it.
    /// The batch's tab is the step's when it names none.
    private func batchStep(_ step: JSONValue, number: Int, tab: String) throws -> BatchStep {
        let place = "steps[\(number - 1)]"
        guard let name = step["tool"]?.string else { throw Arguments.invalid("\(place).tool must be a tool name.") }
        if Self.refusedInBatch.contains(name) { throw Arguments.invalid("\(place): \(name) can’t run inside a batch. Call it on its own.") }
        guard let tool = tool(named: name) else { throw Arguments.invalid("\(place).tool: there is no tool \(name).") }
        var arguments: [String: JSONValue] = [:]
        if let given = step["args"], given != .null {
            guard let object = given.object else { throw Arguments.invalid("\(place).args must be an object.") }
            arguments = object
        }
        if tool.takes("tab"), arguments["tab"] == nil { arguments["tab"] = .string(tab) }
        if name == "tab_close", arguments["tab"] == .string(tab) { throw Arguments.invalid("\(place): a batch can’t close its own tab \(tab).") }
        // Only the batch's one diff is read; a tab a step opens is read by snapshot when needed.
        for key in ["diff", "snapshot"] where tool.takes(key) { arguments[key] = false }
        return BatchStep(tool: name, arguments: arguments)
    }

    /// What the step's tool gives itself alone, so a step in a batch never waits longer than it
    /// would on its own.
    private static func ownTimeout(of step: BatchStep) -> Int {
        if let given = step.arguments["timeoutMs"], case .int(let milliseconds) = given { return milliseconds }
        switch step.tool {
        case "fill_form", "upload_files": return 60_000
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
