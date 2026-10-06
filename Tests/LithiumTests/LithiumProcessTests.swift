import Foundation
import LithiumProcess
import Testing

/// The check `lithium-mcp` runs on the endpoint file's pid before it sends the token there.
struct LithiumProcessTests {
    private let me = ProcessInfo.processInfo.processIdentifier

    private static func run(_ executable: URL) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["60"]
        try process.run()
        return process
    }

    @Test func knowsTheProcessThatStartedThen() throws {
        let started = try #require(LithiumProcess.started(me))
        let executable = try #require(LithiumProcess.executable(me))
        #expect(LithiumProcess.isLithium(me, started: started, executable: executable))
        #expect(!LithiumProcess.isLithium(me, started: started + 1, executable: executable))
        #expect(!LithiumProcess.isLithium(me, started: nil, executable: executable))
        #expect(!LithiumProcess.isLithium(me, started: started), "the test runner isn't an app's Lithium")
    }

    @Test func refusesAnotherProgramUnderThePid() throws {
        let other = try Self.run(URL(filePath: "/bin/sleep"))
        defer { other.terminate() }
        let pid = other.processIdentifier
        #expect(LithiumProcess.executable(pid) == "/bin/sleep")
        let started = try #require(LithiumProcess.started(pid))
        #expect(!LithiumProcess.isLithium(pid, started: started, executable: LithiumProcess.executable(me)))
        #expect(!LithiumProcess.isLithium(pid, started: started))
    }

    @Test func refusesAPidNothingRunsUnder() throws {
        let exited = Process()
        exited.executableURL = URL(filePath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        let pid = exited.processIdentifier
        #expect(LithiumProcess.started(pid) == nil)
        #expect(LithiumProcess.executable(pid) == nil)
        #expect(!LithiumProcess.isLithium(pid, started: 0))
    }

    @Test func takesTheLithiumOfAnyApp() throws {
        let app = FileManager.default.temporaryDirectory.appending(path: "lithium-process-\(UUID().uuidString)/Copy.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let executable = app.appending(path: "Contents/MacOS/Lithium")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: executable)
        let lithium = try Self.run(executable)
        defer { lithium.terminate() }
        let pid = lithium.processIdentifier
        let started = try #require(LithiumProcess.started(pid))
        #expect(LithiumProcess.isLithium(pid, started: started))
        #expect(!LithiumProcess.isLithium(pid, started: started - 1))
    }
}
