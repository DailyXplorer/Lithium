import Foundation

// lithium-mcp: the stdio door to Lithium's agent server, for MCP clients that start a command
// (`claude mcp add lithium -- /Applications/Lithium.app/Contents/MacOS/lithium-mcp`). It reads
// the token from Lithium's endpoint file each time it connects, so no client config holds it.
//
// LITHIUM_MCP_ENDPOINT names another endpoint file and LITHIUM_MCP_OPEN another program in
// place of /usr/bin/open: the tests use both, so they never touch the real file or start an app.

let environment = ProcessInfo.processInfo.environment
let endpointFile = environment["LITHIUM_MCP_ENDPOINT"].map { URL(filePath: $0) }
    ?? URL.applicationSupportDirectory.appending(path: "Lithium/Agent/endpoint.json")
let launcher = Launcher.standard(program: URL(filePath: environment["LITHIUM_MCP_OPEN"] ?? "/usr/bin/open"))
let bridge = Bridge(file: endpointFile, launcher: launcher)

// A client that quits stops the bridge with a signal more often than by closing stdin; the
// session still ends in Lithium, rather than showing as connected until its idle timeout.
signal(SIGPIPE, SIG_IGN)
let signalSources = [SIGTERM, SIGINT, SIGHUP].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        Task {
            await bridge.end()
            exit(0)
        }
    }
    source.resume()
    return source
}

// Lines split on "\n" alone: JSON may hold U+2028 unescaped, which `lines` would also split on.
// Each message runs on its own, so a long call doesn't hold up the next.
await withTaskGroup(of: Void.self) { group in
    var line = Data()
    do {
        for try await byte in FileHandle.standardInput.bytes {
            guard byte == 0x0A else {
                line.append(byte)
                continue
            }
            if line.last == 0x0D { line.removeLast() }
            if line.contains(where: { ![0x20, 0x09].contains($0) }) {
                let message = line
                group.addTask { await bridge.handle(message) }
            }
            line.removeAll(keepingCapacity: true)
        }
    } catch {
        log("Couldn’t read stdin: \(error.localizedDescription)")
    }
    if line.contains(where: { ![0x20, 0x09, 0x0D].contains($0) }) {
        let message = line
        group.addTask { await bridge.handle(message) }
    }
}
await bridge.end()
withExtendedLifetime(signalSources) {}
