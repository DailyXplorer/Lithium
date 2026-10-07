import FilterEngine
import Foundation

/// Rules WebKit's content blocker cannot express (uBO scriptlets, procedural cosmetics, CSS
/// injection). AdGuard's engine finds the rules for a page; Lithium turns them into one script
/// injected at document start, before any page code runs. Scriptlets from uBO's lists run
/// uBO's own code (`UBOScriptlets`); the rest run AdGuard's.
@MainActor
final class AdvancedBlocking {
    private var engine: WebExtension?
    private let container: URL
    private let scriptlets: [String: String]
    private let extendedCss: String
    private let ubo = UBOScriptlets.bundled

    init(container: URL = URL.applicationSupportDirectory.appending(path: "Lithium/AdvancedEngine")) {
        self.container = container
        let scripts = Resources.bundle
        let library = scripts.url(forResource: "scriptlets.corelibs", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(ScriptletLibrary.self, from: $0) }
        var byName: [String: String] = [:]
        for entry in library?.scriptlets ?? [] {
            entry.names.forEach { byName[$0] = entry.scriptlet }
        }
        scriptlets = byName
        extendedCss = scripts.url(forResource: "extended-css.min", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// Builds AdGuard's index from a filter folder (`advanced.txt`, and uBO's `+js()` filters in
    /// `scriptlets.txt`) the first time that folder, or a new uBO scriptlet library, is seen.
    /// Each build gets its own directory, renamed into place once complete: AdGuard's engine
    /// holds a file lock while it builds, and an engine in use that shared it would make every
    /// page opened meanwhile wait on the main thread.
    func load(folder: URL, stamp filterStamp: String) async {
        let ubo = ubo
        let stamp = "\(filterStamp)-ubo-\(ubo?.version ?? "none")"
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
            guard built else { return }
        }
        engine = try? WebExtension(containerURL: directory)
        let others = (try? FileManager.default.contentsOfDirectory(at: container, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for other in others where other.lastPathComponent != stamp {
            // Another load's build stays; only one a crash left behind, untouched for a day, goes.
            if other.lastPathComponent.hasPrefix(".building-"),
               let modified = try? other.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(modified) < 24 * 60 * 60 { continue }
            try? FileManager.default.removeItem(at: other)
        }
    }

    /// The script for a page at `url`, or, given `page`, for a frame of that page showing `url`:
    /// looked up for the frame's own site, and only run in frames of that host, never the page itself.
    func script(for url: URL, inFrameOf page: URL? = nil) -> String? {
        guard ["http", "https"].contains(url.scheme), page.map({ ["http", "https"].contains($0.scheme) }) ?? true,
              let configuration = engine?.lookup(pageUrl: url, topUrl: page) else { return nil }

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

private struct ScriptletLibrary: Decodable {
    struct Entry: Decodable {
        let names: [String]
        let scriptlet: String
    }
    let scriptlets: [Entry]
}
