import Foundation

/// The kind of sign-in field `autofill.js` reports focused.
enum PasswordField: String, Sendable {
    case username, password
    /// A sign-up or change form's: offers a strong password instead of the saved ones.
    case newPassword = "new-password"
}

/// What `autofill.js` may say, once checked. Its description leaves the password out.
enum AutofillMessage: Equatable, CustomStringConvertible {
    /// `rect` is the field's, in CSS pixels of the visual viewport `viewport` describes.
    case focus(PasswordField, rect: CGRect, viewport: PageViewport)
    case blur
    case submit(username: String, password: String)

    static let maxLength = 4096

    /// Nil for anything but the main frame of an https page (http only on this Mac) whose origin is
    /// the page's own, or a body not shaped as the script sends it.
    init?(_ body: Any, isMainFrame: Bool, scheme: String, host: String, page: URL?) {
        guard isMainFrame, Self.trusts(scheme: scheme, host: host, page: page),
              let body = body as? [String: Any], let type = body["type"] as? String else { return nil }
        switch type {
        case "focus":
            guard let field = (body["kind"] as? String).flatMap(PasswordField.init(rawValue:)),
                  let rect = body["rect"] as? [String: Any], let viewport = body["viewport"] as? [String: Any],
                  let x = Self.number(rect["x"]), let y = Self.number(rect["y"]),
                  let width = Self.number(rect["w"]), let height = Self.number(rect["h"]), width > 0, height > 0,
                  let left = Self.number(viewport["x"]), let top = Self.number(viewport["y"]),
                  let scale = Self.number(viewport["scale"]), scale > 0 else { return nil }
            self = .focus(field, rect: CGRect(x: x, y: y, width: width, height: height),
                          viewport: PageViewport(w: 0, h: 0, sx: 0, sy: 0, pw: 0, ph: 0, dpr: 1, vx: left, vy: top, vs: scale))
        case "blur":
            self = .blur
        case "submit":
            guard let username = body["username"] as? String, let password = body["password"] as? String,
                  !password.isEmpty, username.count <= Self.maxLength, password.count <= Self.maxLength else { return nil }
            self = .submit(username: username, password: password)
        default:
            return nil
        }
    }

    /// The frame is the page's own origin, over https, or http on this Mac for a local test form.
    static func trusts(scheme: String, host: String, page: URL?) -> Bool {
        guard let page, let pageHost = page.host()?.lowercased(), !pageHost.isEmpty,
              host.lowercased() == pageHost, page.scheme?.lowercased() == scheme.lowercased() else { return false }
        switch scheme.lowercased() {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1"].contains(pageHost)
        default: return false
        }
    }

    /// Finite numbers only: a JavaScript `NaN` or `Infinity` would place the list nowhere. A
    /// boolean comes as an `NSNumber` too, which `is Bool` can't tell from a 0 or a 1.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    var description: String {
        switch self {
        case let .focus(field, rect, _): "focus(\(field.rawValue), \(rect))"
        case .blur: "blur"
        case let .submit(username, _): "submit(\(username))"
        }
    }
}

/// The list under a focused sign-in field. It holds no password: a row names an account by id.
struct PasswordDropdown: Equatable {
    enum Row: Equatable, Identifiable {
        case account(Credential.ID, username: String, host: String)
        case strongPassword

        var id: String {
            switch self {
            case let .account(id, _, _): id.uuidString
            case .strongPassword: "strong"
            }
        }
    }

    let tabID: Tab.ID
    let host: String
    let field: PasswordField
    /// The field's, in the web view's points from its top left.
    let rect: CGRect
    let rows: [Row]

    static let rowHeight: CGFloat = 40
    static let padding: CGFloat = 5
    static let minWidth: CGFloat = 260

    /// A new password field gets a strong password; any other the site's accounts, its own host's first.
    static func rows(for field: PasswordField, host: String, in vault: VaultContents) -> [Row] {
        if field == .newPassword { return [.strongPassword] }
        return SiteMatch.credentials(for: host, in: vault.credentials).map { .account($0.id, username: $0.username, host: $0.host) }
    }

    /// Under the field, or over it when the page ends first; always inside the page.
    func frame(in page: CGSize) -> CGRect {
        let width = min(max(rect.width, Self.minWidth), max(page.width - 16, 0))
        let height = CGFloat(rows.count) * Self.rowHeight + Self.padding * 2
        let x = min(max(rect.minX, 8), max(page.width - width - 8, 8))
        var y = rect.maxY + 4
        if y + height > page.height - 8, rect.minY - 4 - height >= 8 { y = rect.minY - 4 - height }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// "Save password?" over a page whose sign-in form was sent. The password is held in memory only,
/// until the user answers or the tab leaves the site.
struct PasswordSaveRequest: Identifiable, Equatable, CustomStringConvertible {
    let id = UUID()
    let tabID: Tab.ID
    let host: String
    let username: String
    let password: String
    let offer: SaveOffer

    var site: String { SiteInfo.registrable(host) }

    var title: String {
        switch offer {
        case .save: "Save password for \(site)?"
        case .update: "Update password for \(username.isEmpty ? site : username)?"
        }
    }

    var confirmTitle: String { offer == .save ? "Save" : "Update" }
    var description: String { "PasswordSaveRequest(\(username) on \(host))" }
}

enum PasswordSaveAnswer {
    case save, notNow, never
}

extension VaultContents {
    /// A new account, or the one the offer names with its new password.
    mutating func store(_ offer: SaveOffer, host: String, username: String, password: String, now: Date) {
        switch offer {
        case .save:
            credentials.append(Credential(host: host.lowercased(), username: username, password: password, created: now, modified: now))
        case let .update(id):
            guard let index = credentials.firstIndex(where: { $0.id == id }) else { return }
            credentials[index].password = password
            credentials[index].modified = now
        }
    }
}
