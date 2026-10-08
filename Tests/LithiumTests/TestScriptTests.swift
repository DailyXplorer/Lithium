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

    /// A run says which tests it skipped for want of the network, model or live-site gates, so a
    /// pass isn't read as covering them.
    @Test func namesTheGatedTestsItSkipped() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "test-script-\(UUID())")
        let bin = folder.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A build and a test run that pass at once.
        let fakes = ["swift": "#!/bin/bash\nexit 0\n", "sandbox-exec": "#!/bin/bash\nshift 2\nexec \"$@\"\n", "log": "#!/bin/bash\nexit 0\n"]
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
        environment["TMPDIR"] = folder.path + "/"
        environment["LITHIUM_NETWORK_TESTS"] = nil
        environment["LITHIUM_MODEL_TESTS"] = "0"
        environment["LITHIUM_LIVE_TESTS"] = "1"
        script.environment = environment
        let output = Pipe()
        script.standardInput = FileHandle.nullDevice
        script.standardOutput = output
        script.standardError = FileHandle.nullDevice
        try script.run()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        script.waitUntilExit()

        #expect(script.terminationStatus == 0)
        #expect(printed.contains("scripts/test: skipped the tests gated by LITHIUM_NETWORK_TESTS LITHIUM_MODEL_TESTS (set to 1 to run them).\n"))
    }

    /// Each checkout builds in a folder of its own, so a run never tests another checkout's build.
    /// A link to the old shared folder is moved; one the user made stays.
    @Test func eachCheckoutBuildsInItsOwnFolder() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: "test-script-\(UUID())")
        let bin = folder.appending(path: "bin")
        let home = folder.appending(path: "home")
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        // A build that fails, so the script stops right after setting up `.build`.
        let swift = bin.appending(path: "swift")
        try "#!/bin/bash\nexit 7\n".write(to: swift, atomically: false, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        let source = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/test").standardized

        func checkout(_ name: String, linkedTo destination: String? = nil) throws -> URL {
            let checkout = folder.appending(path: name)
            try manager.createDirectory(at: checkout.appending(path: "scripts"), withIntermediateDirectories: true)
            try manager.copyItem(at: source, to: checkout.appending(path: "scripts/test"))
            if let destination { try manager.createSymbolicLink(atPath: checkout.appending(path: ".build").path, withDestinationPath: destination) }
            return checkout
        }
        func build(_ checkout: URL) throws -> String {
            let script = Process()
            script.executableURL = URL(filePath: "/bin/bash")
            script.arguments = [checkout.appending(path: "scripts/test").path]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
            environment["HOME"] = home.path
            script.environment = environment
            script.standardInput = FileHandle.nullDevice
            script.standardOutput = FileHandle.nullDevice
            script.standardError = FileHandle.nullDevice
            try script.run()
            script.waitUntilExit()
            #expect(script.terminationStatus == 7, "stopped at the build")
            return try manager.destinationOfSymbolicLink(atPath: checkout.appending(path: ".build").path)
        }

        let builds = home.appending(path: "Library/Caches/Lithium/builds").path + "/"
        let firstCheckout = try checkout("first")
        let first = try build(firstCheckout)
        let second = try build(checkout("second", linkedTo: home.appending(path: "Library/Caches/Lithium/build").path))
        #expect(first.hasPrefix(builds) && second.hasPrefix(builds))
        #expect(first != second)
        #expect(manager.fileExists(atPath: first) && manager.fileExists(atPath: second))
        #expect(try build(firstCheckout) == first, "a checkout keeps its folder")

        // A copied checkout keeps the original's link; built, it must move to a folder of its own.
        let copy = try build(checkout("copy", linkedTo: first))
        #expect(copy.hasPrefix(builds) && copy != first && copy != second)
        #expect(try build(firstCheckout) == first, "the original keeps its folder")

        let own = folder.appending(path: "own").path
        #expect(try build(checkout("custom", linkedTo: own)) == own)
    }
}
