import Foundation

/// One line from the client, read just enough to route it.
struct Message: Sendable {
    let data: Data
    let isObject: Bool
    let method: String?
    /// The id as JSON; nil for a notification.
    let id: Data?

    var isRequest: Bool { method != nil && id != nil }

    init?(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return nil }
        let fields = object as? [String: Any]
        self.data = data
        isObject = fields != nil
        method = fields?["method"] as? String
        id = fields?["id"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
    }

    /// The client's own `initialize` under an id of the bridge's, whose answer it keeps.
    static func replay(_ initialize: Data, id: String) -> Data {
        guard var fields = (try? JSONSerialization.jsonObject(with: initialize)) as? [String: Any] else { return initialize }
        fields["id"] = id
        return (try? JSONSerialization.data(withJSONObject: fields)) ?? initialize
    }

    static let initialized = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
}

/// The client's MCP session as Lithium knows it at the moment.
struct Session: Sendable {
    let endpoint: Endpoint
    let id: String
    /// Counts sessions opened, so requests that failed together reconnect once.
    let generation: Int
}

/// Relays newline-delimited JSON-RPC from stdin to Lithium's Streamable HTTP endpoint and the
/// answers back to stdout. The client keeps one session for as long as the bridge runs: when
/// Lithium relaunches, moves to another port, gets a new token or ends the session, the bridge
/// opens a new one with the client's own `initialize` (and `notifications/initialized` if the
/// client sent it) and sends the request again. Lithium's state for the old session (snapshot
/// baselines, site grants, calls in flight) doesn't carry over.
actor Bridge {
    private let file: URL
    private let launcher: Launcher
    /// The executable Lithium runs as; nil for any app's `Contents/MacOS/Lithium`.
    private let lithium: String?
    private let launchTimeout: Duration
    private let http: URLSession
    private var session: Session?
    private var generation = 0
    private var initializeMessage: Data?
    private var clientSentInitialized = false
    /// Negotiated in `initialize`; MCP wants it on every later request.
    private var protocolVersion: String?
    private var reconnecting: Task<Result<Session, Failure>, Never>?

    init(file: URL, launcher: Launcher, lithium: String? = nil, launchTimeout: Duration = .seconds(10)) {
        self.file = file
        self.launcher = launcher
        self.lithium = lithium
        self.launchTimeout = launchTimeout
        let configuration = URLSessionConfiguration.ephemeral
        // The token goes to 127.0.0.1 only, never through a proxy.
        configuration.connectionProxyDictionary = [:]
        // Lithium bounds every call (60 s at most, a confirmation included); this only catches a hung server.
        configuration.timeoutIntervalForRequest = 300
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        http = URLSession(configuration: configuration)
    }

    func handle(_ line: Data) async {
        guard let message = Message(line) else { return write(Failure.parseError.response(id: nil)) }
        guard message.isObject else { return write(Failure.notOneMessage.response(id: nil)) }
        if message.method == "initialize" { return await initialize(message) }
        if message.method == "notifications/initialized" { clientSentInitialized = true }
        guard let session else {
            if message.isRequest { write(Failure.notInitialized.response(id: message.id)) }
            return
        }
        await relay(message, on: session, retrying: true)
    }

    /// Ends the session in Lithium, so the indicator stops showing the client at once.
    func end() async {
        guard let session else { return }
        self.session = nil
        _ = await post(nil, to: session.endpoint, session: session.id, method: "DELETE", timeout: 2)
    }

    // MARK: Sessions

    private func initialize(_ message: Message) async {
        initializeMessage = message.data
        clientSentInitialized = false
        do {
            let (session, body) = try await open(message.data, avoiding: nil)
            self.session = session
            write(body)
        } catch {
            write(error.response(id: message.id))
        }
    }

    /// Sends `initialize` where the endpoint file points, starting Lithium if needed. A refused
    /// connection reads the file once more: Lithium may be moving to another port.
    private func open(_ initialize: Data, avoiding stale: Endpoint?) async throws(Failure) -> (Session, Data) {
        var avoiding = stale
        for _ in 0..<2 {
            let endpoint = try await discover(avoiding: avoiding)
            guard case .answered(let status, let id, let body) = await post(initialize, to: endpoint, session: nil), status != 401 else {
                avoiding = endpoint
                continue
            }
            let reply = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if let error = reply?["error"] as? [String: Any] {
                throw Failure(code: error["code"] as? Int ?? -32000, message: error["message"] as? String ?? "Lithium refused the session.")
            }
            guard status == 200, let id, let result = reply?["result"] as? [String: Any] else { throw .http(status) }
            protocolVersion = result["protocolVersion"] as? String
            generation += 1
            return (Session(endpoint: endpoint, id: id, generation: generation), body)
        }
        throw .notReady
    }

    /// The endpoint to use: the file's, once the Lithium that wrote it runs. `stale`, the
    /// endpoint that just refused the connection, is waited past.
    private func discover(avoiding stale: Endpoint?) async throws(Failure) -> Endpoint {
        let endpoint = try Endpoint.read(file)
        if !endpoint.isRunning(as: lithium) {
            log("Lithium isn’t running; starting it in the background.")
            guard await launcher.launch() else { throw .launchFailed }
            return try await waitForEndpoint { [lithium] in $0.isRunning(as: lithium) }
        }
        guard let stale, stale == endpoint else { return endpoint }
        // Running, but not taking connections: starting, or listening again elsewhere. A listener
        // that comes back on the same port writes the same file, so only a connection tells.
        return try await waitForEndpoint { [lithium] in
            guard $0.isRunning(as: lithium) else { return false }
            if $0 != stale { return true }
            return await self.accepts($0)
        }
    }

    /// The one wait the bridge has: Lithium writes a fresh file once its server listens.
    private func waitForEndpoint(_ isFresh: (Endpoint) async -> Bool) async throws(Failure) -> Endpoint {
        let deadline = ContinuousClock.now + launchTimeout
        while true {
            let endpoint = try Endpoint.read(file)
            if await isFresh(endpoint) { return endpoint }
            guard ContinuousClock.now < deadline else { throw .notReady }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// One new session for every request that found the old one gone.
    private func reconnect(from stale: Session, refused: Bool) async -> Result<Session, Failure> {
        if let session, session.generation != stale.generation { return .success(session) }
        if let reconnecting { return await reconnecting.value }
        let task = Task { await self.reopen(avoiding: refused ? stale.endpoint : nil) }
        reconnecting = task
        let result = await task.value
        reconnecting = nil
        return result
    }

    private func reopen(avoiding stale: Endpoint?) async -> Result<Session, Failure> {
        guard let initializeMessage else { return .failure(.notInitialized) }
        do {
            let (session, _) = try await open(Message.replay(initializeMessage, id: "lithium-mcp-\(generation + 1)"), avoiding: stale)
            if clientSentInitialized { _ = await post(Message.initialized, to: session.endpoint, session: session.id) }
            self.session = session
            log("Reconnected to Lithium in a new session.")
            return .success(session)
        } catch {
            log("Couldn’t reconnect: \(error.message)")
            return .failure(error)
        }
    }

    // MARK: Relaying

    private func relay(_ message: Message, on session: Session, retrying: Bool) async {
        switch await post(message.data, to: session.endpoint, session: session.id) {
        case .answered(let status, _, _) where retrying && (status == 401 || status == 404):
            // A new token, or a session Lithium ended (Stop, relaunch, idle timeout).
            await retry(message, after: session, refused: false)
        case .refused where retrying:
            await retry(message, after: session, refused: true)
        case .lost where retrying:
            // Lithium only drops a connection under a call when it quits or turns access off;
            // with the same Lithium still running, the request never reached it.
            do {
                let endpoint = try Endpoint.read(file)
                guard endpoint.isRunning(as: lithium) else { return answer(message, .quit) }
                if endpoint == session.endpoint {
                    await relay(message, on: session, retrying: false)
                } else {
                    await retry(message, after: session, refused: false)
                }
            } catch {
                answer(message, error)
            }
        case .answered(let status, _, let body):
            guard message.isRequest else {
                if status != 202 { log("Lithium refused a notification (HTTP \(status)).") }
                return
            }
            if (try? JSONSerialization.jsonObject(with: body)) is [String: Any] { write(body) } else { answer(message, .http(status)) }
        case .refused:
            answer(message, .notReady)
        case .lost, .failed:
            answer(message, .lost)
        }
    }

    private func retry(_ message: Message, after stale: Session, refused: Bool) async {
        switch await reconnect(from: stale, refused: refused) {
        case .success(let session): await relay(message, on: session, retrying: false)
        case .failure(let failure): answer(message, failure)
        }
    }

    private func answer(_ message: Message, _ failure: Failure) {
        if message.isRequest { write(failure.response(id: message.id)) } else { log(failure.message) }
    }

    private enum Outcome {
        case answered(status: Int, session: String?, body: Data)
        /// Nothing listens: the request never left.
        case refused
        /// The connection closed before an answer.
        case lost
        /// Timed out or otherwise failed; Lithium may have run it.
        case failed
    }

    private func post(_ body: Data?, to endpoint: Endpoint, session: String?, method: String = "POST", timeout: TimeInterval? = nil) async -> Outcome {
        // The token only goes to the Lithium that wrote it: once that one quits, anyone may hold
        // its port, and so may anyone once that one moves to another port (the file then names
        // the new one). A refusal reads the file again, which starts Lithium if needed.
        guard endpoint.isRunning(as: lithium), (try? Endpoint.read(file))?.url == endpoint.url,
              let url = URL(string: endpoint.url) else { return .refused }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        if session != nil, let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        do {
            let (data, response) = try await http.data(for: request)
            guard let response = response as? HTTPURLResponse else { return .failed }
            return .answered(status: response.statusCode, session: response.value(forHTTPHeaderField: "Mcp-Session-Id"), body: data)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return .refused
        } catch let error as URLError where error.code == .networkConnectionLost {
            return .lost
        } catch {
            return .failed
        }
    }

    /// Whether a server listens at `endpoint` again, asked without the token.
    private func accepts(_ endpoint: Endpoint) async -> Bool {
        guard let url = URL(string: endpoint.url) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 1
        return (try? await http.data(for: request)) != nil
    }

    // MARK: Output

    /// stdout carries the protocol alone, one message per line.
    private func write(_ message: Data) {
        var line = message
        if line.contains(0x0A), let object = try? JSONSerialization.jsonObject(with: line),
           let compact = try? JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes) {
            line = compact
        }
        line.append(0x0A)
        // The client closed its end: nobody is left to answer.
        do { try FileHandle.standardOutput.write(contentsOf: line) } catch { exit(0) }
    }
}

/// Diagnostics for the client's log; never the token or the session id.
func log(_ text: String) {
    try? FileHandle.standardError.write(contentsOf: Data("lithium-mcp: \(text)\n".utf8))
}
