import Foundation
import LithiumProcess
import Security

/// Where agents find Lithium: `endpoint.json` in the agent folder, which only the user can read.
/// It is the only copy of the token, so turning access off (which deletes it) also retires the token.
struct AgentEndpoint: Codable, Equatable {
    var url: String
    var token: String
    var pid: Int32
    /// When `pid` started, so `lithium-mcp` can tell this Lithium from a process that reused its pid.
    var started: UInt64?
    var version = 1

    static let fileName = "endpoint.json"

    init(port: UInt16, token: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        url = "http://127.0.0.1:\(port)/mcp"
        self.token = token
        self.pid = pid
        started = LithiumProcess.started(pid)
    }

    static func read(in folder: URL) -> AgentEndpoint? {
        guard let data = try? Data(contentsOf: folder.appending(path: fileName)) else { return nil }
        return try? JSONDecoder().decode(AgentEndpoint.self, from: data)
    }

    /// The folder is 0700 and the file 0600, set before the token is written.
    func write(in folder: URL) throws {
        try AgentFiles.prepare(folder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let file = folder.appending(path: Self.fileName)
        let temporary = folder.appending(path: ".\(Self.fileName).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try encoder.encode(self).write(to: temporary)
            guard rename(temporary.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func delete(in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appending(path: fileName))
    }

    static func makeToken() -> String { randomString(bytes: 32) }

    static func randomString(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            fatalError("No system randomness for the agent token")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum AgentFiles {
    static let folder = URL.applicationSupportDirectory.appending(path: "Lithium/Agent")

    /// Creates the folder if needed and makes it the user's alone, even if it already existed.
    static func prepare(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }
}
