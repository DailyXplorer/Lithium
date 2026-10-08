import Foundation
import LithiumProcess
import Network
import os
import Testing
@testable import Lithium

/// The agent server over real sockets. Requests are written by hand rather than with URLSession,
/// which sets Host itself and could not send the forged headers these tests need.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AgentServerTests {
    /// A hub in a folder of its own, listening on a free port.
    @MainActor
    private final class Fixture {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agent-\(UUID().uuidString)")
        let suite = "agent-tests-\(UUID().uuidString)"
        let hub: AgentHub

        init(tools: [AgentTool] = [], preferredPort: Int? = nil, now: @escaping @MainActor () -> Date = Date.init) async throws {
            let defaults = try #require(UserDefaults(suiteName: suite))
            if let preferredPort { defaults.set(preferredPort, forKey: Preference.agentPort) }
            hub = AgentHub(folder: folder, defaults: defaults, tools: tools, now: now)
            await hub.start()
            try #require(hub.state == .listening)
        }

        var endpoint: AgentEndpoint { AgentEndpoint.read(in: folder)! }
        var port: UInt16 { UInt16(URLComponents(string: endpoint.url)!.port!) }

        func post(_ message: JSONValue, session: String? = nil, headers: [String: String] = [:]) async throws -> HTTPReply {
            var all = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream", "Authorization": "Bearer \(endpoint.token)"]
            if let session { all["Mcp-Session-Id"] = session }
            all.merge(headers) { $1 }
            return try await RawHTTP.send(port: port, method: "POST", headers: all, body: message.encoded())
        }

        /// A session as a client opens one; returns its id.
        func initialize(version: String = "2025-06-18") async throws -> String {
            let reply = try await post(Self.initializeMessage(version: version))
            return try #require(reply.headers["mcp-session-id"])
        }

        static func initializeMessage(version: String = "2025-06-18") -> JSONValue {
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
                "protocolVersion": .string(version), "capabilities": [:], "clientInfo": ["name": "test-client", "version": "1.2"],
            ]]
        }

        deinit {
            try? FileManager.default.removeItem(at: folder)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }

    private static func call(_ tool: String, id: Int = 2) -> JSONValue {
        ["jsonrpc": "2.0", "id": .int(id), "method": "tools/call", "params": ["name": .string(tool), "arguments": [:]]]
    }

    /// A tool that signals `started`, then sleeps until cancelled.
    private static func waitTool(_ started: AsyncStream<Void>.Continuation) -> AgentTool {
        AgentTool(name: "wait", description: "Waits.", inputSchema: ["type": "object"]) { _, _, _ in
            started.yield()
            try await Task.sleep(for: .seconds(30))
            return [:]
        }
    }

    private static func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    // MARK: Protocol

    @Test func initializeOpensASession() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let reply = try await fixture.post(Fixture.initializeMessage())
        #expect(reply.status == 200)
        #expect(reply.headers["content-type"] == "application/json")
        let id = try #require(reply.headers["mcp-session-id"])
        #expect(id.count == 22)
        let result = try #require(reply.json?["result"])
        #expect(reply.json?["id"] == 1)
        #expect(result["protocolVersion"] == "2025-06-18")
        #expect(result["serverInfo"]?["name"] == "lithium")
        #expect(result["capabilities"] == ["tools": ["listChanged": false]])
        #expect(fixture.hub.sessions.map(\.label) == ["s1"])
        #expect(fixture.hub.sessions.first?.clientName == "test-client")

        let initialized = try await fixture.post(["jsonrpc": "2.0", "method": "notifications/initialized"], session: id)
        #expect(initialized.status == 202)
        #expect(initialized.body.isEmpty)
        let ping = try await fixture.post(["jsonrpc": "2.0", "id": 7, "method": "ping"], session: id)
        #expect(ping.json == ["jsonrpc": "2.0", "id": 7, "result": [:]])
    }

    @Test func unknownProtocolVersionGetsTheNewest() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let reply = try await fixture.post(Fixture.initializeMessage(version: "2024-01-01"))
        #expect(reply.json?["result"]?["protocolVersion"] == "2025-11-25")
    }

    @Test func listsAndCallsTheStatusTool() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let session = try await fixture.initialize()
        let list = try await fixture.post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], session: session)
        let tools = try #require(list.json?["result"]?["tools"])
        #expect(tools == [[
            "name": "lithium_status",
            "description": .string(AgentHub.statusTool.description),
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
            "annotations": ["title": "Lithium status", "readOnlyHint": true, "idempotentHint": true, "openWorldHint": false],
        ]])

        let reply = try await fixture.post(Self.call("lithium_status", id: 3), session: session)
        let result = try #require(reply.json?["result"])
        let expected: JSONValue = ["browser": "Lithium", "version": .string(AgentHub.appVersion), "session": "s1", "sessions": 1, "protocolVersion": "2025-06-18"]
        #expect(result["structuredContent"] == expected)
        #expect(result["isError"] == false)
        let text = try #require(result["content"]?.arrayValue?.first?["text"]?.string)
        #expect(try JSONValue.decode(Data(text.utf8)) == expected)
    }

    @Test func answersJSONRPCErrors() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let session = try await fixture.initialize()

        let unknownMethod = try await fixture.post(["jsonrpc": "2.0", "id": 4, "method": "resources/list"], session: session)
        #expect(unknownMethod.status == 200)
        #expect(unknownMethod.json?["error"]?["code"] == -32601)
        #expect(unknownMethod.json?["id"] == 4)

        let unknownTool = try await fixture.post(Self.call("eval"), session: session)
        #expect(unknownTool.json?["error"] == ["code": -32602, "message": "Unknown tool: eval"])

        let batch = try await fixture.post([["jsonrpc": "2.0", "id": 5, "method": "ping"]], session: session)
        #expect(batch.status == 400)
        #expect(batch.json?["error"]?["code"] == -32600)

        let garbage = try await RawHTTP.send(port: fixture.port, method: "POST", headers: [
            "Content-Type": "application/json", "Authorization": "Bearer \(fixture.endpoint.token)", "Mcp-Session-Id": session,
        ], body: Data("{\"jsonrpc\":".utf8))
        #expect(garbage.status == 400)
        #expect(garbage.json == ["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]])

        let notJSON = try await fixture.post(["jsonrpc": "2.0", "id": 6, "method": "ping"], session: session, headers: ["Content-Type": "text/plain"])
        #expect(notJSON.status == 415)
    }

    @Test func requiresALiveSession() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let ping: JSONValue = ["jsonrpc": "2.0", "id": 9, "method": "ping"]

        let missing = try await fixture.post(ping)
        #expect(missing.status == 400)
        #expect(missing.json?["error"]?["message"] == "Missing Mcp-Session-Id header. Send initialize first.")
        #expect(try await fixture.post(ping, session: "made-up").status == 404)

        let session = try await fixture.initialize()
        #expect(try await fixture.post(ping, session: session, headers: ["MCP-Protocol-Version": "1999-01-01"]).status == 400)
        #expect(try await fixture.post(ping, session: session, headers: ["MCP-Protocol-Version": "2025-06-18"]).status == 200)

        let end = try await RawHTTP.send(port: fixture.port, method: "DELETE", headers: [
            "Authorization": "Bearer \(fixture.endpoint.token)", "Mcp-Session-Id": session,
        ])
        #expect(end.status == 200)
        #expect(fixture.hub.sessions.isEmpty)
        #expect(try await fixture.post(ping, session: session).status == 404)
    }

    /// Clients that quit without DELETE leave their sessions behind; past the cap, a new client
    /// replaces the one heard from least recently.
    @Test func aNewSessionPastTheCapReplacesTheLeastRecentlyUsedOne() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        var ids: [String] = []
        for _ in 0..<AgentHub.maxSessions { ids.append(try await fixture.initialize()) }
        let ping: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        #expect(try await fixture.post(ping, session: ids[0]).status == 200)

        let fifth = try await fixture.post(Fixture.initializeMessage())
        #expect(fifth.headers["mcp-session-id"] != nil)
        #expect(fixture.hub.sessions.map(\.label) == ["s1", "s3", "s4", "s5"])
        #expect(try await fixture.post(ping, session: ids[1]).status == 404)
        #expect(try await fixture.post(ping, session: ids[0]).status == 200)

        let file = fixture.folder.appending(path: "log/\(AgentLog.fileName(for: Date()))")
        let entry = try JSONValue.decode(Data(try String(contentsOf: file, encoding: .utf8).split(separator: "\n")[0].utf8))
        #expect(entry["event"] == "session_evicted")
        #expect(entry["session"]?["id"] == "s2")
        #expect(entry["for"]?["id"] == "s5")
    }

    @Test func refusesANewSessionWhenEverySessionIsRunningACall() async throws {
        let started = AsyncStream<Void>.makeStream()
        let fixture = try await Fixture(tools: [Self.waitTool(started.continuation)])
        defer { fixture.hub.shutdown() }
        var pending: [Task<HTTPReply, any Error>] = []
        var iterator = started.stream.makeAsyncIterator()
        for _ in 0..<AgentHub.maxSessions {
            let session = try await fixture.initialize()
            pending.append(Task { try await fixture.post(Self.call("wait"), session: session) })
            await iterator.next()
        }

        let fifth = try await fixture.post(Fixture.initializeMessage())
        #expect(fifth.headers["mcp-session-id"] == nil)
        #expect(fifth.json?["error"]?["message"] == "Lithium already has 4 agent sessions, each running a tool call.")
        #expect(fixture.hub.sessions.count == AgentHub.maxSessions)

        fixture.hub.stop()
        for task in pending { _ = try await task.value }
    }

    @Test func dropsSessionsIdleForThirtyMinutes() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let idle = try await fixture.initialize()
        fixture.hub.dropIdleSessions(now: Date().addingTimeInterval(AgentHub.idleTimeout - 60))
        #expect(fixture.hub.sessions.count == 1)
        fixture.hub.dropIdleSessions(now: Date().addingTimeInterval(AgentHub.idleTimeout + 60))
        #expect(fixture.hub.sessions.isEmpty)
        #expect(try await fixture.post(["jsonrpc": "2.0", "id": 1, "method": "ping"], session: idle).status == 404)
    }

    @MainActor private final class Clock {
        var now = Date()
    }

    /// A call that outlasts the idle timeout keeps its session, which then counts as seen when the call ends.
    @Test func aCallLongerThanTheIdleTimeoutKeepsItsSession() async throws {
        let clock = Clock()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let hold = AgentTool(name: "hold", description: "", inputSchema: ["type": "object"]) { _, _, _ in
            started.continuation.yield()
            for await _ in release.stream { break }
            try Task.checkCancellation()
            return ["done": true]
        }
        let fixture = try await Fixture(tools: [hold], now: { clock.now })
        defer { fixture.hub.shutdown() }
        let session = try await fixture.initialize()
        let pending = Task { try await fixture.post(Self.call("hold"), session: session) }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()

        clock.now += AgentHub.idleTimeout + 60
        fixture.hub.dropIdleSessions(now: clock.now)
        let other = try await fixture.initialize()
        #expect(fixture.hub.sessions.count == 2)

        release.continuation.yield()
        let reply = try await pending.value
        #expect(reply.json?["result"]?["structuredContent"] == ["done": true])
        fixture.hub.dropIdleSessions(now: clock.now + AgentHub.idleTimeout - 60)
        #expect(fixture.hub.sessions.map(\.id) == [session, other])
        fixture.hub.dropIdleSessions(now: clock.now + AgentHub.idleTimeout + 60)
        #expect(fixture.hub.sessions.isEmpty)
    }

    @Test func limitsToolCallsPerSecond() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let session = try await fixture.initialize()
        var codes: [JSONValue?] = []
        for id in 0...AgentHub.maxCallsPerSecond {
            let reply = try await fixture.post(Self.call("lithium_status", id: 100 + id), session: session)
            codes.append(reply.json?["result"]?["structuredContent"]?["code"])
        }
        #expect(codes.dropLast().allSatisfy { $0 == nil })
        #expect(codes.last == "rate_limited")
    }

    @Test func refusesServerInitiatedStreams() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let reply = try await RawHTTP.send(port: fixture.port, method: "GET", headers: [
            "Authorization": "Bearer \(fixture.endpoint.token)", "Accept": "text/event-stream",
        ])
        #expect(reply.status == 405)
        #expect(reply.headers["allow"] == "POST, DELETE")
    }

    // MARK: Security

    @Test func refusesMissingOrWrongTokens() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let body = Fixture.initializeMessage().encoded()
        let missing = try await RawHTTP.send(port: fixture.port, method: "POST", headers: ["Content-Type": "application/json"], body: body)
        #expect(missing.status == 401)
        #expect(missing.headers["www-authenticate"] == "Bearer")
        var wrong = fixture.endpoint.token
        // One character off: a different one, whatever the token ends with.
        let last = wrong.removeLast()
        wrong.append(last == "A" ? "B" : "A")
        for authorization in ["Bearer \(wrong)", "Bearer ", "Basic \(fixture.endpoint.token)", fixture.endpoint.token] {
            let reply = try await RawHTTP.send(port: fixture.port, method: "POST", headers: ["Content-Type": "application/json", "Authorization": authorization], body: body)
            #expect(reply.status == 401, "\(authorization)")
        }
        #expect(fixture.hub.sessions.isEmpty)
    }

    @Test func refusesForeignHosts() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        for host in ["evil.example", "evil.example:\(fixture.port)", "127.0.0.1", "127.0.0.1:1", "192.168.1.2:\(fixture.port)", "[::1]:\(fixture.port)"] {
            #expect(try await fixture.post(Fixture.initializeMessage(), headers: ["Host": host]).status == 403, "\(host)")
        }
        #expect(fixture.hub.sessions.isEmpty)
        #expect(try await fixture.post(Fixture.initializeMessage(), headers: ["Host": "localhost:\(fixture.port)"]).status == 200)
        #expect(try await fixture.post(Fixture.initializeMessage(), headers: ["Host": "127.0.0.1:\(fixture.port)"]).status == 200)
    }

    @Test func refusesAnyOrigin() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        for origin in ["https://evil.example", "http://127.0.0.1:\(fixture.port)", "null", "lithium://settings"] {
            let reply = try await fixture.post(Fixture.initializeMessage(), headers: ["Origin": origin])
            #expect(reply.status == 403, "\(origin)")
            #expect(reply.headers["access-control-allow-origin"] == nil)
        }
        let preflight = try await RawHTTP.send(port: fixture.port, method: "OPTIONS", headers: [
            "Origin": "https://evil.example", "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "authorization",
        ])
        #expect(preflight.status == 403)
        #expect(fixture.hub.sessions.isEmpty)
    }

    @Test func answersARequestPipelinedBehindARefusedOne() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let body = Fixture.initializeMessage().encoded()
        func request(_ headers: [String: String]) -> Data {
            let all = ["Host": "127.0.0.1:\(fixture.port)", "Content-Type": "application/json", "Content-Length": "\(body.count)"]
                .merging(headers) { $1 }
            return Data(("POST /mcp HTTP/1.1\r\n" + all.map { "\($0): \($1)\r\n" }.joined() + "\r\n").utf8) + body
        }
        let token = "Bearer \(fixture.endpoint.token)"
        let data = try await RawHTTP.exchange(port: fixture.port, request:
            request(["Authorization": token, "Origin": "https://evil.example"])
            + request(["Authorization": "Bearer wrong"])
            + request(["Authorization": token, "Connection": "close"]))
        let replies = try RawHTTP.parseAll(data)
        #expect(replies.map(\.status) == [403, 401, 200])
        #expect(replies.last?.headers["connection"] == "close")
        #expect(fixture.hub.sessions.count == 1)
    }

    /// A client that half-closes right after its requests still reads every refusal before EOF.
    /// Enough refusals that some are still queued in the server when its EOF arrives.
    @Test func answersRefusedRequestsBeforeAHalfClose() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        func request(_ authorization: String, body: String) -> String {
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nAuthorization: \(authorization)\r\n"
                + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        }
        let refused = 2000
        let data = try await RawHTTP.halfClosedExchange(port: fixture.port, request: Data((
            String(repeating: request("Bearer wrong", body: "{}"), count: refused) + request("Bearer \(fixture.endpoint.token)", body: "{")
        ).utf8))
        let replies = try RawHTTP.parseAll(data)
        #expect(replies.map(\.status) == Array(repeating: 401, count: refused) + [400])
        #expect(replies.first?.headers["www-authenticate"] == "Bearer")
        #expect(replies.last?.json == ["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]])
    }

    @Test func refusesBodiesOverOneMegabyte() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let reply = try await RawHTTP.send(port: fixture.port, method: "POST", headers: [
            "Content-Type": "application/json", "Authorization": "Bearer \(fixture.endpoint.token)",
        ], body: Data(repeating: 0x20, count: AgentServer.maxBodyBytes + 1))
        #expect(reply.status == 413)
    }

    @Test func listensOnIPv4LoopbackOnly() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        #expect(await RawHTTP.canConnect(host: "127.0.0.1", port: fixture.port))
        #expect(await !RawHTTP.canConnect(host: "::1", port: fixture.port))
    }

    @Test func writesTheEndpointForTheUserAlone() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let endpoint = fixture.endpoint
        #expect(endpoint.url == "http://127.0.0.1:\(fixture.hub.port!)/mcp")
        #expect(endpoint.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(endpoint.started != nil)
        #expect(endpoint.started == LithiumProcess.started(endpoint.pid))
        #expect(endpoint.version == 1)
        #expect(endpoint.token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil)
        #expect(try permissions(fixture.folder) == 0o700)
        #expect(try permissions(fixture.folder.appending(path: AgentEndpoint.fileName)) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }

    @Test func resetTokenRetiresTheOldOne() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let old = fixture.endpoint.token
        let session = try await fixture.initialize()
        fixture.hub.resetToken()
        let new = fixture.endpoint.token
        #expect(new != old)
        #expect(fixture.hub.sessions.isEmpty)
        #expect(try permissions(fixture.folder.appending(path: AgentEndpoint.fileName)) == 0o600)
        let withOld = try await fixture.post(Fixture.initializeMessage(), headers: ["Authorization": "Bearer \(old)"])
        #expect(withOld.status == 401)
        #expect(try await fixture.post(["jsonrpc": "2.0", "id": 1, "method": "ping"], session: session).status == 404)
        #expect(try await fixture.post(Fixture.initializeMessage()).status == 200)
    }

    /// A quit leaves the endpoint file behind, and its port to whoever takes it: the token it
    /// names must not open the next run.
    @Test func makesANewTokenOnEveryStart() async throws {
        let first = try await Fixture()
        let token = first.endpoint.token
        first.hub.stop()
        let relaunched = AgentHub(folder: first.folder, defaults: UserDefaults(suiteName: first.suite)!)
        await relaunched.start()
        defer { relaunched.shutdown() }
        let fresh = try #require(AgentEndpoint.read(in: first.folder)?.token)
        #expect(fresh != token)
        let port = try #require(relaunched.port)
        let withOld = try await RawHTTP.send(port: port, method: "POST", headers: [
            "Content-Type": "application/json", "Authorization": "Bearer \(token)",
        ], body: Fixture.initializeMessage().encoded())
        #expect(withOld.status == 401)
        first.hub.shutdown()
    }

    /// A prompt's answer may be a PIN or a code, and goes into no field the log could weigh.
    @Test func neverLogsADialogAnswer() {
        let logged = CallNotes().logged(["tab": "t1", "accept": true, "text": "4921"], tool: "dialog_respond")
        #expect(logged == ["tab": "t1", "accept": true, "text": "[redacted]"])
    }

    /// A malformed `fill_form` fails, but its call is logged all the same: values given as a
    /// string, or as list items that aren't objects, never reach the log.
    @Test func neverLogsMalformedFillFormValues() {
        let notes = CallNotes()
        #expect(notes.logged(["tab": "t1", "fields": "hunter2secret"], tool: "fill_form") == ["tab": "t1", "fields": "[redacted]"])
        #expect(notes.logged(["tab": "t1", "fields": ["hunter2secret", ["ref": "e1", "value": "Ann"], ["ref": "e2"]]], tool: "fill_form")
            == ["tab": "t1", "fields": ["[redacted]", ["ref": "e1", "value": "[redacted]"], ["ref": "e2"]]])
    }

    /// Day files are named in the Gregorian calendar whatever the user's, so names sort by date
    /// and retention compares like with like; the day is the user's local one.
    @Test func logDayFilesAreGregorianDates() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-08T23:30:00Z"))
        #expect(AgentLog.fileName(for: date, timeZone: TimeZone(identifier: "UTC")!) == "2026-10-08.jsonl")
        #expect(AgentLog.fileName(for: date, timeZone: TimeZone(identifier: "Asia/Tokyo")!) == "2026-10-09.jsonl")
        #expect(AgentLog.fileName(for: date, timeZone: TimeZone(identifier: "America/Los_Angeles")!) == "2026-10-08.jsonl")
        #expect(AgentLog.dayCalendar.identifier == .gregorian)
    }

    @Test func takesAnotherPortWhenTheLastOneIsTaken() async throws {
        let first = try await Fixture()
        defer { first.hub.shutdown() }
        let second = try await Fixture(preferredPort: Int(first.port))
        defer { second.hub.shutdown() }
        #expect(second.port != first.port)
        #expect(UserDefaults(suiteName: second.suite)?.integer(forKey: Preference.agentPort) == Int(second.port))
    }

    /// The taken port's listener reports `.cancelled` after its failure, sometimes once the retry
    /// is already pending. The hook lands those late events inside that window every time.
    @Test func retryAfterATakenPortIgnoresTheFailedListener() async throws {
        let occupant = AgentServer(token: "t") { _ in AgentReply() }
        let taken = try await occupant.start(port: 0)
        defer { occupant.stop() }
        let server = AgentServer(token: "t") { _ in AgentReply() }
        defer { server.stop() }
        let failed = try NWListener(using: .tcp)
        await #expect(throws: AgentServer.StartError.self) { try await server.start(port: taken) }
        server.listenerDidStart = { server, _ in
            server.listener(failed, changedTo: .failed(.posix(.EADDRINUSE)), port: taken)
            server.listener(failed, changedTo: .cancelled, port: taken)
        }
        let port = try await server.start(port: 0)
        #expect(port != taken && port != 0)
        #expect(await RawHTTP.canConnect(host: "127.0.0.1", port: port), "port \(port), taken \(taken)")
    }

    @Test func aStoppedServerNeverListensAgain() async throws {
        let server = AgentServer(token: "t") { _ in AgentReply() }
        server.stop()
        await #expect(throws: CancellationError.self) { try await server.start(port: 0) }
    }

    @Test func shutdownStopsListeningAndDeletesTheEndpoint() async throws {
        let fixture = try await Fixture()
        let port = fixture.port
        fixture.hub.shutdown()
        #expect(AgentEndpoint.read(in: fixture.folder) == nil)
        #expect(await RawHTTP.refusesSoon(host: "127.0.0.1", port: port))
    }

    // MARK: Stop

    @Test func stopCancelsCallsAndEndsSessions() async throws {
        let started = AsyncStream<Void>.makeStream()
        let fixture = try await Fixture(tools: [Self.waitTool(started.continuation)])
        defer { fixture.hub.shutdown() }
        let session = try await fixture.initialize()
        let pending = Task { try await fixture.post(Self.call("wait"), session: session) }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        #expect(fixture.hub.isActing)

        let clock = ContinuousClock.now
        fixture.hub.stop()
        let reply = try await pending.value
        #expect(ContinuousClock.now - clock < .seconds(5))
        #expect(reply.headers["connection"] == "close")
        #expect(reply.json?["result"]?["isError"] == true)
        #expect(reply.json?["result"]?["structuredContent"] == ["code": "agent_stopped", "message": "The user stopped agents in Lithium."])
        #expect(!fixture.hub.isActing)
        #expect(fixture.hub.sessions.isEmpty)
        #expect(fixture.hub.state == .stopped)

        #expect(try await fixture.post(["jsonrpc": "2.0", "id": 1, "method": "ping"], session: session).status == 404)
        let refused = try await fixture.post(Fixture.initializeMessage())
        #expect(refused.headers["mcp-session-id"] == nil)
        #expect(refused.json?["error"]?["message"] == "The user stopped agents in Lithium. They can click Allow Agents Again in Lithium.")
        fixture.hub.stop()
        #expect(fixture.hub.state == .stopped)

        fixture.hub.allowAgain()
        #expect(try await fixture.post(Fixture.initializeMessage()).headers["mcp-session-id"] != nil)
    }

    @Test func clientCancellationKeepsTheSession() async throws {
        let started = AsyncStream<Void>.makeStream()
        let fixture = try await Fixture(tools: [Self.waitTool(started.continuation)])
        defer { fixture.hub.shutdown() }
        let session = try await fixture.initialize()
        let pending = Task { try await fixture.post(Self.call("wait", id: 42), session: session) }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        let cancel = try await fixture.post(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 42]], session: session)
        #expect(cancel.status == 202)
        let reply = try await pending.value
        #expect(reply.json?["result"]?["structuredContent"]?["code"] == "cancelled")
        #expect(fixture.hub.sessions.count == 1)
    }

    @Test func refusesASecondCallUnderAnIdInFlight() async throws {
        let started = AsyncStream<Void>.makeStream()
        let fixture = try await Fixture(tools: [Self.waitTool(started.continuation)])
        defer { fixture.hub.shutdown() }
        let session = try await fixture.initialize()
        let pending = Task { try await fixture.post(Self.call("wait", id: 42), session: session) }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()

        let duplicate = try await fixture.post(Self.call("lithium_status", id: 42), session: session)
        #expect(duplicate.json == ["jsonrpc": "2.0", "id": 42, "error": [
            "code": -32600, "message": "A call with this id is already in flight in this session.",
        ]])
        #expect(fixture.hub.isActing)

        _ = try await fixture.post(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 42]], session: session)
        let reply = try await pending.value
        #expect(reply.json?["result"]?["structuredContent"]?["code"] == "cancelled")
        #expect(!fixture.hub.isActing)
    }

    /// The tools cancel their own call as their last step, the way a Stop or a
    /// notifications/cancelled lands just as a tool finishes; the work is done, so it reports done.
    @Test func aCallThatFinishedIsReportedAsFinished() async throws {
        let thenCancelled = AgentTool(name: "then_cancelled", description: "", inputSchema: ["type": "object"]) { _, _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return ["done": true]
        }
        let thenStopped = AgentTool(name: "then_stopped", description: "", inputSchema: ["type": "object"]) { _, _, hub in
            hub.stop()
            return ["done": true]
        }
        let fixture = try await Fixture(tools: [thenCancelled, thenStopped])
        defer { fixture.hub.shutdown() }
        let session = try await fixture.initialize()
        for tool in ["then_cancelled", "then_stopped"] {
            let reply = try await fixture.post(Self.call(tool), session: session)
            #expect(reply.json?["result"]?["isError"] == false, "\(tool)")
            #expect(reply.json?["result"]?["structuredContent"] == ["done": true], "\(tool)")
        }
        #expect(fixture.hub.state == .stopped)
        let file = fixture.folder.appending(path: "log/\(AgentLog.fileName(for: Date()))")
        let entries = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { try JSONValue.decode(Data($0.utf8)) }
        #expect(entries.map { $0["tool"] } == ["then_cancelled", "then_stopped"])
        #expect(entries.map { $0["result"] } == [["ok": true], ["ok": true]])
    }

    // MARK: Listener

    @Test func listensAgainWhenTheListenerDies() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let session = try await fixture.initialize()
        let token = fixture.endpoint.token
        try #require(fixture.hub.server).failListener(.posix(.ENETDOWN))

        let ping: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        #expect(await Self.eventually { (try? await fixture.post(ping, session: session))?.status == 200 })
        #expect(fixture.hub.state == .listening)
        #expect(fixture.endpoint.token == token)
        #expect(fixture.endpoint.url == fixture.hub.url)
    }

    /// The old port is taken when the listener comes back, so the server moves to a new one; a
    /// connection accepted on the old port still names it in Host and still gets answers.
    @Test func aConnectionKeepsItsPortAcrossARelistenOnAnotherPort() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let session = try await fixture.initialize()
        let old = fixture.port
        let server = try #require(fixture.hub.server)
        let socket = try RawHTTP.connectedSocket(port: old)
        defer { Darwin.close(socket) }
        #expect(await Self.eventually { server.connectionCount == 1 })
        server.listenerDidStart = { server, listener in
            guard case .hostPort(_, let port) = listener.parameters.requiredLocalEndpoint, port.rawValue == old else { return }
            server.listener(listener, changedTo: .failed(.posix(.EADDRINUSE)), port: old)
        }
        server.failListener(.posix(.ENETDOWN))
        #expect(await Self.eventually { fixture.hub.state == .listening && fixture.hub.port.map { $0 != old } == true })
        let new = try #require(fixture.hub.port)

        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let request = Data(("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(old)\r\nAuthorization: Bearer \(fixture.endpoint.token)\r\n"
            + "Content-Type: application/json\r\nAccept: application/json, text/event-stream\r\nMcp-Session-Id: \(session)\r\n"
            + "Connection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)").utf8)
        let data = try await Task.detached {
            try RawHTTP.write(request, to: socket)
            return try RawHTTP.readToEOF(socket)
        }.value
        #expect(try RawHTTP.parseAll(data).map(\.status) == [200])

        let stale = try await Task.detached {
            let socket = try RawHTTP.connectedSocket(port: new)
            defer { Darwin.close(socket) }
            try RawHTTP.write(request, to: socket)
            return try RawHTTP.readToEOF(socket)
        }.value
        #expect(try RawHTTP.parseAll(stale).map(\.status) == [403])
        #expect(try await fixture.post(["jsonrpc": "2.0", "id": 2, "method": "ping"], session: session).status == 200)
    }

    /// Clients still post the old token to the old port, which anyone may hold once the server
    /// left it: a relisten on another port comes with a new token, and the old one is refused.
    @Test func aRelistenOnAnotherPortChangesTheToken() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let session = try await fixture.initialize()
        let old = fixture.port
        let oldToken = fixture.endpoint.token
        let server = try #require(fixture.hub.server)
        server.listenerDidStart = { server, listener in
            guard case .hostPort(_, let port) = listener.parameters.requiredLocalEndpoint, port.rawValue == old else { return }
            server.listener(listener, changedTo: .failed(.posix(.EADDRINUSE)), port: old)
        }
        server.failListener(.posix(.ENETDOWN))
        #expect(await Self.eventually { fixture.hub.state == .listening && fixture.hub.port.map { $0 != old } == true })

        #expect(fixture.endpoint.token != oldToken)
        let ping: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        #expect(try await fixture.post(ping, session: session, headers: ["Authorization": "Bearer \(oldToken)"]).status == 401)
        #expect(try await fixture.post(ping, session: session).status == 200)
    }

    @Test func failsWhenListeningAgainKeepsFailing() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        _ = try await fixture.initialize()
        let server = try #require(fixture.hub.server)
        server.listenerDidStart = { server, listener in
            server.listener(listener, changedTo: .failed(.posix(.EADDRNOTAVAIL)), port: 0)
        }
        server.failListener(.posix(.ENETDOWN))

        #expect(await Self.eventually { fixture.hub.state != .listening })
        guard case .failed(let message) = fixture.hub.state else {
            Issue.record("state is \(fixture.hub.state)")
            return
        }
        #expect(message.hasPrefix("Lithium’s agent server stopped listening"))
        #expect(message.hasSuffix("Turn agent access off and on to retry."))
        #expect(fixture.hub.server == nil)
        #expect(fixture.hub.sessions.isEmpty)
        #expect(fixture.hub.url == nil)
        let file = fixture.folder.appending(path: AgentEndpoint.fileName)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        fixture.hub.resetToken()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(fixture.hub.state == .failed(message))
    }

    /// The first listener reports `.ready`, then dies before the hub has resumed from starting it.
    @Test func aListenerThatDiesWhileTheHubStartsIsReplaced() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agent-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: "agent-tests-\(UUID().uuidString)"))
        let hub = AgentHub(folder: folder, defaults: defaults)
        defer { hub.shutdown() }
        let starts = OSAllocatedUnfairLock(initialState: 0)
        hub.listenerDidStart = { server, listener in
            guard starts.withLock({ $0 += 1; return $0 }) == 1 else { return }
            server.listener(listener, changedTo: .ready, port: 0)
            server.listener(listener, changedTo: .failed(.posix(.ENETDOWN)), port: 0)
        }
        await hub.start()

        #expect(await Self.eventually {
            guard starts.withLock({ $0 }) >= 2, hub.state == .listening, let port = hub.port, port != 0 else { return false }
            return await RawHTTP.canConnect(host: "127.0.0.1", port: port)
        })
        #expect(AgentEndpoint.read(in: folder)?.url == hub.url)
    }

    /// The listener a relisten started reports `.ready`, then dies before the hub has resumed.
    @Test func aListenerThatDiesWhileTheHubRelistensIsReplaced() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let session = try await fixture.initialize()
        let server = try #require(fixture.hub.server)
        let starts = OSAllocatedUnfairLock(initialState: 0)
        server.listenerDidStart = { server, listener in
            guard starts.withLock({ $0 += 1; return $0 }) == 1 else { return }
            server.listener(listener, changedTo: .ready, port: 0)
            server.listener(listener, changedTo: .failed(.posix(.ENETDOWN)), port: 0)
        }
        server.failListener(.posix(.ENETDOWN))

        let ping: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        // The faked `.ready` comes before the listener has a port, so the dead one is recorded as port 0.
        #expect(await Self.eventually {
            guard starts.withLock({ $0 }) >= 2, fixture.hub.port != 0 else { return false }
            return (try? await fixture.post(ping, session: session))?.status == 200
        })
        #expect(starts.withLock { $0 } >= 2)
        #expect(fixture.hub.state == .listening)
        #expect(fixture.endpoint.url == fixture.hub.url)
    }

    // MARK: Backpressure

    /// What a client sends while its call is in flight stays in the socket: the server's buffer
    /// holds at most the one read that carried the call.
    @Test func readsNothingMoreWhileACallIsInFlight() async throws {
        let arrived = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let server = AgentServer(token: "t") { _ in
            arrived.continuation.yield()
            for await _ in release.stream { break }
            return AgentReply(status: 202)
        }
        defer { server.stop() }
        let port = try await server.start(port: 0)
        let call = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer t\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        let flood = Data(repeating: 0x20, count: 16 << 20)
        // After the 202, the spaces are a head over the limit: a 431 closes the connection with
        // input unread, which resets it while this client may still be sending.
        let exchange = Task { try await RawHTTP.exchangeUntilReset(port: port, request: Data(call.utf8) + flood) }
        var iterator = arrived.stream.makeAsyncIterator()
        await iterator.next()
        try await Task.sleep(for: .seconds(1))
        #expect(server.bufferedBytes <= 65_536)

        release.continuation.yield()
        let replies = try await exchange.value
        #expect(replies.first?.status == 202)
        #expect(server.bufferedBytes == 0)
    }

    /// A client that resets its connection mid-call gets nothing back: the server cancels the
    /// connection, which closes the socket, and the tool's call, which keeps the session.
    @Test func aFailedConnectionIsCancelledWithItsCall() async throws {
        let started = AsyncStream<Void>.makeStream()
        let fixture = try await Fixture(tools: [Self.waitTool(started.continuation)])
        defer { fixture.hub.shutdown() }
        let session = try await fixture.initialize()
        let pending = Task { try await fixture.post(Self.call("wait"), session: session) }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        let server = try #require(fixture.hub.server)
        #expect(server.connectionCount == 1)

        server.failConnections(.posix(.ECONNRESET))
        #expect(server.connectionCount == 0)
        // Awaiting a task ignores the time limit, so a socket left open fails here instead of hanging.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return false }
            pending.cancel()
            return true
        }
        await #expect(throws: (any Error).self) { try await pending.value }
        watchdog.cancel()
        #expect(await watchdog.value == false, "the server closed the socket")
        #expect(await Self.eventually { !fixture.hub.isActing })
        #expect(fixture.hub.sessions.count == 1)
        let file = fixture.folder.appending(path: "log/\(AgentLog.fileName(for: Date()))")
        #expect(await Self.eventually {
            let line = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").last
            return line.flatMap { try? JSONValue.decode(Data($0.utf8)) }?["result"] == ["ok": false, "error": "cancelled"]
        })
        #expect(try await fixture.post(["jsonrpc": "2.0", "id": 1, "method": "ping"], session: session).status == 200)
    }

    // MARK: Connections

    /// A server with token `t` whose `hold` calls wait for `release`; every message is answered
    /// with its id.
    private static func holdingServer(timeouts: AgentServer.Timeouts = .init(), arrived: AsyncStream<Void>.Continuation, release: AsyncStream<Void>) -> AgentServer {
        AgentServer(token: "t", timeouts: timeouts) { request in
            guard case .message(let message, _, _) = request else { return AgentReply() }
            if message["method"] == "hold" {
                arrived.yield()
                for await _ in release { break }
            }
            return AgentReply(body: ["id": message["id"] ?? .null])
        }
    }

    private static func request(_ method: String, id: Int, port: UInt16) -> Data {
        let body = #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"}"#
        return Data(("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer t\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)").utf8)
    }

    /// While call 1 is held, the client sends call 2 and a ping, then half-closes. The server
    /// reads those and the EOF together once call 1 is answered, so the EOF lands while call 2
    /// is held: the ping behind it still gets its answer, and only that last answer closes.
    @Test func answersEveryRequestPipelinedBeforeAHalfClose() async throws {
        let arrived = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let server = Self.holdingServer(arrived: arrived.continuation, release: release.stream)
        defer { server.stop() }
        let port = try await server.start(port: 0)
        let socket = try RawHTTP.connectedSocket(port: port)
        defer { Darwin.close(socket) }
        var iterator = arrived.stream.makeAsyncIterator()
        try RawHTTP.write(Self.request("hold", id: 1, port: port), to: socket)
        await iterator.next()
        try RawHTTP.write(Self.request("hold", id: 2, port: port) + Self.request("ping", id: 3, port: port), to: socket)
        #expect(shutdown(socket, SHUT_WR) == 0)
        try await Task.sleep(for: .milliseconds(200))

        release.continuation.yield()
        await iterator.next()
        release.continuation.yield()
        let data = try await Task.detached { try RawHTTP.readToEOF(socket) }.value
        let replies = try RawHTTP.parseAll(data)
        #expect(replies.map(\.json) == [["id": 1], ["id": 2], ["id": 3]])
        #expect(replies.map { $0.headers["connection"] } == [nil, nil, "close"])
    }

    /// Local processes that take every slot without sending a request can't lock a client out:
    /// the client's connection evicts the oldest, and the head deadline closes the rest.
    @Test func strangersHoldingEverySlotDontLockAClientOut() async throws {
        let server = AgentServer(token: "t", timeouts: .init(head: 2, body: 2, idle: 60)) { _ in AgentReply(status: 202) }
        defer { server.stop() }
        let port = try await server.start(port: 0)
        var strangers: [Int32] = []
        defer { strangers.forEach { Darwin.close($0) } }
        for index in 0..<AgentServer.maxConnections {
            let socket = try RawHTTP.connectedSocket(port: port)
            strangers.append(socket)
            if index.isMultiple(of: 2) { try RawHTTP.write(Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1".utf8), to: socket) }
        }
        #expect(await Self.eventually { server.connectionCount == AgentServer.maxConnections })

        let reply = try await RawHTTP.send(port: port, method: "POST", headers: ["Authorization": "Bearer t", "Content-Type": "application/json"], body: Data("{}".utf8))
        #expect(reply.status == 202)
        #expect(server.connectionCount == AgentServer.maxConnections - 1)
        let closed = await Task.detached { [strangers] in strangers.map { (try? RawHTTP.readToEOF($0)) == Data() } }.value
        #expect(closed == Array(repeating: true, count: AgentServer.maxConnections))
        #expect(server.connectionCount == 0)
    }

    @Test func closesAKeepAliveConnectionLeftIdle() async throws {
        let server = AgentServer(token: "t", timeouts: .init(head: 30, body: 30, idle: 0.5)) { _ in AgentReply(status: 202) }
        defer { server.stop() }
        let port = try await server.start(port: 0)
        let request = Self.request("ping", id: 1, port: port)
        let start = ContinuousClock.now
        let data = try await Task.detached {
            let socket = try RawHTTP.connectedSocket(port: port)
            defer { Darwin.close(socket) }
            try RawHTTP.write(request, to: socket)
            return try RawHTTP.readToEOF(socket)
        }.value
        let elapsed = ContinuousClock.now - start
        let replies = try RawHTTP.parseAll(data)
        #expect(replies.map(\.status) == [202])
        #expect(replies.first?.headers["connection"] == nil)
        #expect(elapsed >= .milliseconds(500))
        #expect(elapsed < .seconds(5))
    }

    /// Every deadline is far shorter than the call; the connection waits for it, then for idle.
    @Test func aCallInFlightOutlastsEveryDeadline() async throws {
        let arrived = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let server = Self.holdingServer(timeouts: .init(head: 0.3, body: 0.3, idle: 0.3), arrived: arrived.continuation, release: release.stream)
        defer { server.stop() }
        let port = try await server.start(port: 0)
        let request = Self.request("hold", id: 1, port: port)
        let exchange = Task.detached {
            let socket = try RawHTTP.connectedSocket(port: port)
            defer { Darwin.close(socket) }
            try RawHTTP.write(request, to: socket)
            return try RawHTTP.readToEOF(socket)
        }
        var iterator = arrived.stream.makeAsyncIterator()
        await iterator.next()
        try await Task.sleep(for: .seconds(1))
        #expect(server.connectionCount == 1)

        release.continuation.yield()
        let replies = try RawHTTP.parseAll(try await exchange.value)
        #expect(replies.map(\.json) == [["id": 1]])
        #expect(server.connectionCount == 0)
    }

    // MARK: Log

    @Test func logsToolCallsWithoutTheSessionSecret() async throws {
        let fixture = try await Fixture()
        defer { fixture.hub.shutdown() }
        let session = try await fixture.initialize()
        _ = try await fixture.post(Self.call("lithium_status"), session: session)
        let file = fixture.folder.appending(path: "log/\(AgentLog.fileName(for: Date()))")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains(session))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 1)
        var entry = try JSONValue.decode(Data(lines[0].utf8)).object ?? [:]
        #expect(entry.removeValue(forKey: "ts")?.string?.hasSuffix("Z") == true)
        #expect(entry.removeValue(forKey: "ms") != nil)
        #expect(entry == [
            "seq": 1, "tool": "lithium_status", "params": [:], "result": ["ok": true],
            "session": ["id": "s1", "client": "test-client", "version": "1.2", "selfReported": true],
        ])
        #expect(try permissions(file) == 0o600)
    }

    @Test func prunesLogsOlderThanThirtyDays() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agent-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = AgentLog(folder: folder)
        let now = Date()
        let old = Calendar.current.date(byAdding: .day, value: -31, to: now)!
        let recent = Calendar.current.date(byAdding: .day, value: -29, to: now)!
        await log.append(["tool": "a"], at: old)
        await log.append(["tool": "b"], at: recent)
        await log.prune(now: now)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == [AgentLog.fileName(for: recent)])
    }

    /// Day files an earlier version named in a Buddhist year sort after every Gregorian one:
    /// pruning drops them instead of keeping them, as the newest, forever.
    @Test func prunesDayFilesNamedAfterTomorrow() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agent-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = AgentLog(folder: folder)
        let now = Date()
        await log.append(["tool": "a"], at: now)
        let tomorrow = AgentLog.fileName(for: AgentLog.dayCalendar.date(byAdding: .day, value: 1, to: now)!)
        for name in ["2569-10-01.jsonl", tomorrow] {
            FileManager.default.createFile(atPath: folder.appending(path: name).path, contents: Data("{}\n".utf8))
        }
        await log.prune(now: now)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == [AgentLog.fileName(for: now), tomorrow].sorted())
    }

    private func permissions(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? -1
    }
}

/// Access off is the default, and a `Browser` with it off has no hub and no server; turning
/// it on and off again runs and removes both.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct AgentAccessTests {
    @Test func accessIsOffUntilTurnedOn() async throws {
        UserDefaults.standard.removeObject(forKey: Preference.agentAccess)
        let browser = Browser()
        #expect(browser.agent == nil)
        #expect(AgentEndpoint.read(in: AgentFiles.folder) == nil)

        await browser.setAgentAccess(true)
        let hub = try #require(browser.agent)
        #expect(hub.state == .listening)
        let port = try #require(hub.port)
        #expect(AgentEndpoint.read(in: AgentFiles.folder)?.url == "http://127.0.0.1:\(port)/mcp")
        #expect(await RawHTTP.canConnect(host: "127.0.0.1", port: port))

        await browser.setAgentAccess(false)
        #expect(browser.agent == nil)
        #expect(!UserDefaults.standard.bool(forKey: Preference.agentAccess))
        #expect(AgentEndpoint.read(in: AgentFiles.folder) == nil)
        #expect(await RawHTTP.refusesSoon(host: "127.0.0.1", port: port))
    }
}

struct HTTPReply: Sendable {
    let status: Int
    /// Lowercased names.
    let headers: [String: String]
    let body: Data

    var json: JSONValue? { try? JSONValue.decode(body) }
}

/// A one-request HTTP/1.1 client over a plain socket, so tests choose every header.
enum RawHTTP {
    static func send(port: UInt16, method: String, path: String = "/mcp", headers: [String: String] = [:], body: Data = Data()) async throws -> HTTPReply {
        var all = ["Host": "127.0.0.1:\(port)", "Connection": "close"]
        all.merge(headers) { $1 }
        if !body.isEmpty || method == "POST" { all["Content-Length"] = "\(body.count)" }
        let head = "\(method) \(path) HTTP/1.1\r\n" + all.map { "\($0): \($1)\r\n" }.joined() + "\r\n"
        let data = try await exchange(port: port, request: Data(head.utf8) + body)
        return try parse(data)
    }

    /// `NWListener.cancel()` closes its socket asynchronously, so a connection made right after a
    /// stop can still land while the machine is busy (tests running side by side). Waits up to 5 s.
    static func refusesSoon(host: String, port: UInt16) async -> Bool {
        for _ in 0..<50 {
            if await !canConnect(host: host, port: port) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    static func canConnect(host: String, port: UInt16) async -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        let result = AsyncStream<Bool>.makeStream()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: result.continuation.yield(true)
            case .failed, .waiting, .cancelled: result.continuation.yield(false)
            default: break
            }
        }
        connection.start(queue: .global())
        // A connection still preparing after this long is as good as refused.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { result.continuation.yield(false) }
        var iterator = result.stream.makeAsyncIterator()
        return await iterator.next() ?? false
    }

    /// Sends the request and reads until the server closes the connection.
    static func exchange(port: UInt16, request: Data) async throws -> Data {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        let chunks = AsyncThrowingStream<Data, any Error>.makeStream()
        @Sendable func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data { chunks.continuation.yield(data) }
                if let error {
                    // A reset after the whole answer arrived is how a server that closes early looks.
                    if case .posix(.ECONNRESET) = error { chunks.continuation.finish() } else { chunks.continuation.finish(throwing: error) }
                } else if isComplete {
                    chunks.continuation.finish()
                } else {
                    receive()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state { chunks.continuation.finish(throwing: error) }
        }
        connection.start(queue: .global())
        connection.send(content: request, completion: .contentProcessed { _ in })
        receive()
        var data = Data()
        for try await chunk in chunks.stream { data.append(chunk) }
        return data
    }

    /// The whole answers received before the server closed or reset the connection. A server
    /// that closes with input still unread resets it, maybe while the request is still being
    /// sent; the answers before the reset count, and a reset before any whole answer throws.
    static func exchangeUntilReset(port: UInt16, request: Data) async throws -> [HTTPReply] {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        let chunks = AsyncThrowingStream<Data, any Error>.makeStream()
        // Only the receive path ends the stream: a failed connection completes the pending
        // receive with its error, after every byte it already read.
        @Sendable func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data { chunks.continuation.yield(data) }
                if let error { chunks.continuation.finish(throwing: error) } else if isComplete { chunks.continuation.finish() } else { receive() }
            }
        }
        connection.start(queue: .global())
        connection.send(content: request, completion: .contentProcessed { _ in })
        receive()
        var data = Data()
        do {
            for try await chunk in chunks.stream { data.append(chunk) }
        } catch NWError.posix(.ECONNRESET) {
            let replies = wholeReplies(data)
            guard !replies.isEmpty else { throw NWError.posix(.ECONNRESET) }
            return replies
        }
        return try parseAll(data)
    }

    /// The answers at the start of `data` whose head and body arrived in full.
    private static func wholeReplies(_ data: Data) -> [HTTPReply] {
        var rest = data
        var replies: [HTTPReply] = []
        while let reply = try? parse(rest) {
            let length = Int(reply.headers["content-length"] ?? "") ?? 0
            guard reply.body.count >= length else { break }
            replies.append(HTTPReply(status: reply.status, headers: reply.headers, body: Data(reply.body.prefix(length))))
            rest = Data(reply.body.dropFirst(length))
        }
        return replies
    }

    /// Over a BSD socket: writes the request, `shutdown(SHUT_WR)`, then reads to EOF. A reset
    /// throws instead of passing for EOF, unlike in `exchange`.
    static func halfClosedExchange(port: UInt16, request: Data) async throws -> Data {
        try await Task.detached {
            let socket = try connectedSocket(port: port)
            defer { Darwin.close(socket) }
            // Answers back up in the server while this client is still writing.
            var buffer: Int32 = 4096
            setsockopt(socket, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
            try write(request, to: socket)
            guard shutdown(socket, SHUT_WR) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            return try readToEOF(socket)
        }.value
    }

    /// A blocking BSD socket connected to the server; reads give up after `timeout` seconds,
    /// since a blocking read ignores the test's time limit.
    static func connectedSocket(port: UInt16, timeout: Int = 10) throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var limit = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(socket)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return socket
    }

    static func write(_ data: Data, to socket: Int32) throws {
        let written = data.withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) }
        guard written == data.count else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    /// Everything the server sends until it closes; a reset or the read timeout throws.
    static func readToEOF(_ socket: Int32) throws -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(socket, &chunk, chunk.count)
            guard count >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            if count == 0 { return data }
            data.append(contentsOf: chunk[..<count])
        }
    }

    private static func parse(_ data: Data) throws -> HTTPReply {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw URLError(.badServerResponse) }
        let lines = head.components(separatedBy: "\r\n")
        let status = Int(lines[0].split(separator: " ")[1]) ?? 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return HTTPReply(status: status, headers: headers, body: Data(data[end.upperBound...]))
    }

    /// Answers sent back to back on one connection, split by their Content-Length.
    static func parseAll(_ data: Data) throws -> [HTTPReply] {
        var rest = data
        var replies: [HTTPReply] = []
        while !rest.isEmpty {
            let reply = try parse(rest)
            let length = Int(reply.headers["content-length"] ?? "") ?? 0
            replies.append(HTTPReply(status: reply.status, headers: reply.headers, body: Data(reply.body.prefix(length))))
            rest = Data(reply.body.dropFirst(length))
        }
        return replies
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }
}
