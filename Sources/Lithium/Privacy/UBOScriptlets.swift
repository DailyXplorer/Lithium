import Foundation
import JavaScriptCore

/// uBlock Origin's own scriptlets, bundled by scripts/update-ubo-scriptlets.mjs.
/// uBO's `+js()` filters are written for these implementations and uBO's argument syntax.
/// AdGuard's look-alikes take different arguments and lack the newest ones, which are
/// precisely the ones YouTube's ads are fought with.
struct UBOScriptlets: Decodable, Sendable {
    struct Resource: Decodable, Sendable {
        let code: String
        let dependencies: [String]
        let priority: Int?
    }

    let version: String
    let argumentParser: String
    let aliases: [String: String]
    let resources: [String: Resource]

    /// The prefix marking these scriptlets in AdGuard's rule syntax, which its engine indexes by site.
    static let prefix = "ubo-"

    static let bundled: UBOScriptlets? = Resources.bundle.url(forResource: "scriptlets.ubo", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(UBOScriptlets.self, from: $0) }

    /// `set`, `set.js`, `ubo-set` and `set-constant.js` all name `set-constant.js`.
    func resourceName(_ token: String) -> String? {
        var name = token.hasPrefix(Self.prefix) ? String(token.dropFirst(Self.prefix.count)) : token
        if !name.hasSuffix(".js") { name += ".js" }
        name = aliases[name] ?? name
        return resources[name] == nil ? nil : name
    }

    /// Rewrites uBO filters (`example.com##+js(set, a.b, 1)`, `example.com#@#+js(...)`) as AdGuard
    /// scriptlet rules. Arguments are split by uBO's own parser, so quoting and escapes mean
    /// exactly what they mean in uBO.
    func adguardRules(fromUBO filters: [String]) -> [String] {
        guard let context = JSContext() else { return [] }
        context.evaluateScript(argumentParser + Self.argumentsScript)
        guard let parse = context.objectForKeyedSubscript("lithiumScriptletArguments") else { return [] }

        return filters.compactMap { filter in
            let isException = filter.contains("#@#+js(")
            guard let marker = filter.range(of: isException ? "#@#+js(" : "##+js("), filter.hasSuffix(")") else { return nil }
            let body = String(filter[marker.upperBound..<filter.index(before: filter.endIndex)])
            guard let arguments = parse.call(withArguments: [body])?.toArray() as? [String],
                  let token = arguments.first, let name = resourceName(token) else { return nil }
            let quoted = ([Self.prefix + name.dropLast(3)] + arguments.dropFirst()).map { argument in
                "\"" + argument.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
            return String(filter[..<marker.lowerBound]) + (isException ? "#@%#" : "#%#") + "//scriptlet(\(quoted.joined(separator: ", ")))"
        }
    }

    /// One private scope holding every scriptlet the page needs and their helpers, then the calls,
    /// highest priority first: the shape uBO itself injects.
    func script(for calls: [(name: String, arguments: [String])]) -> String? {
        var definitions: [String] = []
        var defined: Set<String> = []
        var invocations: [(priority: Int, code: String)] = []
        for call in calls {
            guard let name = resourceName(call.name), let resource = resources[name],
                  let function = Self.functionName(resource.code) else { continue }
            var pending = [name]
            while let next = pending.popLast() {
                guard defined.insert(next).inserted, let needed = resources[next] else { continue }
                definitions.append(needed.code)
                pending += needed.dependencies
            }
            let arguments = String(Self.json(call.arguments).dropFirst().dropLast())
            invocations.append((resource.priority ?? 0, "try { \(function)(\(arguments)); } catch (e) {}"))
        }
        guard !invocations.isEmpty else { return nil }
        let ordered = invocations.enumerated()
            .sorted { $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset }
            .map(\.element.code)
        return """
            (function() {
            const scriptletGlobals = {};
            \(definitions.joined(separator: "\n"))
            \(ordered.joined(separator: "\n"))
            })();
            """
    }

    private static func functionName(_ code: String) -> String? {
        guard let match = code.firstMatch(of: /^function\s+([^(\s]+)\s*\(/) else { return nil }
        return String(match.1)
    }

    private static func json(_ value: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "[]"
    }

    /// uBO's AstFilterParser.parseExtPatternScriptletArgs, reduced to the argument values.
    private static let argumentsScript = """

        function lithiumScriptletArguments(body) {
          const parser = new ArglistParser(',');
          const first = parser.nextArg(body, 0);
          let token = body.slice(first.argBeg, first.argEnd);
          if (token.endsWith('.js')) { token = token.slice(0, -3); }
          const values = [token];
          const rest = body.slice(first.separatorEnd);
          for (let i = 0; i < rest.length;) {
            const next = parser.nextArg(rest, i);
            const value = rest.slice(next.argBeg, next.argEnd);
            values.push(next.transform ? parser.normalizeArg(value) : value);
            i = next.separatorEnd;
          }
          return values;
        }
        """
}
