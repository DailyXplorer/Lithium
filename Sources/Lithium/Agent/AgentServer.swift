import Foundation
import Network

/// One HTTP request that passed every check of `AgentServer`, as `AgentHub` sees it.
enum AgentRequest: Sendable {
    /// `POST /mcp` with a JSON body.
    case message(JSONValue, session: String?, protocolVersion: String?)
    /// `DELETE /mcp`.
    case endSession(String?)
}

/// What `AgentHub` answers. A nil body is an empty response (202 for a notification).
struct AgentReply: Sendable {
    var status = 200
    var sessionID: String?
    var body: JSONValue?
}

/// The MCP endpoint: Streamable HTTP on 127.0.0.1, with just enough HTTP/1.1 for MCP clients
/// (keep-alive, Content-Length bodies). It checks Origin, Host, and the bearer token before
/// anything reaches `AgentHub`, and never touches `Browser`.
///
/// Every stored property is confined to `queue`, which is what makes the class Sendable.
final class AgentServer: @unchecked Sendable {
    typealias Handler = @Sendable (AgentRequest) async -> AgentReply

    static let maxBodyBytes = 1 << 20
    static let maxHeaderBytes = 16 * 1024
    /// MCP clients keep one or two connections; more is a runaway local process.
    static let maxConnections = 16

    private let queue = DispatchQueue(label: "app.lithium.agent-server")
    private let handler: Handler
    private var listener: NWListener?
    private var token: [UInt8]
    private var port: UInt16 = 0
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var starting: CheckedContinuation<UInt16, any Error>?

    /// Confined to `queue`, like the server.
    private final class Connection: @unchecked Sendable {
        let connection: NWConnection
        var buffer = Data()
        /// A request is with `AgentHub`; answers go out in order, so the next one waits.
        var isBusy = false
        var closesAfterReply = false

        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(token: String, handler: @escaping Handler) {
        self.token = Array(token.utf8)
        self.handler = handler
    }

    enum StartError: Error {
        case failed(NWError)
    }

    /// Listens on 127.0.0.1 only, on `port` or on any free port when it is 0, and returns the port.
    func start(port requested: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requested) ?? .any)
        parameters.acceptLocalOnly = true
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in self?.listener(listener, changedTo: state, port: requested) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.starting = continuation
                self.listener = listener
                listener.start(queue: self.queue)
            }
        }
    }

    private func listener(_ listener: NWListener, changedTo state: NWListener.State, port requested: UInt16) {
        guard let starting else { return }
        switch state {
        case .ready:
            self.starting = nil
            port = listener.port?.rawValue ?? requested
            starting.resume(returning: port)
        case .failed(let error), .waiting(let error):
            self.starting = nil
            listener.cancel()
            starting.resume(throwing: StartError.failed(error))
        case .cancelled:
            self.starting = nil
            starting.resume(throwing: CancellationError())
        default:
            break
        }
    }

    func setToken(_ token: String) {
        queue.sync { self.token = Array(token.utf8) }
    }

    /// Closes the listener and every connection.
    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.connection.cancel() }
            connections.removeAll()
        }
    }

    /// Ends every connection; one waiting on `AgentHub` closes once its answer is out.
    func closeConnections() {
        queue.sync {
            for (id, entry) in connections {
                if entry.isBusy {
                    entry.closesAfterReply = true
                } else {
                    entry.connection.cancel()
                    connections[id] = nil
                }
            }
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let entry = Connection(connection)
        connections[ObjectIdentifier(entry)] = entry
        connection.stateUpdateHandler = { [weak self, weak entry] state in
            guard let self, let entry else { return }
            switch state {
            case .failed, .cancelled: self.connections[ObjectIdentifier(entry)] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: entry)
    }

    private func receive(on entry: Connection) {
        entry.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak entry] data, _, isComplete, error in
            guard let self, let entry else { return }
            if let data { entry.buffer.append(data) }
            self.process(entry)
            if isComplete || error != nil {
                if !entry.isBusy { self.close(entry) } else { entry.closesAfterReply = true }
                return
            }
            self.receive(on: entry)
        }
    }

    private func close(_ entry: Connection) {
        entry.connection.cancel()
        connections[ObjectIdentifier(entry)] = nil
    }

    // MARK: Requests

    private struct Head {
        let method: String
        let target: String
        let version: String
        let headers: [String: String]
    }

    private func process(_ entry: Connection) {
        guard !entry.isBusy, connections[ObjectIdentifier(entry)] != nil else { return }
        guard let end = entry.buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            if entry.buffer.count > Self.maxHeaderBytes { respond(entry, status: 431, closing: true) }
            return
        }
        guard end.lowerBound <= Self.maxHeaderBytes else { return respond(entry, status: 431, closing: true) }
        guard let head = Self.parseHead(entry.buffer[..<end.lowerBound]) else { return respond(entry, status: 400, closing: true) }
        if head.headers["transfer-encoding"] != nil { return respond(entry, status: 411, closing: true) }
        var length = 0
        if let header = head.headers["content-length"] {
            guard let value = Int(header), value >= 0 else { return respond(entry, status: 400, closing: true) }
            length = value
        }
        guard length <= Self.maxBodyBytes else { return respond(entry, status: 413, closing: true) }
        let bodyStart = end.upperBound
        guard entry.buffer.count - (bodyStart - entry.buffer.startIndex) >= length else { return }
        let body = Data(entry.buffer[bodyStart..<(bodyStart + length)])
        entry.buffer = Data(entry.buffer[(bodyStart + length)...])
        if head.version != "HTTP/1.1" || head.headers["connection"]?.lowercased() == "close" { entry.closesAfterReply = true }
        handle(head, body: body, on: entry)
    }

    /// Checks in order of what a stranger could learn: a web page (Origin) or a rebound DNS
    /// name (Host) is refused before the token is even looked at.
    private func handle(_ head: Head, body: Data, on entry: Connection) {
        if head.headers["origin"] != nil { return respond(entry, status: 403) }
        let host = head.headers["host"]?.lowercased()
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else { return respond(entry, status: 403) }
        guard isAuthorized(head.headers["authorization"]) else {
            return respond(entry, status: 401, headers: [("WWW-Authenticate", "Bearer")])
        }
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
            // No server-initiated stream (GET) in this version.
            return respond(entry, status: 405, headers: [("Allow", "POST, DELETE")])
        }
        entry.isBusy = true
        let handler = handler
        Task {
            let reply = await handler(request)
            self.queue.async { self.finish(reply, on: entry) }
        }
    }

    private func finish(_ reply: AgentReply, on entry: Connection) {
        entry.isBusy = false
        guard connections[ObjectIdentifier(entry)] != nil else { return }
        var headers: [(String, String)] = []
        if let id = reply.sessionID { headers.append(("Mcp-Session-Id", id)) }
        respond(entry, status: reply.status, headers: headers, body: reply.body?.encoded())
        // A client may send its next request before reading this answer.
        process(entry)
    }

    /// Constant time, so the comparison doesn't tell a guesser how much of the token was right.
    private func isAuthorized(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let given = Array(header.dropFirst("Bearer ".count).utf8)
        guard given.count == token.count else { return false }
        return zip(given, token).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func respond(_ entry: Connection, status: Int, headers: [(String, String)] = [], body: Data? = nil, closing: Bool = false) {
        let closes = closing || entry.closesAfterReply
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
        let connection = entry.connection
        connection.send(content: Data(head.utf8) + (body ?? Data()), completion: .contentProcessed { _ in
            if closes { connection.cancel() }
        })
        if closes { connections[ObjectIdentifier(entry)] = nil }
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
