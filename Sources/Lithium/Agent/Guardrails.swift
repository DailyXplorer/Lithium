import Foundation

/// What a snapshot's `guard` says of an element: acting on it pays, or types or sends a password.
/// Lithium asks the user nothing; the mark tells the agent, whose own rules decide.
enum GuardKind: String, CaseIterable {
    case payment, password
}

/// Payment providers' hosts: a frame or a tab on one of them, or under one, is a payment.
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

/// Which elements are sensitive, from the facts `agent.js` reports per frame. Pure: no AppKit,
/// no page.
enum Guardrails {
    struct Element {
        var role: String
        var name: String?
        /// `password` or `payment`, for a field `agent.js` marked.
        var field: String?
        /// An Apple Pay or Google Pay button.
        var wallet = false
        var inPaymentFrame = false
        /// In a frame Lithium can't read: keys there may fill a card or a password.
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

    /// What text typed into `element` is: a card's, a password's, or nil for neither. Decides
    /// what the action log keeps of it. A payment wins over a password.
    static func secret(typedInto element: Element, page: Page) -> GuardKind? {
        if page.isProviderTab || element.inPaymentFrame { return .payment }
        if element.inUnknownFrame { return page.isPaymentPage ? .payment : .password }
        return element.field.flatMap(GuardKind.init(rawValue:))
    }

    /// The `guard` the snapshot shows: a card or password field, a wallet button, a control that
    /// commits a payment, or anything a click reaches in a provider's frame or tab.
    static func mark(_ element: Element, page: Page) -> GuardKind? {
        if element.field != nil { return secret(typedInto: element, page: page) }
        guard actionable.contains(element.role) || element.wallet else { return nil }
        if page.isProviderTab || element.inPaymentFrame || element.wallet { return .payment }
        return isCommitControl(role: element.role, name: element.name) && (page.isPaymentPage || hasAmount(element.name)) ? .payment : nil
    }

    private static let actionable: Set<String> = [
        "link", "button", "textbox", "searchbox", "checkbox", "radio", "combobox", "listbox", "option", "slider",
        "spinbutton", "switch", "tab", "menuitem", "clickable", "shadow-closed", "frame",
    ]

    static let paymentPaths: Set<String> = ["checkout", "payment", "paiement", "pay", "kasse", "zahlung", "pago", "pagamento", "billing", "place-order"]

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

    /// "S’abonner" is "sabonner".
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
