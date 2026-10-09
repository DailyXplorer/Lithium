import Foundation

// lithium-mcp: the stdio bridge to Lithium's agent server. It reads the token from the endpoint
// file on each connect, so no client config holds it. The LITHIUM_MCP_* variables are for tests.

let environment = ProcessInfo.processInfo.environment
let endpointFile = environment["LITHIUM_MCP_ENDPOINT"].map { URL(filePath: $0) }
    ?? URL.applicationSupportDirectory.appending(path: "Lithium/Agent/endpoint.json")
let launcher = Launcher.standard(program: URL(filePath: environment["LITHIUM_MCP_OPEN"] ?? "/usr/bin/open"))
let bridge = Bridge(file: endpointFile, launcher: launcher, lithium: environment["LITHIUM_MCP_APP"])

// Clients usually stop the bridge with a signal; end the session so Lithium doesn't wait out its idle timeout.
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

// Split on "\n" alone: JSON may hold U+2028 unescaped, which `lines` would also split on.
// A discarding group frees each task as it ends; a plain one would keep them all until exit.
await withDiscardingTaskGroup { group in
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
