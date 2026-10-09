import Foundation
import LithiumProcess

/// What Lithium writes to `endpoint.json` (`AgentEndpoint` in the app).
struct Endpoint: Decodable, Equatable, Sendable {
    let url: String
    let token: String
    let pid: Int32
    let started: UInt64?

    /// The token only goes to the process that wrote it: a stale file's pid and port may belong to anyone.
    func isRunning(as executable: String?) -> Bool {
        LithiumProcess.isLithium(pid, started: started, executable: executable)
    }

    /// Refuses a file other accounts could have written, and any address but this Mac's
    /// loopback, so a tampered file can't send the token elsewhere.
    static func read(_ file: URL) throws(Failure) -> Endpoint {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let data = try? Data(contentsOf: file) else { throw .accessOff }
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        guard mode & 0o077 == 0, owner == getuid() else { throw .unsafeFile }
        guard let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data),
              let url = URL(string: endpoint.url), url.scheme == "http",
              url.host() == "127.0.0.1" || url.host() == "localhost" else { throw .unsafeFile }
        return endpoint
    }
}

/// Starts Lithium hidden and in the background (`open -g -j`), so no window shows over the user's work.
struct Launcher: Sendable {
    /// `/usr/bin/open`, or a test stub.
    let program: URL
    let arguments: [String]

    /// The app this bridge ships in, else whichever Lithium LaunchServices knows.
    static func standard(program: URL) -> Launcher {
        let bundle = Bundle.main.bundleURL
        let target = bundle.pathExtension == "app" ? [bundle.path] : ["-b", "app.lithium.browser"]
        return Launcher(program: program, arguments: ["-g", "-j"] + target)
    }

    func launch() async -> Bool {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}

/// A JSON-RPC error the bridge answers in Lithium's place.
struct Failure: Error, Sendable {
    var code = -32000
    let message: String

    static let accessOff = Failure(message: "Agent access is off. Turn it on in Lithium › Settings › Agents.")
    static let unsafeFile = Failure(message: "Lithium’s endpoint file isn’t private to this account, so lithium-mcp won’t use it. Turn agent access off and on in Lithium › Settings › Agents.")
    static let notReady = Failure(message: "Lithium didn’t answer within 10 seconds. Open Lithium and check Settings › Agents.")
    static let launchFailed = Failure(message: "lithium-mcp couldn’t start Lithium. Open Lithium, then try again.")
    static let quit = Failure(message: "Lithium quit during this call, so it may or may not have run. The next call starts Lithium again.")
    static let lost = Failure(message: "The connection to Lithium broke during this call, so it may or may not have run.")
    static let notInitialized = Failure(code: -32600, message: "Send initialize first.")
    static let notOneMessage = Failure(code: -32600, message: "Send one JSON-RPC message per line.")
    static let parseError = Failure(code: -32700, message: "Parse error")

    static func http(_ status: Int) -> Failure {
        Failure(message: "Lithium answered HTTP \(status).")
    }

    /// `id` is the request's id as JSON, `null` when it couldn't be read.
    func response(id: Data?) -> Data {
        let text = (try? JSONSerialization.data(withJSONObject: message, options: .fragmentsAllowed)) ?? Data("\"\"".utf8)
        return Data(#"{"jsonrpc":"2.0","id":"#.utf8) + (id ?? Data("null".utf8))
            + Data(#","error":{"code":\#(code),"message":"#.utf8) + text + Data("}}".utf8)
    }
}
