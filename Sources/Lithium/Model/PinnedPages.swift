import Foundation
import WebKit

/// Badge, notification and icon signals from a pinned tab's page via `pinned-page.js`. Only pinned
/// tabs get the script and the channel, which any script of the page could see.
@MainActor
final class PinnedPages: NSObject, WKScriptMessageHandler {
    static let name = "lithiumPinned"

    /// In the page's world, where it calls `navigator.setAppBadge` and `new Notification`.
    static let script = WKUserScript(
        source: Resources.bundle.url(forResource: "pinned-page", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "",
        injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page
    )

    enum Signal: Equatable {
        /// nil is a dot.
        case badge(Int?)
        case clearBadge
        case notification
        /// With the page's title as it named the icon: WebKit may report a new title only after
        /// this, and a count that came with the icon must be known before the icon is fetched.
        case icon(URL, title: String?)

        static let largestCount = 1_000_000
        /// A data: icon past this is no icon a page means to show.
        static let longestIcon = 512 * 1024

        /// Any script of the page can post one, so only a finite, non-negative number (not a
        /// boolean) count and a fetchable icon address get through.
        init?(message body: Any) {
            guard let body = body as? [String: Any], let type = body["type"] as? String else { return nil }
            switch type {
            case "badge":
                switch body["count"] {
                case nil, is NSNull:
                    self = .badge(nil)
                case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
                    let value = number.doubleValue
                    guard value.isFinite, value >= 0 else { return nil }
                    self = .badge(Int(min(value, Double(Self.largestCount))))
                default:
                    return nil
                }
            case "clearBadge":
                self = .clearBadge
            case "notification":
                self = .notification
            case "icon":
                guard let href = body["href"] as? String, href.utf8.count <= Self.longestIcon,
                      let url = URL(string: href), Favicons.isFetchable(url) else { return nil }
                self = .icon(url, title: body["title"] as? String)
            default:
                return nil
            }
        }
    }

    /// Each tab has its own controller, a popup too (`Privacy.harden` replaces the one WebKit
    /// copied from its opener).
    private let channels = NSHashTable<WKUserContentController>.weakObjects()

    func setChannel(_ open: Bool, on controller: WKUserContentController) {
        guard open != channels.contains(controller) else { return }
        if open {
            controller.add(self, contentWorld: .page, name: Self.name)
            channels.add(controller)
        } else {
            controller.removeScriptMessageHandler(forName: Self.name, contentWorld: .page)
            channels.remove(controller)
        }
    }

    /// Frames in the page are ignored: an ad's iframe has no say on the tab's badge.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let tab = (message.webView as? PageWebView)?.tab,
              tab.pinID != nil, !tab.isAsleep, let signal = Signal(message: message.body) else { return }
        tab.receive(signal)
    }
}
