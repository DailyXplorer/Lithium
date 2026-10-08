import Foundation

/// What an agent can't do without the user's Allow (design section 7.3).
enum ConfirmationKind: String, CaseIterable {
    case payment, password, download, upload, file

    /// Payments always ask; a `file:` address has no site to allow.
    var allowsSiteGrant: Bool { self != .payment && self != .file }
}

/// Payment providers' hosts: a frame or a tab on one of them, or under one, is a payment. The
/// list ships with Lithium; tests give their own, so a local server can stand in for a provider.
struct PaymentProviders: Equatable {
    let hosts: [String]

    static let known = PaymentProviders(hosts: [
        "stripe.com", "stripe.network", "paypal.com", "paypalobjects.com", "braintreegateway.com", "braintree-api.com",
        "adyen.com", "checkout.com", "squareup.com", "squarecdn.com", "klarna.com", "klarnaservices.com", "afterpay.com",
        "clearpay.co.uk", "affirm.com", "mollie.com", "worldpay.com", "authorize.net", "recurly.com", "chargebee.com",
        "paddle.com", "razorpay.com", "payplug.com", "payzen.eu", "lyra.com", "stancer.com", "sumup.com", "gocardless.com",
        "pay.google.com", "apple-pay-gateway.apple.com", "pay.amazon.com", "shop.app",
    ])

    func contains(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// An address or an origin such as `https://js.stripe.com`.
    func contains(address: String?) -> Bool {
        contains(host: address.flatMap(URL.init(string:))?.host())
    }
}

/// Which agent actions need the user's Allow, from the facts `agent.js` reports per frame. Pure:
/// no AppKit, no page; the snapshot marks elements with it, and input tools ask before acting.
enum Guardrails {
    /// An element as the snapshot shows it.
    struct Element {
        var role: String
        var name: String?
        /// `password` or `payment`, for a field `agent.js` marked.
        var field: String?
        /// An Apple Pay or Google Pay button.
        var wallet = false
        /// A password field that isn't empty is in its document, whoever filled it: a sign-in
        /// may send it without a form, from a plain button or link or on Enter.
        var passwordFilled = false
        /// A file input: it shows as a button, but a click on it only opens the file chooser,
        /// which `upload_files` asks about. Enter on it may still send the password.
        var setsFiles = false
        /// In a payment provider's frame, at any depth.
        var inPaymentFrame = false
        /// In a frame Lithium can't read, of an origin it can't tell: keys there may fill a
        /// card or a password.
        var inUnknownFrame = false
    }

    /// The tab's page, all frames together.
    struct Page {
        var url: URL?
        var cardField = false
        var paymentFrame = false
        var wallet = false
        var providers = PaymentProviders.known

        var isProviderTab: Bool { providers.contains(host: url?.host()) }

        var isPaymentPage: Bool {
            cardField || paymentFrame || wallet || (url?.pathComponents.contains { Guardrails.paymentPaths.contains($0.lowercased()) } ?? false)
        }
    }

    /// The form an action submits.
    struct Form {
        var cardField = false
        /// A password field that isn't empty, whoever filled it.
        var filledPassword = false
    }

    enum Action: Equatable {
        case type, select, check
        /// A key pressed in the element; `enter` when it is Enter or types Enter's carriage return.
        case press(enter: Bool)
        /// A click, or Enter or Space on a button or link.
        case activate
    }

    /// The confirmation `action` needs, nil when it is free. `form` is the form the action submits,
    /// if it submits one. A payment wins over a password.
    static func confirmation(for action: Action, on element: Element, page: Page, submitting form: Form? = nil) -> ConfirmationKind? {
        if page.isProviderTab || element.inPaymentFrame { return .payment }
        if element.inUnknownFrame { return page.isPaymentPage ? .payment : .password }
        if let form, form.cardField || page.paymentFrame { return .payment }
        switch action {
        case .type, .select, .check:
            if element.field == "payment" { return .payment }
            if element.field == "password", action == .type { return .password }
        case .press(let enter):
            if element.field == "payment" { return .payment }
            if enter, element.field == "password" || element.passwordFilled { return .password }
        case .activate:
            if element.wallet { return .payment }
            if isCommitControl(role: element.role, name: element.name), page.isPaymentPage || hasAmount(element.name) { return .payment }
            // A script can send the filled password from any click, form or not, and the target's
            // own role often hides it: a span inside a button, a div that only has a click
            // listener. Only a field's own controls are left out, and only from a click: Enter on
            // them beside a filled password is a `.press` (`ActionTarget.guarded`).
            if element.passwordFilled, !element.setsFiles, !Self.fieldRoles.contains(element.role) { return .password }
        }
        return form?.filledPassword == true ? .password : nil
    }

    /// The `guard` the snapshot shows on an element: what its usual action (typing into a field,
    /// activating anything else) would need, as `confirmation(for:)` decides it.
    static func mark(_ element: Element, page: Page) -> ConfirmationKind? {
        if element.field != nil { return confirmation(for: .type, on: element, page: page) }
        guard actionable.contains(element.role) || element.wallet else { return nil }
        return confirmation(for: .activate, on: element, page: page)
    }

    private static let actionable: Set<String> = [
        "link", "button", "textbox", "searchbox", "checkbox", "radio", "combobox", "listbox", "option", "slider",
        "spinbutton", "switch", "tab", "menuitem", "clickable", "shadow-closed", "frame",
    ]

    /// Controls a click sets rather than sends: clicking them beside a filled password is free.
    private static let fieldRoles: Set<String> = [
        "textbox", "searchbox", "checkbox", "radio", "switch", "combobox", "listbox", "option", "slider", "spinbutton",
    ]

    static let paymentPaths: Set<String> = ["checkout", "payment", "paiement", "pay", "kasse", "zahlung", "pago", "pagamento", "billing", "place-order"]

    /// A button or link whose name, amounts and punctuation taken out, says it pays or orders.
    static func isCommitControl(role: String, name: String?) -> Bool {
        guard ["button", "link", "clickable"].contains(role), let name else { return false }
        return commitNames.contains(normalized(stripping(amountsIn: name)))
    }

    static func hasAmount(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.contains(symbolAmount) || name.lowercased().contains(codeAmount)
    }

    nonisolated(unsafe) private static let symbolAmount = /[$€£¥₹] ?\d[\d.,]*/
    nonisolated(unsafe) private static let codeAmount = /\d[\d.,]* ?(?:€|(?:eur|usd|gbp|chf)\b)/

    private static func stripping(amountsIn name: String) -> String {
        name.lowercased().replacing(symbolAmount, with: " ").replacing(codeAmount, with: " ")
    }

    /// Lowercased, accents and punctuation gone, spaces collapsed: "S’abonner" is "sabonner".
    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let kept = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(kept)).split(separator: " ").joined(separator: " ")
    }

    private static let commitNames: Set<String> = Set([
        "pay", "pay now", "place order", "place your order", "complete order", "complete purchase", "complete payment", "confirm order",
        "confirm and pay", "confirm payment", "buy", "buy now", "purchase", "submit order", "submit payment", "subscribe",
        "start subscription", "donate", "payer", "payer maintenant", "commander", "passer la commande", "valider la commande",
        "valider et payer", "confirmer la commande", "confirmer le paiement", "finaliser la commande", "acheter", "s'abonner",
        "faire un don", "bezahlen", "jetzt bezahlen", "kaufen", "jetzt kaufen", "zahlungspflichtig bestellen", "bestellung abschicken",
        "abonnieren", "pagar", "comprar", "realizar pedido", "confirmar pedido", "paga", "acquista", "conferma ordine",
    ].map(normalized))
}
