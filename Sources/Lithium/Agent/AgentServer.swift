import Foundation
import Network

/// One HTTP request that passed every check of `AgentServer`.
enum AgentRequest: Sendable {
    case message(JSONValue, session: String?, protocolVersion: String?)
    case endSession(String?)
}

/// What `AgentHub` answers. A nil body is an empty response (202 for a notification).
struct AgentReply: Sendable {
    var status = 200
    var sessionID: String?
    var body: JSONValue?
}

/// The MCP endpoint: Streamable HTTP on 127.0.0.1, with just enough HTTP/1.1 for MCP clients.
/// It checks Origin, Host, and the bearer token before anything reaches `AgentHub`.
///
/// Every stored property is confined to `queue`, which is what makes the class Sendable.
final class AgentServer: @unchecked Sendable {
    typealias Handler = @Sendable (AgentRequest) async -> AgentReply

    static let maxBodyBytes = 1 << 20
    static let maxHeaderBytes = 16 * 1024
    /// MCP clients keep one or two connections; more is a runaway local process.
    static let maxConnections = 16

    /// How long a connection may stay in one `Phase`. Without them, a local process that opens
    /// sockets and sends nothing would hold the 16 slots for good.
    struct Timeouts: Sendable {
        var head: TimeInterval = 10
        var body: TimeInterval = 30
        /// Between an answer and the next request, on a connection that presented the token.
        var idle: TimeInterval = 60
    }

    private enum Phase {
        case head, body, idle, busy
    }

    private let queue = DispatchQueue(label: "app.lithium.agent-server")
    private let timeouts: Timeouts
    private let handler: Handler
    private var listener: NWListener?
    private var token: [UInt8]
    private var port: UInt16 = 0
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var acceptedCount = 0
    /// The listener a pending `start` waits on; only its own events may settle that start.
    private var starting: (listener: NWListener, continuation: CheckedContinuation<UInt16, any Error>)?
    private var isStopped = false
    /// Runs on `queue` when the live listener dies (sleep, a network change), so the hub can
    /// listen again.
    private let listenerDidFail: @Sendable (NWError?) -> Void
    /// Tests only: runs on `queue` before the listener can report `.ready`, where the race tests
    /// land a late event from an earlier listener.
    var listenerDidStart: (@Sendable (AgentServer, NWListener) -> Void)?

    /// Confined to `queue`, like the server.
    private final class Connection: @unchecked Sendable {
        let connection: NWConnection
        /// Accept order, so eviction takes the oldest.
        let serial: Int
        /// A client keeps naming this port in Host after a relisten moved the server.
        let port: UInt16
        var buffer = Data()
        var isAuthenticated = false
        var inputEnded = false
        var phase: Phase?
        var deadline: DispatchWorkItem?
        /// Answers go out in order, so the next request waits.
        var isBusy = false
        /// Off while busy (but for a one-byte read), so a client's extra input stays in the
        /// socket instead of growing `buffer` without bound.
        var isReceiving = false
        var closesAfterReply = false
        var request: Task<Void, Never>?

        init(_ connection: NWConnection, serial: Int, port: UInt16) {
            self.connection = connection
            self.serial = serial
            self.port = port
        }
    }

    init(token: String, timeouts: Timeouts = Timeouts(), listenerDidFail: @escaping @Sendable (NWError?) -> Void = { _ in }, handler: @escaping Handler) {
        self.token = Array(token.utf8)
        self.timeouts = timeouts
        self.listenerDidFail = listenerDidFail
        self.handler = handler
    }

    enum StartError: Error {
        case failed(NWError)
    }

    /// Listens on 127.0.0.1 only; 0 picks any free port.
    func start(port requested: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requested) ?? .any)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in self?.listener(listener, changedTo: state, port: requested) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, port: listener.port?.rawValue ?? requested) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                // A `stop()` that ran before this block must not be undone by it.
                guard !self.isStopped else { return continuation.resume(throwing: CancellationError()) }
                self.abandonStart()
                self.starting = (listener, continuation)
                self.listener = listener
                listener.start(queue: self.queue)
                self.listenerDidStart?(self, listener)
            }
        }
    }

    /// A listener that failed still reports `.cancelled` later, possibly while a retry on
    /// another port is pending; the identity check keeps that late event away from the retry.
    func listener(_ listener: NWListener, changedTo state: NWListener.State, port requested: UInt16) {
        guard let starting, starting.listener === listener else {
            // Only an unexpected death of the live listener gets past this.
            guard self.listener === listener else { return }
            switch state {
            case .failed(let error), .waiting(let error):
                self.listener = nil
                listener.cancel()
                listenerDidFail(error)
            case .cancelled:
                self.listener = nil
                listenerDidFail(nil)
            default:
                break
            }
            return
        }
        switch state {
        case .ready:
            self.starting = nil
            port = listener.port?.rawValue ?? requested
            starting.continuation.resume(returning: port)
        case .failed(let error), .waiting(let error):
            self.starting = nil
            self.listener = nil
            listener.cancel()
            starting.continuation.resume(throwing: StartError.failed(error))
        case .cancelled:
            self.starting = nil
            starting.continuation.resume(throwing: CancellationError())
        default:
            break
        }
    }

    private func abandonStart() {
        listener?.cancel()
        listener = nil
        guard let starting else { return }
        self.starting = nil
        starting.continuation.resume(throwing: CancellationError())
    }

    func setToken(_ token: String) {
        queue.sync { self.token = Array(token.utf8) }
    }

    /// Tests only: the live listener dies the way it does after sleep or a network change.
    func failListener(_ error: NWError) {
        queue.sync {
            guard let listener else { return }
            listener.cancel()
            self.listener(listener, changedTo: .failed(error), port: port)
        }
    }

    /// Tests only.
    var bufferedBytes: Int {
        queue.sync { connections.values.map(\.buffer.count).max() ?? 0 }
    }

    /// Tests only.
    var connectionCount: Int {
        queue.sync { connections.count }
    }

    /// Tests only.
    func failConnections(_ error: NWError) {
        queue.sync { connections.values.forEach { connection($0, changedTo: .failed(error)) } }
    }

    /// For good: a start still pending throws.
    func stop() {
        queue.sync {
            isStopped = true
            abandonStart()
            connections.values.forEach(close)
        }
    }

    func closeConnections() {
        queue.sync {
            for entry in connections.values {
                if entry.isBusy { entry.closesAfterReply = true } else { closeAfterSending(entry) }
            }
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection, port: UInt16) {
        guard connections.count < Self.maxConnections || evictOne() else {
            connection.cancel()
            return
        }
        acceptedCount += 1
        let entry = Connection(connection, serial: acceptedCount, port: port)
        connections[ObjectIdentifier(entry)] = entry
        connection.stateUpdateHandler = { [weak self, weak entry] state in
            guard let self, let entry else { return }
            self.connection(entry, changedTo: state)
        }
        connection.start(queue: queue)
        receive(on: entry)
        updateDeadline(entry)
    }

    /// Makes room at the cap so strangers can't lock a client out: unauthenticated first, then
    /// idle clients, oldest first. A request in progress is never cut.
    private func evictOne() -> Bool {
        let candidates = connections.values.filter { !$0.isAuthenticated || $0.phase == .idle }
        guard let victim = candidates.min(by: { ($0.isAuthenticated ? 1 : 0, $0.serial) < ($1.isAuthenticated ? 1 : 0, $1.serial) }) else {
            return false
        }
        close(victim)
        return true
    }

    /// Staying in a phase keeps its deadline, so a client dribbling bytes can't push it back.
    private func updateDeadline(_ entry: Connection) {
        guard connections[ObjectIdentifier(entry)] != nil else { return }
        let phase: Phase
        if entry.isBusy {
            phase = .busy
        } else if entry.buffer.firstRange(of: Data("\r\n\r\n".utf8)) != nil {
            // `process` leaves no whole request behind, so a head here waits on its body.
            phase = .body
        } else {
            phase = entry.buffer.isEmpty && entry.isAuthenticated ? .idle : .head
        }
        guard phase != entry.phase else { return }
        entry.phase = phase
        entry.deadline?.cancel()
        entry.deadline = nil
        let timeout: TimeInterval
        switch phase {
        case .head: timeout = timeouts.head
        case .body: timeout = timeouts.body
        case .idle: timeout = timeouts.idle
        case .busy: return
        }
        let deadline = DispatchWorkItem { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.close(entry)
        }
        entry.deadline = deadline
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
    }

    /// Network.framework holds a failed connection's resources until it is cancelled.
    private func connection(_ entry: Connection, changedTo state: NWConnection.State) {
        if case .failed = state { close(entry) }
    }

    /// Reads only while not busy, so `buffer` stays bounded; while busy, a one-byte read watches
    /// for the client going away.
    private func receive(on entry: Connection) {
        entry.isReceiving = true
        entry.connection.receive(minimumIncompleteLength: 1, maximumLength: entry.isBusy ? 1 : 65_536) { [weak self, weak entry] data, _, isComplete, error in
            guard let self, let entry else { return }
            entry.isReceiving = false
            if let data { entry.buffer.append(data) }
            if isComplete || error != nil { entry.inputEnded = true }
            // EOF with nothing after the request: nobody waits for the answer, so the call ends now.
            // A client that half-closes behind pipelined requests still gets every answer.
            if entry.isBusy, entry.inputEnded, entry.buffer.isEmpty {
                self.close(entry)
                return
            }
            // A request cut by the EOF is dropped.
            self.process(entry)
            if entry.inputEnded {
                if !entry.isBusy { self.closeAfterSending(entry) }
                return
            }
            self.resumeReceiving(entry)
        }
    }

    private func resumeReceiving(_ entry: Connection) {
        guard !entry.isBusy || entry.buffer.isEmpty, !entry.isReceiving, !entry.inputEnded, connections[ObjectIdentifier(entry)] != nil else { return }
        receive(on: entry)
    }

    private func close(_ entry: Connection) {
        guard connections.removeValue(forKey: ObjectIdentifier(entry)) != nil else { return }
        entry.deadline?.cancel()
        entry.request?.cancel()
        entry.connection.cancel()
    }

    /// Like `close`, but sends are ordered, so the cancel waits for every answer already queued.
    private func closeAfterSending(_ entry: Connection) {
        guard connections.removeValue(forKey: ObjectIdentifier(entry)) != nil else { return }
        entry.deadline?.cancel()
        let connection = entry.connection
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: Requests

    private struct Head {
        let method: String
        let target: String
        let version: String
        let headers: [String: String]
    }

    /// Answers the buffered requests in order; one that went to `AgentHub` stops the loop until `finish`.
    private func process(_ entry: Connection) {
        while !entry.isBusy, connections[ObjectIdentifier(entry)] != nil, processNext(entry) {}
        updateDeadline(entry)
    }

    private func processNext(_ entry: Connection) -> Bool {
        switch Self.frame(entry.buffer) {
        case .partial:
            return false
        case .malformed(let status):
            respond(entry, status: status, closing: true)
        case .request(let head, let body):
            let content = Data(entry.buffer[body])
            entry.buffer = Data(entry.buffer[body.upperBound...])
            if head.version != "HTTP/1.1" || head.headers["connection"]?.lowercased() == "close" { entry.closesAfterReply = true }
            handle(head, body: content, on: entry)
        }
        return true
    }

    private enum Frame {
        case partial
        /// Answered with this status, then the connection closes.
        case malformed(Int)
        case request(Head, body: Range<Data.Index>)
    }

    private static func frame(_ buffer: Data) -> Frame {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeaderBytes ? .malformed(431) : .partial
        }
        guard end.lowerBound - buffer.startIndex <= maxHeaderBytes else { return .malformed(431) }
        guard let head = parseHead(buffer[..<end.lowerBound]) else { return .malformed(400) }
        if head.headers["transfer-encoding"] != nil { return .malformed(411) }
        var length = 0
        if let header = head.headers["content-length"] {
            guard let value = Int(header), value >= 0 else { return .malformed(400) }
            length = value
        }
        guard length <= maxBodyBytes else { return .malformed(413) }
        guard buffer.endIndex - end.upperBound >= length else { return .partial }
        return .request(head, body: end.upperBound..<(end.upperBound + length))
    }

    /// Checks in order of what a stranger could learn: a web page (Origin) or a rebound DNS
    /// name (Host) is refused before the token is even looked at.
    private func handle(_ head: Head, body: Data, on entry: Connection) {
        if head.headers["origin"] != nil { return respond(entry, status: 403) }
        let host = head.headers["host"]?.lowercased()
        guard host == "127.0.0.1:\(entry.port)" || host == "localhost:\(entry.port)" else { return respond(entry, status: 403) }
        guard isAuthorized(head.headers["authorization"]) else {
            return respond(entry, status: 401, headers: [("WWW-Authenticate", "Bearer")])
        }
        entry.isAuthenticated = true
        guard head.target == "/mcp" else { return respond(entry, status: 404) }
        let session = head.headers["mcp-session-id"]
        let request: AgentRequest
        switch head.method {
        case "POST":
            let type = head.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
            guard type == "application/json" else { return respond(entry, status: 415) }
            guard let message = try? JSONValue.decode(body) else {
                let error: JSONValue = ["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]]
                return respond(entry, status: 400, body: error.encoded())
            }
            request = .message(message, session: session, protocolVersion: head.headers["mcp-protocol-version"])
        case "DELETE":
            request = .endSession(session)
        default:
            // No server-initiated stream (GET).
            return respond(entry, status: 405, headers: [("Allow", "POST, DELETE")])
        }
        entry.isBusy = true
        let handler = handler
        entry.request = Task {
            let reply = await handler(request)
            self.queue.async { self.finish(reply, on: entry) }
        }
    }

    private func finish(_ reply: AgentReply, on entry: Connection) {
        entry.isBusy = false
        entry.request = nil
        guard connections[ObjectIdentifier(entry)] != nil else { return }
        var headers: [(String, String)] = []
        if let id = reply.sessionID { headers.append(("Mcp-Session-Id", id)) }
        respond(entry, status: reply.status, headers: headers, body: reply.body?.encoded())
        // A client may send its next request before reading this answer.
        process(entry)
        resumeReceiving(entry)
    }

    /// Constant time, so the comparison doesn't tell a guesser how much of the token was right.
    private func isAuthorized(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let given = Array(header.dropFirst("Bearer ".count).utf8)
        guard given.count == token.count else { return false }
        return zip(given, token).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func respond(_ entry: Connection, status: Int, headers: [(String, String)] = [], body: Data? = nil, closing: Bool = false) {
        // After the client's EOF, the answer to the last whole request it sent closes.
        let isLast: Bool
        if entry.inputEnded, case .partial = Self.frame(entry.buffer) { isLast = true } else { isLast = false }
        let closes = closing || entry.closesAfterReply || isLast
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Error")\r\n"
        if let body {
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
        } else {
            head += "Content-Length: 0\r\n"
        }
        head += "Cache-Control: no-store\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        if closes { head += "Connection: close\r\n" }
        head += "\r\n"
        entry.connection.send(content: Data(head.utf8) + (body ?? Data()), completion: .contentProcessed { _ in })
        if closes { closeAfterSending(entry) }
    }

    /// Spelled out: `HTTPURLResponse.localizedString` follows the user's language.
    private static let reasons = [
        200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 411: "Length Required", 413: "Content Too Large", 415: "Unsupported Media Type",
        431: "Request Header Fields Too Large", 503: "Service Unavailable",
    ]

    private static func parseHead(_ data: Data) -> Head? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].lowercased()
            // Two Host or Authorization headers could be read differently by a proxy and by us.
            guard headers[name] == nil else { return nil }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Head(method: String(start[0]), target: String(start[1]), version: String(start[2]), headers: headers)
    }
}
