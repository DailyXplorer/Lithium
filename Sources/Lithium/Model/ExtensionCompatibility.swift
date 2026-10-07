import Foundation

/// Runs `extension-compat.js` before an extension's background, which adds the Chrome APIs
/// WebKit lacks and Chrome Web Store builds use as soon as they start. WebKit has no way to run
/// a script in an extension's background, so its service worker becomes a small one that loads
/// the script, then the extension's own. Only a service worker background: none other has been
/// seen to need it.
enum ExtensionCompatibility {
    static let script = "lithium-compat.js"
    static let worker = "lithium-background.js"

    private static let source = Resources.bundle.url(forResource: "extension-compat", withExtension: "js")
        .flatMap { try? Data(contentsOf: $0) } ?? Data()

    struct OutsideFolder: Error {}

    /// Prepares the unpacked extension in `folder`. Repeating it changes nothing, except the script
    /// when Lithium's is newer.
    static func apply(to folder: URL) throws {
        let file = folder.appending(path: "manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: file), options: .json5Allowed) as? [String: Any],
              var background = manifest["background"] as? [String: Any],
              let original = background["service_worker"] as? String else { return }
        let directory = (original as NSString).deletingLastPathComponent
        let name = (original as NSString).lastPathComponent
        // The path comes from the package: `..` or a link must not have Lithium write elsewhere on the Mac.
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appending(path: directory).standardizedFileURL.resolvingSymlinksInPath()
        guard target.pathComponents.starts(with: base.pathComponents) else { throw OutsideFolder() }

        let script = folder.appending(path: Self.script)
        if (try? Data(contentsOf: script)) != source { try source.write(to: script, options: .atomic) }
        guard name != worker else { return }
        // Next to the extension's own, so the paths it loads relative to itself still lead to the same
        // files. The names are written as JSON strings: a quote in one can't add code.
        let load = background["type"] as? String == "module"
            ? "import \"/\(Self.script)\";\nimport \(try jsonString("./\(name)"));\n"
            : "importScripts(\"/\(Self.script)\", \(try jsonString(name)));\n"
        try Data(load.utf8).write(to: target.appending(path: worker), options: .atomic)
        background["service_worker"] = (directory as NSString).appendingPathComponent(worker)
        manifest["background"] = background
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]).write(to: file, options: .atomic)
    }

    private static func jsonString(_ string: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
