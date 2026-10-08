import Foundation

/// Chrome's native messaging (`runtime.connectNative`, `runtime.sendNativeMessage`), which password
/// managers use to reach their Mac app: 1Password and Bitwarden unlock through it, and with nothing
/// answering, 1Password's extension stayed locked and couldn't save logins. WebKit hands these
/// calls to the browser (`Extensions`); as Chrome does, Lithium runs the host an app registered (a
/// JSON manifest naming its executable and the extensions allowed to use it) and exchanges JSON
/// messages with it over its standard input and output. Nothing runs until an extension asks.
enum NativeMessaging {
    /// Where apps register hosts: Lithium's own folder, then Chrome's and other Chromium browsers',
    /// where password managers write theirs.
    static let folders: [URL] = {
        let support = URL.applicationSupportDirectory
        return ["Lithium", "Google/Chrome", "Chromium", "Microsoft Edge", "BraveSoftware/Brave-Browser"]
            .map { support.appending(path: "\($0)/NativeMessagingHosts", directoryHint: .isDirectory) }
            + [URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts", isDirectory: true)]
    }()

    /// Chrome's own messages, which extensions may look for.
    enum HostError: LocalizedError {
        case notFound, forbidden, exited, failed

        var errorDescription: String? {
            switch self {
            case .notFound: "Specified native messaging host not found."
            case .forbidden: "Access to the specified native messaging host is forbidden."
            case .exited: "Native host has exited."
            case .failed: "Error when communicating with the native messaging host."
            }
        }
    }

    /// The executable of host `name` that extension `id` may run. The first manifest found decides,
    /// as in Chrome, and it must list the extension.
    static func executable(of name: String, for id: String, in folders: [URL] = folders) throws -> URL {
        // Chrome's rule for names, which also keeps one from leading out of the folders.
        guard name.range(of: #"^([a-z0-9_]+\.)*[a-z0-9_]+$"#, options: .regularExpression) != nil else { throw HostError.notFound }
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appending(path: "\(name).json")) else { continue }
            guard let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  manifest["name"] as? String == name, manifest["type"] as? String == "stdio",
                  let path = manifest["path"] as? String, path.hasPrefix("/") else { throw HostError.notFound }
            guard (manifest["allowed_origins"] as? [String] ?? []).contains(origin(of: id)) else { throw HostError.forbidden }
            return URL(fileURLWithPath: path)
        }
        throw HostError.notFound
    }

    /// Lithium's extension ids are their Chrome Web Store ids, so hosts know them by Chrome's origin.
    static func origin(of id: String) -> String {
        "chrome-extension://\(id)/"
    }

    /// A message: its length in four bytes of the Mac's byte order, then its JSON.
    static func frame(_ message: Any) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        guard var length = UInt32(exactly: json.count) else { throw HostError.failed }
        return Data(bytes: &length, count: 4) + json
    }

    /// Takes a host's messages out of its output as it comes, in pieces of any size.
    struct Reader {
        /// Chrome takes no more from a host in one message.
        static let limit = 1024 * 1024
        private var buffer = Data()

        mutating func read(_ data: Data) throws -> [Any] {
            buffer.append(data)
            var messages: [Any] = []
            while buffer.count >= 4 {
                let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                guard length <= Self.limit else { throw HostError.failed }
                guard buffer.count >= 4 + length else { break }
                messages.append(try JSONSerialization.jsonObject(with: Data(buffer.dropFirst(4).prefix(length)), options: .fragmentsAllowed))
                buffer = Data(buffer.dropFirst(4 + length))
            }
            return messages
        }
    }

    /// A running host. It is told who started it by the extension's origin, as Chrome tells it, and
    /// stops when the extension disconnects, is turned off, or Lithium quits (its input closes).
    @MainActor
    final class Host {
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        /// Writing waits while the host is busy reading, so it is done off the main thread, in order.
        private let writer = DispatchQueue(label: "Lithium.NativeMessaging")
        private var reader = Reader()
        private var isDone = false
        var onMessage: (Any) -> Void = { _ in }
        /// Called once when the host ends, whichever side ends it: a call waiting on it then fails.
        var onExit: (HostError) -> Void = { _ in }

        init(executable: URL, extensionID: String) {
            process.executableURL = executable
            process.arguments = [NativeMessaging.origin(of: extensionID)]
            process.currentDirectoryURL = executable.deletingLastPathComponent()
            process.standardInput = input
            process.standardOutput = output
        }

        func start() throws {
            // A host that exits while a message is on its way would otherwise end Lithium with SIGPIPE.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                // At the end of its output, which would otherwise call this again and again.
                if data.isEmpty { handle.readabilityHandler = nil }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data) } }
            }
            do {
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                throw HostError.notFound
            }
        }

        func send(_ message: Any) throws {
            let data = try NativeMessaging.frame(message)
            let handle = input.fileHandleForWriting
            writer.async { try? handle.write(contentsOf: data) }
        }

        func stop() {
            end(.exited)
        }

        private func received(_ data: Data) {
            guard !isDone else { return }
            guard !data.isEmpty else { return end(.exited) }
            do {
                for message in try reader.read(data) where !isDone { onMessage(message) }
            } catch {
                end(.failed)
            }
        }

        private func end(_ error: HostError) {
            guard !isDone else { return }
            isDone = true
            output.fileHandleForReading.readabilityHandler = nil
            let handle = input.fileHandleForWriting
            writer.async { try? handle.close() }
            if process.isRunning { process.terminate() }
            onExit(error)
            // A caller's handler may hold the host (`sendNativeMessage` stops it from its reply): let
            // go, or the host, its process and its pipes' descriptors stay until Lithium quits.
            onMessage = { _ in }
            onExit = { _ in }
        }
    }
}
