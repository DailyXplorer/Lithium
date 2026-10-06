import Foundation
import LithiumProcess
import os
import Testing
@testable import Lithium

/// The built `lithium-mcp`, spawned with pipes against a hub listening in a folder of its own.
/// The bridge reads that folder's endpoint file, never the real one, and runs a stub in place of
/// `open`, so no app ever starts.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AgentBridgeTests {
    /// Lithium's side: a hub without a browser, writing its endpoint file in `folder`.
    @MainActor
    final class Lithium {
        let folder: URL
        let suite = "agent-bridge-tests-\(UUID().uuidString)"
        let hub: AgentHub

        init(folder: URL) async throws {
            self.folder = folder
            hub = AgentHub(folder: folder, defaults: try #require(UserDefaults(suiteName: suite)))
            await hub.start()
            try #require(hub.state == .listening)
        }

        var endpoint: AgentEndpoint { AgentEndpoint.read(in: folder)! }

        deinit {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }

    /// Everything the bridge wrote to stdout and stderr.
    final class Transcript: Sendable {
        private let data = OSAllocatedUnfairLock(initialState: Data())
        func append(_ chunk: Data) { data.withLock { $0.append(chunk) } }
        func contains(_ text: String) -> Bool { data.withLock { $0.range(of: Data(text.utf8)) != nil } }
    }

    @MainActor
    final class Bridge {
        /// Built with the tests, next to the test bundle (which holds this target's resources, or
        /// sits beside them, depending on the build system).
        static let executable: URL = {
            var folder = Bundle.module.bundleURL
            while folder.pathComponents.count > 1 {
                folder.deleteLastPathComponent()
                let candidate = folder.appending(path: "lithium-mcp")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
            return Bundle.module.bundleURL.deletingLastPathComponent().appending(path: "lithium-mcp")
        }()

        let process = Process()
        let transcript = Transcript()
        private let input = Pipe()
        private var output: AsyncStream<Data>.Iterator
        private var diagnostics: AsyncStream<Data>.Iterator

        init(folder: URL, open: URL = URL(filePath: "/usr/bin/false")) throws {
            try #require(FileManager.default.isExecutableFile(atPath: Self.executable.path), "lithium-mcp isn't built at \(Self.executable.path)")
            process.executableURL = Self.executable
            var environment = ProcessInfo.processInfo.environment
            environment["LITHIUM_MCP_ENDPOINT"] = folder.appending(path: AgentEndpoint.fileName).path
            environment["LITHIUM_MCP_OPEN"] = open.path
            // The hubs run in this process, so it is the Lithium the bridge looks for.
            environment["LITHIUM_MCP_APP"] = LithiumProcess.executable(ProcessInfo.processInfo.processIdentifier)
            process.environment = environment
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = input
            process.standardOutput = stdout
            process.standardError = stderr
            output = Self.lines(of: stdout, into: transcript).makeAsyncIterator()
            diagnostics = Self.lines(of: stderr, into: transcript).makeAsyncIterator()
            try process.run()
        }

        private static func lines(of pipe: Pipe, into transcript: Transcript) -> AsyncStream<Data> {
            AsyncStream { continuation in
                let pending = OSAllocatedUnfairLock(initialState: Data())
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else {
                        handle.readabilityHandler = nil
                        return continuation.finish()
                    }
                    transcript.append(chunk)
                    let lines = pending.withLock { pending in
                        pending.append(chunk)
                        var lines: [Data] = []
                        while let end = pending.firstIndex(of: 0x0A) {
                            lines.append(Data(pending[..<end]))
                            pending.removeSubrange(...end)
                        }
                        return lines
                    }
                    lines.forEach { continuation.yield($0) }
                }
            }
        }

        func send(_ message: JSONValue) {
            send(raw: message.encoded())
        }

        func send(raw line: Data) {
            input.fileHandleForWriting.write(line + Data([0x0A]))
        }

        /// The next line on stdout, which must be one JSON message.
        func next() async throws -> JSONValue {
            // A copy of AsyncStream's iterator reads on from the same stream.
            var lines = output
            let line = try #require(await lines.next(isolation: #isolation), "lithium-mcp closed stdout")
            return try JSONValue.decode(line)
        }

        func nextDiagnostic() async -> String? {
            var lines = diagnostics
            return await lines.next(isolation: #isolation).map { String(decoding: $0, as: UTF8.self) }
        }

        func close() {
            if process.isRunning { process.terminate() }
        }
    }

    private static let initialize: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
        "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test-client", "version": "1.2"],
    ]]

    private static func status(id: Int) -> JSONValue {
        ["jsonrpc": "2.0", "id": .int(id), "method": "tools/call", "params": ["name": "lithium_status", "arguments": [:]]]
    }

    private static func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "agent-bridge-\(UUID().uuidString)")
    }

    @Test func relaysASession() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let lithium = try await Lithium(folder: folder)
        defer { lithium.hub.shutdown() }
        let bridge = try Bridge(folder: folder)
        defer { bridge.close() }

        bridge.send(Self.initialize)
        let initialized = try await bridge.next()
        #expect(initialized["id"] == 1)
        #expect(initialized["result"]?["protocolVersion"] == "2025-06-18")
        #expect(initialized["result"]?["serverInfo"]?["name"] == "lithium")
        #expect(lithium.hub.sessions.map(\.clientName) == ["test-client"])

        bridge.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        bridge.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        // A notification gets no answer, so the next line is the list.
        let list = try await bridge.next()
        #expect(list["id"] == 2)
        guard case .array(let tools) = list["result"]?["tools"] else {
            Issue.record("No tools in \(list)")
            return
        }
        #expect(tools.compactMap { $0["name"]?.string } == ["lithium_status"])

        bridge.send(Self.status(id: 3))
        let status = try await bridge.next()
        #expect(status["id"] == 3)
        #expect(status["result"]?["structuredContent"]?["session"] == "s1")
        #expect(status["result"]?["isError"] == false)
        #expect(!bridge.transcript.contains(lithium.endpoint.token))
    }

    @Test func answersAMalformedLineAndGoesOn() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let lithium = try await Lithium(folder: folder)
        defer { lithium.hub.shutdown() }
        let bridge = try Bridge(folder: folder)
        defer { bridge.close() }

        bridge.send(raw: Data(#"{"jsonrpc": "2.0", "id": "#.utf8))
        #expect(try await bridge.next() == ["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]])
        bridge.send([1, 2])
        #expect(try await bridge.next() == ["jsonrpc": "2.0", "id": .null, "error": ["code": -32600, "message": "Send one JSON-RPC message per line."]])
        bridge.send(Self.initialize)
        #expect(try await bridge.next()["result"]?["serverInfo"]?["name"] == "lithium")
        #expect(bridge.process.isRunning)
    }

    @Test func tellsTheUserToTurnAccessOn() async throws {
        let folder = Self.temporaryFolder()
        let bridge = try Bridge(folder: folder)
        defer { bridge.close() }

        bridge.send(Self.initialize)
        #expect(try await bridge.next() == ["jsonrpc": "2.0", "id": 1, "error": [
            "code": -32000, "message": "Agent access is off. Turn it on in Lithium › Settings › Agents.",
        ]])
    }

    /// Lithium relaunched: another port, another token, and the session gone with the old server.
    @Test func followsTheEndpointFileToANewServer() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try await Lithium(folder: folder)
        let bridge = try Bridge(folder: folder)
        defer { bridge.close() }
        bridge.send(Self.initialize)
        _ = try await bridge.next()
        bridge.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        bridge.send(Self.status(id: 2))
        #expect(try await bridge.next()["result"]?["structuredContent"]?["session"] == "s1")
        let old = first.endpoint
        first.hub.shutdown()

        let second = try await Lithium(folder: folder)
        defer { second.hub.shutdown() }
        #expect(second.endpoint.url != old.url)
        #expect(second.endpoint.token != old.token)
        bridge.send(Self.status(id: 3))
        let status = try await bridge.next()
        #expect(status["id"] == 3)
        #expect(status["result"]?["structuredContent"]?["session"] == "s1")
        #expect(second.hub.sessions.map(\.clientName) == ["test-client"])
        #expect(await bridge.nextDiagnostic() == "lithium-mcp: Reconnected to Lithium in a new session.")
        #expect(!bridge.transcript.contains(old.token))
        #expect(!bridge.transcript.contains(second.endpoint.token))
    }

    @Test func reconnectsAfterResetToken() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let lithium = try await Lithium(folder: folder)
        defer { lithium.hub.shutdown() }
        let bridge = try Bridge(folder: folder)
        defer { bridge.close() }
        bridge.send(Self.initialize)
        _ = try await bridge.next()

        lithium.hub.resetToken()
        bridge.send(Self.status(id: 2))
        #expect(try await bridge.next()["result"]?["structuredContent"]?["session"] == "s2")
        #expect(lithium.hub.sessions.map(\.label) == ["s2"])
    }

    @Test func passesOnStopAndReconnectsOnceAllowed() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let lithium = try await Lithium(folder: folder)
        defer { lithium.hub.shutdown() }
        let bridge = try Bridge(folder: folder)
        defer { bridge.close() }
        bridge.send(Self.initialize)
        _ = try await bridge.next()

        lithium.hub.stop()
        bridge.send(Self.status(id: 2))
        #expect(try await bridge.next() == ["jsonrpc": "2.0", "id": 2, "error": [
            "code": -32000, "message": "The user stopped agents in Lithium. They can click Allow Agents Again in Lithium.",
        ]])
        lithium.hub.allowAgain()
        bridge.send(Self.status(id: 3))
        #expect(try await bridge.next()["result"]?["structuredContent"]?["session"] == "s2")
    }

    /// The endpoint file of a Lithium that quit: the bridge runs `open` (a stub here) and waits
    /// for the file of the Lithium it started.
    @Test func startsLithiumInTheBackground() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let exited = Process()
        exited.executableURL = URL(filePath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        try AgentEndpoint(port: 9, token: "kept-from-the-last-run", pid: exited.processIdentifier).write(in: folder)
        let bridge = try Bridge(folder: folder, open: Self.openStub(in: folder))
        defer { bridge.close() }

        bridge.send(Self.initialize)
        #expect(await bridge.nextDiagnostic() == "lithium-mcp: Lithium isn’t running; starting it in the background.")
        let lithium = try await Lithium(folder: folder)
        defer { lithium.hub.shutdown() }
        #expect(try await bridge.next()["result"]?["serverInfo"]?["name"] == "lithium")
        #expect(lithium.endpoint.token == "kept-from-the-last-run")
        #expect(try String(contentsOf: folder.appending(path: "open-arguments"), encoding: .utf8) == "-g\n-j\n-b\napp.lithium.browser\n")
    }

    /// After a quit or a restart, the file's pid runs another program, and another server holds
    /// the old port and would take the old token: the bridge sends it nothing and starts Lithium.
    @Test func startsLithiumWhenItsPidRunsAnotherProgram() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let impostor = try await Lithium(folder: Self.temporaryFolder())
        defer { try? FileManager.default.removeItem(at: impostor.folder) }
        defer { impostor.hub.shutdown() }
        let other = Process()
        other.executableURL = URL(filePath: "/bin/sleep")
        other.arguments = ["60"]
        try other.run()
        defer { other.terminate() }
        try AgentEndpoint(port: try #require(impostor.hub.port), token: impostor.endpoint.token, pid: other.processIdentifier).write(in: folder)

        try await expectStartsLithium(in: folder, sparing: impostor)
    }

    /// The pid is Lithium's executable again, but not the run that wrote the file.
    @Test func startsLithiumWhenItsPidStartedAnotherTime() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let impostor = try await Lithium(folder: Self.temporaryFolder())
        defer { try? FileManager.default.removeItem(at: impostor.folder) }
        defer { impostor.hub.shutdown() }
        var endpoint = AgentEndpoint(port: try #require(impostor.hub.port), token: impostor.endpoint.token)
        endpoint.started = try #require(endpoint.started) + 1
        try endpoint.write(in: folder)

        try await expectStartsLithium(in: folder, sparing: impostor)
    }

    private func expectStartsLithium(in folder: URL, sparing impostor: Lithium) async throws {
        let bridge = try Bridge(folder: folder, open: Self.openStub(in: folder))
        defer { bridge.close() }
        bridge.send(Self.initialize)
        #expect(await bridge.nextDiagnostic() == "lithium-mcp: Lithium isn’t running; starting it in the background.")

        let lithium = try await Lithium(folder: folder)
        defer { lithium.hub.shutdown() }
        #expect(try await bridge.next()["result"]?["serverInfo"]?["name"] == "lithium")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "open-arguments").path))
        #expect(lithium.hub.sessions.map(\.clientName) == ["test-client"])
        #expect(impostor.hub.sessions.isEmpty)
    }

    /// Stands in for `open`: writes its arguments next to itself and starts nothing.
    private static func openStub(in folder: URL) throws -> URL {
        let stub = folder.appending(path: "open")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0-arguments\"\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        return stub
    }
}
