import Foundation
import Observation
import WebKit

enum FrameTarget {
    case main
    case child(WKFrameInfo)

    var info: WKFrameInfo? {
        if case .child(let info) = self { info } else { nil }
    }
}

/// Talks to `agent.js` in a tab's frames, in the `lithium-agent` content world. The script goes
/// into a frame the first time an agent reads it; later calls send only the operation.
@MainActor
enum PageProbe {
    static let world = WKContentWorld.world(name: "lithium-agent")
    static let messageName = "lithiumAgent"

    private static func script(_ name: String) -> String {
        Resources.bundle.url(forResource: name, withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    private static let source = script("agent")
    /// About 1 KB, in every frame of every tab while agent access is on.
    static let bootstrap = WKUserScript(source: script("agent-bootstrap"), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)

    private static let call = """
        const agent = globalThis.lithiumAgent;
        return agent ? await agent.run(operation, args) : null;
        """

    struct Failure: Error {}

    private struct FrameKey: Hashable {
        let webView: ObjectIdentifier
        let frame: ObjectIdentifier?
    }

    /// The calls waiting for the install going on in each frame.
    private static var installing: [FrameKey: [CheckedContinuation<Void, Never>]] = [:]
    private(set) static var installs = 0

    /// Throws when the frame is gone or the script failed. A call that finds no `agent.js` while
    /// another call installs it waits for that install.
    static func run(_ operation: String, _ arguments: [String: Any], in target: FrameTarget, of webView: WKWebView) async throws -> Data {
        let parameters: [String: Any] = ["operation": operation, "args": arguments]
        let key = FrameKey(webView: ObjectIdentifier(webView), frame: target.info.map(ObjectIdentifier.init))
        var answer = try await webView.callAsyncJavaScript(call, arguments: parameters, in: target.info, contentWorld: world)
        if answer == nil || answer is NSNull {
            if installing[key] != nil {
                await withCheckedContinuation { waiter in
                    if installing[key] != nil { installing[key]?.append(waiter) } else { waiter.resume() }
                }
            } else {
                // Only the install, which answers at once: an operation can wait in the page for
                // long, and one in a document that went away never answers.
                installing[key] = []
                installs += 1
                defer { installing.removeValue(forKey: key)?.forEach { $0.resume() } }
                _ = try await webView.callAsyncJavaScript(source, in: target.info, contentWorld: world)
            }
            answer = try await webView.callAsyncJavaScript(call, arguments: parameters, in: target.info, contentWorld: world)
        }
        guard let json = answer as? String else { throw Failure() }
        return Data(json.utf8)
    }

    /// `JSONDecoder` refuses a whole document for one lone surrogate escape, which a page can write
    /// on purpose: a refused answer is retried with each replaced by U+FFFD.
    nonisolated static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            guard let repaired = replacingLoneSurrogates(in: data) else { throw error }
            return try JSONDecoder().decode(type, from: repaired)
        }
    }

    /// Nil when there is no lone surrogate. Read escape by escape, so an escaped backslash before
    /// "ud83d" is left alone.
    nonisolated static func replacingLoneSurrogates(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        func unit(at index: Int) -> UInt16? {
            guard index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { return nil }
            return UInt16(String(decoding: bytes[index + 2 ..< index + 6], as: UTF8.self), radix: 16)
        }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var changed = false
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "\\") else {
                output.append(bytes[index])
                index += 1
                continue
            }
            var length = min(2, bytes.count - index)
            if let first = unit(at: index) {
                length = 6
                if (0xD800...0xDBFF).contains(first), let second = unit(at: index + 6), (0xDC00...0xDFFF).contains(second) {
                    length = 12
                } else if (0xD800...0xDFFF).contains(first) {
                    output.append(contentsOf: Array(#"�"#.utf8))
                    changed = true
                    index += length
                    continue
                }
            }
            output.append(contentsOf: bytes[index ..< index + length])
            index += length
        }
        return changed ? Data(output) : nil
    }
}

/// Receives each frame's hello from the bootstrap and files it with the tab's `AgentTab`.
@MainActor
final class AgentFrameHandler: NSObject, WKScriptMessageHandler {
    weak var hub: AgentHub?
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()

    init(hub: AgentHub) {
        self.hub = hub
    }

    /// A handler from a hub that has gone (access off, then on) is replaced.
    func install(on controller: WKUserContentController) {
        if !controllers.contains(controller) {
            controller.removeScriptMessageHandler(forName: PageProbe.messageName, contentWorld: PageProbe.world)
            controller.add(self, contentWorld: PageProbe.world, name: PageProbe.messageName)
            controllers.add(controller)
        }
        controller.addUserScript(PageProbe.bootstrap)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let tab = (message.webView as? PageWebView)?.tab, let hub, hub.isOpen(tab),
              message.frameInfo.securityOrigin.protocol != Extensions.scheme else { return }
        if let error = body["console"] as? [String: Any] {
            // The page can fire error events at any rate, and this world's listener hears them all.
            guard message.frameInfo.securityOrigin.protocol != Internal.scheme, let capture = hub.tabs[tab.id]?.capture, capture.admitsMessage() else { return }
            capture.log(
                level: "error", kind: error["kind"] as? String, text: error["text"] as? String ?? "", source: error["source"] as? String,
                line: error["line"] as? Int, column: error["column"] as? Int, frameID: ResourceLoadSpy.frameID(of: message.frameInfo)
            )
        } else if let token = body["token"] as? String {
            hub.agentTab(for: tab)?.hello(token: token, frame: message.frameInfo, restored: body["restored"] as? Bool == true)
        }
    }
}

/// Observed, so a wait on it ends as the answer comes.
@MainActor
@Observable
final class PageAnswer<Value> {
    var result: Result<Value, any Error>?
}
