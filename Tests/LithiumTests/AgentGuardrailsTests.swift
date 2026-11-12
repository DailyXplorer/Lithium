import Foundation
import Testing
@testable import Lithium

/// Which elements a snapshot marks as sensitive, and what the log may keep of what is typed, as
/// table tests. No browser needed.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentGuardrailsTests {
    typealias Element = Guardrails.Element
    typealias Page = Guardrails.Page

    private static let shop = Page(url: URL(string: "https://shop.example/products"))
    private static let checkout = Page(url: URL(string: "https://shop.example/checkout/step-2"))

    @Test func paymentProvidersMatchHostsAndSubdomains() {
        let known = PaymentProviders.known
        for address in ["https://js.stripe.com/v3/elements", "https://www.paypal.com/checkoutnow", "https://pay.google.com/gp/p/ui", "https://checkoutshopper-live.adyen.com/x", "https://shop.app/pay"] {
            #expect(known.contains(address: address), "\(address)")
        }
        for address in ["https://notstripe.com/", "https://stripe.com.evil.example/", "https://google.com/", "about:blank", "not a url"] {
            #expect(!known.contains(address: address), "\(address)")
        }
        #expect(PaymentProviders(hosts: ["localhost"]).contains(host: "LOCALHOST"))
        #expect(!known.contains(host: nil))
    }

    @Test func commitControlsInEachLanguage() {
        let cases: [(role: String, name: String, commit: Bool)] = [
            ("button", "Pay €42.00", true), ("button", "Place order", true), ("button", "PLACE YOUR ORDER", true),
            ("button", "Payer 42,00 €", true), ("button", "Passer la commande", true), ("button", "S’abonner", true),
            ("button", "Zahlungspflichtig bestellen", true), ("link", "Jetzt kaufen", true), ("button", "Realizar pedido", true),
            ("button", "Conferma ordine", true), ("clickable", "Buy now", true), ("button", "Pay 42 USD", true),
            ("button", "Continue", false), ("button", "Pay later options", false), ("textbox", "Pay", false), ("heading", "Buy", false),
        ]
        for test in cases {
            #expect(Guardrails.isCommitControl(role: test.role, name: test.name) == test.commit, "\(test.role) \(test.name)")
        }
        #expect(Guardrails.hasAmount("Pay €42.00"))
        #expect(Guardrails.hasAmount("Payer 42,00 €"))
        #expect(Guardrails.hasAmount("Buy for 12 eur"))
        #expect(!Guardrails.hasAmount("Buy 2 tickets"))
    }

    @Test func paymentPagesFromTheirSignals() {
        #expect(Self.checkout.isPaymentPage)
        #expect(Page(url: URL(string: "https://shop.example/PAY")).isPaymentPage)
        #expect(!Self.shop.isPaymentPage)
        #expect(!Page(url: URL(string: "https://shop.example/payment-methods-faq")).isPaymentPage)
        #expect(Page(url: Self.shop.url, cardField: true).isPaymentPage)
        #expect(Page(url: Self.shop.url, paymentFrame: true).isPaymentPage)
        #expect(Page(url: Self.shop.url, wallet: true).isPaymentPage)
        #expect(Page(url: URL(string: "https://www.paypal.com/checkoutnow")).isProviderTab)
    }

    /// What is typed is a secret, kept out of the log, in a card or password field, in a
    /// provider's frame or tab, and in a frame Lithium can't read.
    @Test func typedTextIsASecretWhereItMayBeOne() {
        let card = Element(role: "textbox", name: "Card number", field: "payment")
        let password = Element(role: "textbox", name: "Password", field: "password")
        let email = Element(role: "textbox", name: "Email")
        let cases: [(element: Element, page: Page, expected: GuardKind?, why: String)] = [
            (card, Self.shop, .payment, "a card number"),
            (Element(role: "combobox", name: "Expiry month", field: "payment"), Self.shop, .payment, "an expiry month"),
            (Element(role: "textbox", name: "Postcode", inPaymentFrame: true), Self.shop, .payment, "anything in a provider's frame"),
            (Element(role: "frame", inUnknownFrame: true), Self.shop, .password, "a frame of an origin nobody knows"),
            (Element(role: "frame", inUnknownFrame: true), Page(url: Self.shop.url, paymentFrame: true), .payment, "that frame on a page with a payment frame"),
            (email, Page(url: URL(string: "https://www.paypal.com/signin")), .payment, "anything in a provider's tab"),
            (password, Self.shop, .password, "a password"),
            (email, Self.shop, nil, "an email address"),
            (email, Self.checkout, nil, "an email address on a checkout page"),
            (Element(role: "checkbox", name: "Show password"), Self.shop, nil, "a show-password toggle"),
        ]
        for test in cases {
            #expect(Guardrails.secret(typedInto: test.element, page: test.page) == test.expected, "\(test.why)")
        }
    }

    /// A field is marked for what typing into it would hold, anything else for what a click on it
    /// does. Text and headings have no action, and no mark.
    @Test func marksWhatTheSnapshotShows() {
        let provider = Page(url: URL(string: "https://www.paypal.com/signin"))
        let password = Element(role: "textbox", name: "Password", field: "password")
        var framedPassword = password
        framedPassword.inPaymentFrame = true
        let cases: [(element: Element, page: Page, expected: GuardKind?, why: String)] = [
            (password, Self.shop, .password, "a password field"),
            (password, provider, .payment, "a password field on a provider's tab"),
            (framedPassword, Self.shop, .payment, "a password field in a provider's frame"),
            (Element(role: "textbox", name: "Card number", field: "payment"), Self.shop, .payment, "a card field"),
            (Element(role: "button", name: "Pay €42.00"), Self.shop, .payment, "a commit control with an amount"),
            (Element(role: "button", name: "Place order"), Self.checkout, .payment, "a commit control on a payment page"),
            (Element(role: "button", name: "Place order"), Self.shop, nil, "a commit control on an ordinary page"),
            (Element(role: "button", name: "Buy"), Self.shop, nil, "a Buy link on a product grid"),
            (Element(role: "shadow-closed", name: "apple-pay-button", wallet: true), Self.shop, .payment, "an Apple Pay button"),
            (Element(role: "button", name: "Sign in"), provider, .payment, "a button on a provider's tab"),
            (Element(role: "button", name: "Sign in"), Self.shop, nil, "a sign-in button"),
            (Element(role: "frame", inPaymentFrame: true), Self.shop, .payment, "a provider's frame"),
            (Element(role: "link", name: "Help"), Self.checkout, nil, "a plain link"),
            (Element(role: "heading", name: "Pay now", inPaymentFrame: true), Self.shop, nil, "a heading"),
            (Element(role: "text", name: "Total €42.00"), Self.checkout, nil, "text"),
        ]
        for test in cases {
            #expect(Guardrails.mark(test.element, page: test.page) == test.expected, "\(test.why)")
        }
    }

    @Test func dialogsSayWhatTheyAreAndTheirSafeDefault() {
        let confirm = AgentDialog(.confirm, message: "Leave \"this\" page?", host: "shop.example")
        #expect(confirm.line == "confirm from shop.example \"Leave \\\"this\\\" page?\"")
        #expect(confirm.json == ["type": "confirm", "message": "Leave \"this\" page?", "default": .null, "from": "shop.example"])
        #expect(confirm.safeDefault == DialogReply(accepted: false, text: nil))
        #expect(AgentDialog(.alert, message: "Saved", host: "").safeDefault.accepted)
        #expect(AgentDialog(.prompt, message: String(repeating: "x", count: 5000), host: "").message.count == 1000)
    }
}
