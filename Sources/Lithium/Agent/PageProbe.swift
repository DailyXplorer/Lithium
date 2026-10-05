import Foundation
import Observation
import WebKit

/// Where a call to `agent.js` runs: the main frame, or a child frame that said hello.
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
    private static let install = source + "\nreturn await globalThis.lithiumAgent.run(operation, args);"

    struct Failure: Error {}

    /// The JSON `agent.js` answered with. Throws when the frame is gone or the script failed.
    static func run(_ operation: String, _ arguments: [String: Any], in target: FrameTarget, of webView: WKWebView) async throws -> Data {
        let parameters: [String: Any] = ["operation": operation, "args": arguments]
        var answer = try await webView.callAsyncJavaScript(call, arguments: parameters, in: target.info, contentWorld: world)
        if answer == nil || answer is NSNull {
            answer = try await webView.callAsyncJavaScript(install, arguments: parameters, in: target.info, contentWorld: world)
        }
        guard let json = answer as? String else { throw Failure() }
        return Data(json.utf8)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
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

    /// Adds the bootstrap to a page's scripts, which `Tab.applyProtections` sets on every
    /// main-frame navigation. A handler from a hub that has gone (access off, then on) is replaced.
    func install(on controller: WKUserContentController) {
        if !controllers.contains(controller) {
            controller.removeScriptMessageHandler(forName: PageProbe.messageName, contentWorld: PageProbe.world)
            controller.add(self, contentWorld: PageProbe.world, name: PageProbe.messageName)
            controllers.add(controller)
        }
        controller.addUserScript(PageProbe.bootstrap)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let token = (message.body as? [String: Any])?["token"] as? String,
              let tab = (message.webView as? PageWebView)?.tab, let hub, hub.isOpen(tab),
              message.frameInfo.securityOrigin.protocol != Extensions.scheme else { return }
        hub.agentTab(for: tab)?.hello(token: token, frame: message.frameInfo)
    }
}

/// An answer still to come from a page, observed, so a wait on it ends as it comes.
@MainActor
@Observable
final class PageAnswer<Value> {
    var result: Result<Value, any Error>?
}
