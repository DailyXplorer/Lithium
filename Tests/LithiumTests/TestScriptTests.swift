import Darwin
import Foundation
import Testing

/// scripts/test, run with stand-ins for swift, sandbox-exec and log, without a terminal.
struct TestScriptTests {
    /// Stopping a hung run (what the watchdog and a ⌃C do) ends the run and the test helper,
    /// which swift test starts outside the run's process group, without a terminal's job control.
    @Test func stoppingAHungRunEndsItsTestHelper() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "test-script-\(UUID())")
        let bin = folder.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pids = folder.appending(path: "pids")
        // A test run that hangs, with a helper in a process group of its own.
        let fakes = [
            "swift": """
                #!/bin/bash
                [ "$1" = test ] || exit 0
                perl -e 'setpgrp(0, 0); $0 = "swiftpm-testing-helper"; sleep 1000' &
                echo "$$ $!" >"$LITHIUM_FAKE_PIDS.tmp" && mv "$LITHIUM_FAKE_PIDS.tmp" "$LITHIUM_FAKE_PIDS"
                exec sleep 1000
                """,
            "sandbox-exec": "#!/bin/bash\nshift 2\nexec \"$@\"\n",
            "log": "#!/bin/bash\nexit 0\n",
        ]
        for (name, source) in fakes {
            let file = bin.appending(path: name)
            try source.write(to: file, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        let script = Process()
        script.executableURL = URL(filePath: "/bin/bash")
        script.arguments = [
            URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/test").standardized.path,
            "--scratch-path", folder.appending(path: "scratch").path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        // Its own temporary folder: scripts/test deletes the hand-off log of the run around this test otherwise.
        environment["TMPDIR"] = folder.path + "/"
        environment["LITHIUM_TEST_MINUTES"] = "1"
        environment["LITHIUM_FAKE_PIDS"] = pids.path
        script.environment = environment
        script.standardInput = FileHandle.nullDevice
        script.standardOutput = FileHandle.nullDevice
        script.standardError = FileHandle.nullDevice
        try script.run()
        defer { if script.isRunning { kill(script.processIdentifier, SIGKILL) } }

        var started: [pid_t] = []
        for _ in 0..<200 where started.isEmpty {
            started = ((try? String(contentsOf: pids, encoding: .utf8)) ?? "").split(separator: " ").compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if started.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        }
        try #require(started.count == 2, "the fake test run started")
        defer { started.forEach { kill($0, SIGKILL) } }
        // Leaves the script time to set its traps after starting the run.
        try await Task.sleep(for: .milliseconds(500))

        script.terminate()
        for _ in 0..<200 where script.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        try #require(!script.isRunning, "scripts/test returned")
        #expect(script.terminationStatus == 128 + SIGTERM)

        // Gone, not left behind: kill(pid, 0) fails once a process is gone.
        var alive = started
        for _ in 0..<40 where !alive.isEmpty {
            alive = alive.filter { kill($0, 0) == 0 }
            if !alive.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(alive.isEmpty, "test run and helper stopped")
    }
}
