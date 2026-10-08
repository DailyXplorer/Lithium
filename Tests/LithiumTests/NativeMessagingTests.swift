import Foundation
import Testing
import WebKit
@testable import Lithium

/// Password managers reach their Mac app through native messaging (`NativeMessaging`). The hosts
/// here are shell scripts that log what they get and echo it back, from a throwaway folder.
@MainActor
struct NativeMessagingTests {
    private let id = "bbccddeeffgghhiijjkkllmmnnooppaa"

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "native-hosts-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Registers host `name` in `folder`, for the extensions in `allowed`: it logs the origin it
    /// was started for, then every message it gets, which it also sends back.
    @discardableResult
    private func register(_ name: String, in folder: URL, allowed: [String], log: URL) throws -> URL {
        let script = folder.appending(path: "\(name).sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$1\" >> '\(log.path)'\nexec /usr/bin/tee -a '\(log.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let manifest: [String: Any] = ["name": name, "description": "Test", "path": script.path, "type": "stdio", "allowed_origins": allowed.map(NativeMessaging.origin)]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appending(path: "\(name).json"))
        return script
    }

    private func archive(_ files: [String: String]) throws -> Data {
        let source = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID())")
        let zip = FileManager.default.temporaryDirectory.appending(path: "extension-\(UUID()).zip")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: zip)
        }
        for (path, text) in files {
            let file = source.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", source.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        return try Data(contentsOf: zip)
    }

    private func waitForLog(_ log: URL, toContain text: String) async throws -> String {
        var content = ""
        for _ in 0..<100 {
            content = String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self)
            if content.contains(text) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return content
    }

    @Test func aHostIsFoundOnlyForTheExtensionsItAllows() throws {
        let first = try folder(), second = try folder()
        defer { [first, second].forEach { try? FileManager.default.removeItem(at: $0) } }
        let log = first.appending(path: "log")
        let script = try register("com.example.app", in: first, allowed: [id], log: log)
        try register("com.example.other", in: second, allowed: ["pppppppppppppppppppppppppppppppp"], log: log)

        #expect(try NativeMessaging.executable(of: "com.example.app", for: id, in: [first, second]) == script)
        #expect(throws: NativeMessaging.HostError.forbidden) { try NativeMessaging.executable(of: "com.example.other", for: id, in: [first, second]) }
        #expect(throws: NativeMessaging.HostError.notFound) { try NativeMessaging.executable(of: "com.example.missing", for: id, in: [first, second]) }
        // A name can't lead out of the folders.
        #expect(throws: NativeMessaging.HostError.notFound) { try NativeMessaging.executable(of: "../first/com.example.app", for: id, in: [second]) }
        // The first manifest found decides, as in Chrome, even when a later one would allow it.
        try register("com.example.app", in: second, allowed: [id], log: log)
        try JSONSerialization.data(withJSONObject: ["name": "com.example.app", "type": "stdio", "path": "relative/host", "allowed_origins": [NativeMessaging.origin(of: id)]])
            .write(to: first.appending(path: "com.example.app.json"))
        #expect(throws: NativeMessaging.HostError.notFound) { try NativeMessaging.executable(of: "com.example.app", for: id, in: [first, second]) }
    }

    @Test func messagesAreReadWhateverPiecesTheyArriveIn() throws {
        let data = try NativeMessaging.frame(["a": 1]) + NativeMessaging.frame("two") + NativeMessaging.frame([3])
        var reader = NativeMessaging.Reader()
        var messages: [Any] = []
        for byte in data { messages += try reader.read(Data([byte])) }
        #expect(messages.count == 3)
        #expect((messages[0] as? [String: Int]) == ["a": 1])
        #expect(messages[1] as? String == "two")
        #expect((messages[2] as? [Int]) == [3])

        // Chrome takes no more than 1 MB in one message from a host.
        var tooLong = UInt32(NativeMessaging.Reader.limit + 1)
        var oversize = NativeMessaging.Reader()
        #expect(throws: NativeMessaging.HostError.failed) { try oversize.read(Data(bytes: &tooLong, count: 4)) }
    }

    /// A host whose handler holds it, as `sendNativeMessage`'s does, is freed once it ends: kept,
    /// each call left its pipes open until Lithium ran out of descriptors.
    @Test(.timeLimit(.minutes(1))) func anEndedHostIsFreed() async throws {
        let hosts = try folder()
        defer { try? FileManager.default.removeItem(at: hosts) }
        try register("com.example.echo", in: hosts, allowed: [id], log: hosts.appending(path: "log"))
        weak var freed: NativeMessaging.Host?
        var reply: Any?
        do {
            var host: NativeMessaging.Host? = NativeMessaging.Host(executable: try NativeMessaging.executable(of: "com.example.echo", for: id, in: [hosts]), extensionID: id)
            host?.onMessage = { message in
                reply = message
                host?.stop()
            }
            try host?.start()
            try host?.send(["step": "send"])
            freed = host
        }
        for _ in 0..<50 where reply == nil || freed != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect((reply as? [String: String]) == ["step": "send"])
        #expect(freed == nil)
    }

    /// One message with its reply (`sendNativeMessage`), then a port (`connectNative`) that stays
    /// open until the extension is turned off. A host that doesn't list it is refused.
    @Test(.timeLimit(.minutes(1))) func anExtensionTalksToTheHostsThatAllowIt() async throws {
        let hosts = try folder()
        let folder = FileManager.default.temporaryDirectory.appending(path: "extensions-\(UUID())")
        defer { [hosts, folder].forEach { try? FileManager.default.removeItem(at: $0) } }
        let log = hosts.appending(path: "log")
        try register("com.example.echo", in: hosts, allowed: [id], log: log)
        try register("com.example.forbidden", in: hosts, allowed: ["pppppppppppppppppppppppppppppppp"], log: log)
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        extensions.nativeHostFolders = [hosts]

        try await extensions.install(archive: try archive([
            "manifest.json": #"""
                {"manifest_version": 3, "name": "Native", "version": "1.0", "permissions": ["nativeMessaging"],
                 "background": {"service_worker": "background.js"}}
                """#,
            "background.js": """
                const refused = chrome.runtime.sendNativeMessage('com.example.forbidden', { step: 'forbidden' }).then(() => 'sent', (error) => error.message);
                Promise.all([refused, chrome.runtime.sendNativeMessage('com.example.echo', { step: 'send' })]).then(([refused, reply]) => {
                    const port = chrome.runtime.connectNative('com.example.echo');
                    port.onMessage.addListener((message) => {
                        if (message.step === 'echo') port.postMessage({ step: 'done', reply: reply.step, refused });
                    });
                    port.postMessage({ step: 'echo' });
                });
                """,
        ]), id: id)

        let content = try await waitForLog(log, toContain: #""step":"done""#)
        #expect(content.contains(NativeMessaging.origin(of: id)))
        #expect(content.contains(#"{"step":"send"}"#))
        #expect(content.contains(#""reply":"send""#))
        #expect(content.contains("forbidden."), "refused: \(content)")
        #expect(!content.contains(#"{"step":"forbidden"}"#))
        // The one-message host has ended; the port's runs until the extension is turned off.
        for _ in 0..<50 where extensions.nativeHosts[id]?.count != 1 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(extensions.nativeHosts[id]?.count == 1)
        await extensions.setEnabled(false, id: id)
        #expect(extensions.nativeHosts[id] == nil)
    }

    /// Password managers turn the browser's password saving off, watch for the Mac idling and look
    /// themselves up as they start, with APIs WebKit lacks (`extension-compat.js`).
    @Test(.timeLimit(.minutes(1))) func aBackgroundFindsTheAPIsPasswordManagersStartWith() async throws {
        let id = "ccddeeffgghhiijjkkllmmnnooppaabb"
        let hosts = try folder()
        let folder = FileManager.default.temporaryDirectory.appending(path: "extensions-\(UUID())")
        defer { [hosts, folder].forEach { try? FileManager.default.removeItem(at: $0) } }
        let log = hosts.appending(path: "log")
        try register("com.example.echo", in: hosts, allowed: [id], log: log)
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        extensions.nativeHostFolders = [hosts]
        extensions.isScreenLocked = { false }

        try await extensions.install(archive: try archive([
            "manifest.json": #"""
                {"manifest_version": 3, "name": "Shims", "version": "1.0", "permissions": ["nativeMessaging", "privacy", "idle", "management"],
                 "background": {"service_worker": "background.js"}}
                """#,
            "background.js": """
                chrome.idle.onStateChanged.addListener(() => {});
                chrome.idle.setDetectionInterval(60);
                chrome.runtime.setUninstallURL('https://example.com/');
                const saving = chrome.privacy.services.passwordSavingEnabled;
                Promise.all([saving.set({ value: false }).then(() => saving.get({})), chrome.idle.queryState(60), chrome.management.getSelf()])
                    .then(([saving, idle, self]) => ({ saving: saving.value, idle, name: self.name }), (error) => ({ error: error.message }))
                    .then((result) => chrome.runtime.sendNativeMessage('com.example.echo', result));
                """,
        ]), id: id)
        defer { Task { await extensions.remove(id: id) } }

        let content = try await waitForLog(log, toContain: "{\"")
        #expect(content.contains(#"{"idle":"active","name":"Shims","saving":false}"#), "got: \(content)")
    }

    /// `chrome.idle` reports the Mac's screen locking and unlocking, which password managers lock
    /// on: always `active`, a vault set to lock with the screen stayed open.
    @Test(.timeLimit(.minutes(1))) func idleTellsAnExtensionTheScreenLocked() async throws {
        let id = "ddeeffgghhiijjkkllmmnnooppaabbcc"
        let hosts = try folder()
        let folder = FileManager.default.temporaryDirectory.appending(path: "extensions-\(UUID())")
        defer { [hosts, folder].forEach { try? FileManager.default.removeItem(at: $0) } }
        let log = hosts.appending(path: "log")
        try register("com.example.echo", in: hosts, allowed: [id], log: log)
        let extensions = Extensions(folder: folder, configuration: .nonPersistent())
        extensions.nativeHostFolders = [hosts]
        extensions.isScreenLocked = { true }

        try await extensions.install(archive: try archive([
            "manifest.json": #"""
                {"manifest_version": 3, "name": "Idle", "version": "1.0", "permissions": ["nativeMessaging", "idle"],
                 "background": {"service_worker": "background.js"}}
                """#,
            "background.js": """
                chrome.idle.onStateChanged.addListener((state) => chrome.runtime.sendNativeMessage('com.example.echo', { changed: state }));
                chrome.idle.queryState(60).then((state) => chrome.runtime.sendNativeMessage('com.example.echo', { queried: state }));
                """,
        ]), id: id)

        var content = try await waitForLog(log, toContain: #"{"queried":"locked"}"#)
        #expect(content.contains(#"{"queried":"locked"}"#), "got: \(content)")
        #expect(extensions.idlePorts[id]?.count == 1)
        extensions.screenLockChanged(locked: false)
        content = try await waitForLog(log, toContain: #"{"changed":"active"}"#)
        #expect(content.contains(#"{"changed":"locked"}"#), "got: \(content)")
        #expect(content.contains(#"{"changed":"active"}"#), "got: \(content)")

        await extensions.setEnabled(false, id: id)
        #expect(extensions.idlePorts[id] == nil)
    }
}
