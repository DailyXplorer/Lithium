import FilterEngine
import Foundation

/// Rules WebKit's content blocker cannot express, found by AdGuard's engine and injected as one
/// script at document start. Scriptlets from uBO's lists run uBO's own code (`UBOScriptlets`).
@MainActor
final class AdvancedBlocking {
    private var engine: WebExtension?
    private let container: URL
    /// Read by the first `load`, off the main thread (0.7 MB of JSON): only an open engine needs it.
    private var library: Library?

    /// For tests.
    var hasReadLibrary: Bool { library != nil }
    /// Part of each engine's folder name: bump it when the rules given to the engine change
    /// (`UBOScriptlets.adguardRules`), or the engine built before keeps the old ones until the next filter set.
    static let conversion = 1

    init(container: URL = URL.applicationSupportDirectory.appending(path: "Lithium/AdvancedEngine")) {
        self.container = container
    }

    /// Each build gets its own directory, renamed into place once complete: AdGuard's engine holds
    /// a file lock while it builds, which would make pages opened meanwhile wait on the main thread.
    /// False when the engine can't be built: the one loaded before stays.
    @discardableResult
    func load(folder: URL, stamp filterStamp: String) async -> Bool {
        let library: Library
        if let read = self.library {
            library = read
        } else {
            library = await Task.detached(priority: .userInitiated) { Library.read() }.value
            self.library = library
        }
        let ubo = library.ubo
        let stamp = "\(filterStamp)-ubo-\(ubo?.version ?? "none")-c\(Self.conversion)"
        let directory = container.appending(path: stamp)
        if !FileManager.default.fileExists(atPath: directory.path) {
            let staging = container.appending(path: ".building-\(UUID().uuidString)")
            let built = await Task.detached(priority: .utility) {
                guard var rules = try? String(contentsOf: folder.appending(path: "advanced.txt"), encoding: .utf8),
                      let builder = try? WebExtension(containerURL: staging) else { return false }
                if let ubo, let filters = try? String(contentsOf: folder.appending(path: "scriptlets.txt"), encoding: .utf8) {
                    let lines = filters.split(whereSeparator: \.isNewline).map(String.init)
                    rules += "\n" + ubo.adguardRules(fromUBO: lines).joined(separator: "\n")
                }
                guard (try? builder.buildFilterEngine(rules: rules)) != nil,
                      (try? FileManager.default.moveItem(at: staging, to: directory)) != nil else {
                    try? FileManager.default.removeItem(at: staging)
                    return false
                }
                return true
            }.value
            guard built else { return false }
        }
        // Off the main thread, which this runs at every launch. Opening only makes the folder: the
        // engine is read by its first lookup, made here so the first page doesn't wait for it.
        // The old engines go once the new one has replaced them, as pages may be looking theirs up meanwhile.
        engine = await Task.detached(priority: .userInitiated) {
            let engine = try? WebExtension(containerURL: directory)
            _ = engine?.lookup(pageUrl: URL(string: "https://example.com/")!, topUrl: nil)
            return OpenedEngine(engine: engine)
        }.value.engine
        let container = container
        await Task.detached(priority: .userInitiated) {
            let others = (try? FileManager.default.contentsOfDirectory(at: container, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for other in others where other.lastPathComponent != stamp {
                // Another load's build stays; only one a crash left behind, untouched for a day, goes.
                if other.lastPathComponent.hasPrefix(".building-"),
                   let modified = try? other.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(modified) < 24 * 60 * 60 { continue }
                try? FileManager.default.removeItem(at: other)
            }
        }.value
        return true
    }

    /// No rules until the next `load`: the engine loaded may hold a list the user turned off.
    func unload() {
        engine = nil
    }

    /// Given `page`, the script is for a frame showing `url`, and runs only in frames of that host.
    func script(for url: URL, inFrameOf page: URL? = nil) -> String? {
        guard ["http", "https"].contains(url.scheme), page.map({ ["http", "https"].contains($0.scheme) }) ?? true,
              let library, let configuration = engine?.lookup(pageUrl: url, topUrl: page) else { return nil }

        let (scriptlets, extendedCss, ubo) = (library.scriptlets, library.extendedCss, library.ubo)
        var parts: [String] = []
        let isUBO = { [ubo] (scriptlet: WebExtension.Scriptlet) in
            scriptlet.name.hasPrefix(UBOScriptlets.prefix) && ubo?.resourceName(scriptlet.name) != nil
        }
        if let script = ubo?.script(for: configuration.scriptlets.filter(isUBO).map { ($0.name, $0.args) }) { parts.append(script) }
        for scriptlet in configuration.scriptlets where !isUBO(scriptlet) {
            guard let function = scriptlets[scriptlet.name] else { continue }
            let source = ["name": scriptlet.name, "engine": "corelibs", "version": "2.3.1"]
            parts.append("try { (\(function))(\(json(source)), \(json(scriptlet.args))); } catch (e) {}")
        }
        parts += configuration.js.map { "try { \($0) } catch (e) {}" }

        let css = Self.cssRules(configuration.css)
        if !css.isEmpty {
            parts.append("injectStyle(\(json(css.joined(separator: "\n"))));")
        }
        let extended = Self.cssRules(configuration.extendedCss)
        if !extended.isEmpty, !extendedCss.isEmpty {
            parts.append("""
                try {
                  \(extendedCss)
                  new ExtendedCss({ cssRules: \(json(extended)) }).apply();
                } catch (e) {}
                """)
        }
        guard !parts.isEmpty else { return nil }

        let script = """
            (() => {
              const injectStyle = (text) => {
                const style = document.createElement('style');
                style.textContent = text;
                const attach = () => (document.head || document.documentElement).appendChild(style);
                if (document.documentElement) { attach(); return; }
                new MutationObserver((_, observer) => {
                  if (document.documentElement) { observer.disconnect(); attach(); }
                }).observe(document, { childList: true });
              };
              \(parts.joined(separator: "\n"))
            })();
            """
        guard page != nil else { return script }
        return "if (window !== window.top && location.hostname === \(json(url.host()?.lowercased() ?? ""))) {\n\(script)\n}"
    }

    private static func cssRules(_ rules: [String]) -> [String] {
        rules.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix("}") ? $0 : "\($0) { display: none !important; }" }
    }

    private func json<T: Encodable>(_ value: T) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "null"
    }
}

/// An engine opened off the main thread, handed to the main actor: only it uses the engine after.
private struct OpenedEngine: @unchecked Sendable {
    let engine: WebExtension?
}

/// AdGuard's scriptlets by name, the extended CSS script and uBO's scriptlets, from the app's resources.
private struct Library: Sendable {
    let scriptlets: [String: String]
    let extendedCss: String
    let ubo: UBOScriptlets?

    static func read() -> Library {
        let scripts = Resources.bundle
        let library = scripts.url(forResource: "scriptlets.corelibs", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(ScriptletLibrary.self, from: $0) }
        var byName: [String: String] = [:]
        for entry in library?.scriptlets ?? [] {
            entry.names.forEach { byName[$0] = entry.scriptlet }
        }
        let extendedCss = scripts.url(forResource: "extended-css.min", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return Library(scriptlets: byName, extendedCss: extendedCss, ubo: UBOScriptlets.bundled)
    }
}

private struct ScriptletLibrary: Decodable {
    struct Entry: Decodable {
        let names: [String]
        let scriptlet: String
    }
    let scriptlets: [Entry]
}
