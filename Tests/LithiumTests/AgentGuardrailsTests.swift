import Foundation
import Testing
@testable import Lithium

/// Which agent actions need the user's Allow, and the prompts and grants that answer them, as
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

    /// The decision table of design section 7.3.
    @Test func decidesEachAction() {
        let button = { (name: String) in Element(role: "button", name: name) }
        let card = Element(role: "textbox", name: "Card number", field: "payment")
        let password = Element(role: "textbox", name: "Password", field: "password")
        let email = Element(role: "textbox", name: "Email")
        let inFrame = Element(role: "textbox", name: "Postcode", inPaymentFrame: true)
        let wallet = Element(role: "shadow-closed", name: "apple-pay-button", wallet: true)
        let cases: [(action: Guardrails.Action, element: Element, page: Page, form: Guardrails.Form?, expected: ConfirmationKind?, why: String)] = [
            (.type, card, Self.shop, nil, .payment, "typing a card number"),
            (.select, Element(role: "combobox", name: "Expiry month", field: "payment"), Self.shop, nil, .payment, "picking an expiry month"),
            (.press("ArrowDown"), card, Self.shop, nil, .payment, "a key in a card field"),
            (.type, inFrame, Self.shop, nil, .payment, "anything in a provider's frame"),
            (.activate, email, Page(url: URL(string: "https://www.paypal.com/signin")), nil, .payment, "anything in a provider's tab"),
            (.activate, button("Pay €42.00"), Self.shop, nil, .payment, "a commit control with an amount anywhere"),
            (.activate, button("Place order"), Self.checkout, nil, .payment, "a commit control on a payment page"),
            (.activate, button("Place order"), Self.shop, nil, nil, "a commit control on an ordinary page"),
            (.activate, button("Buy"), Self.shop, nil, nil, "a Buy link on a product grid"),
            (.activate, wallet, Self.shop, nil, .payment, "an Apple Pay button"),
            (.activate, button("Continue"), Self.shop, Guardrails.Form(cardField: true), .payment, "submitting a form with a card field"),
            (.press("Enter"), email, Page(url: Self.shop.url, paymentFrame: true), Guardrails.Form(), .payment, "submitting any form on a page with a payment frame"),
            (.type, password, Self.shop, nil, .password, "typing a password"),
            (.press("Enter"), password, Self.shop, nil, .password, "Enter in a password field"),
            (.press("Tab"), password, Self.shop, nil, nil, "Tab out of a password field"),
            (.check, Element(role: "checkbox", name: "Show password", field: nil), Self.shop, nil, nil, "a show-password toggle"),
            (.activate, button("Sign in"), Self.shop, Guardrails.Form(filledPassword: true), .password, "submitting a filled password"),
            (.activate, button("Sign in"), Self.shop, Guardrails.Form(filledPassword: false), nil, "submitting an empty password field"),
            (.activate, button("Pay €42.00"), Self.shop, Guardrails.Form(filledPassword: true), .payment, "a payment wins over a password"),
            (.type, email, Self.checkout, nil, nil, "an email field on a checkout page"),
        ]
        for test in cases {
            #expect(Guardrails.confirmation(for: test.action, on: test.element, page: test.page, submitting: test.form) == test.expected, "\(test.why)")
        }
    }

    /// The mark is the confirmation the element's usual action meets: typing into a field,
    /// activating anything else. Text and headings have no action, and no mark.
    @Test func marksWhatTheSnapshotShows() {
        let provider = Page(url: URL(string: "https://www.paypal.com/signin"))
        let password = Element(role: "textbox", name: "Password", field: "password")
        var framedPassword = password
        framedPassword.inPaymentFrame = true
        let cases: [(element: Element, page: Page, expected: ConfirmationKind?, why: String)] = [
            (password, Self.shop, .password, "a password field"),
            (password, provider, .payment, "a password field on a provider's tab"),
            (framedPassword, Self.shop, .payment, "a password field in a provider's frame"),
            (Element(role: "textbox", name: "Card number", field: "payment"), Self.shop, .payment, "a card field"),
            (Element(role: "button", name: "Pay €42.00"), Self.shop, .payment, "a commit control with an amount"),
            (Element(role: "button", name: "Sign in"), provider, .payment, "a button on a provider's tab"),
            (Element(role: "frame", inPaymentFrame: true), Self.shop, .payment, "a provider's frame"),
            (Element(role: "link", name: "Help"), Self.checkout, nil, "a plain link"),
            (Element(role: "heading", name: "Pay now", inPaymentFrame: true), Self.shop, nil, "a heading"),
            (Element(role: "text", name: "Total €42.00"), Self.checkout, nil, "text"),
        ]
        for test in cases {
            let mark = Guardrails.mark(test.element, page: test.page)
            #expect(mark == test.expected, "\(test.why)")
            guard test.expected != nil else { continue }
            let action: Guardrails.Action = test.element.field == nil ? .activate : .type
            #expect(mark == Guardrails.confirmation(for: action, on: test.element, page: test.page), "\(test.why)")
        }
    }

    // MARK: Prompts and grants

    private func confirmation(_ kind: ConfirmationKind, session: String = "a", tab: Tab.ID? = nil, site: String? = "example.com") -> AgentConfirmation {
        AgentConfirmation(kind: kind, session: session, sessionLabel: "s1", client: "test", tabID: tab, action: "do it", site: site)
    }

    @Test func allowOnSiteGrantsOneKindOnOneSiteForOneSession() throws {
        let confirmations = AgentConfirmations()
        let download = confirmation(.download)
        confirmations.ask(download)
        confirmations.answer(download.id, .allowOnSite)
        #expect(confirmations.answers[download.id] == .allowOnSite)
        #expect(confirmations.pending.isEmpty)
        #expect(confirmations.grant(for: .download, site: "example.com", session: "a") != nil)
        #expect(confirmations.grant(for: .download, site: "example.com", session: "b") == nil)
        #expect(confirmations.grant(for: .upload, site: "example.com", session: "a") == nil)
        #expect(confirmations.grant(for: .download, site: "other.example", session: "a") == nil)
        // Answered twice, only the first counts.
        confirmations.answer(download.id, .deny)
        #expect(confirmations.answers[download.id] == .allowOnSite)
        confirmations.finish(download.id)
        #expect(confirmations.answers.isEmpty)

        confirmations.revoke(try #require(confirmations.grants.first))
        #expect(confirmations.grants.isEmpty)
    }

    @Test func paymentsAndFilesAreNeverGranted() {
        let confirmations = AgentConfirmations()
        for kind in [ConfirmationKind.payment, .file] {
            let asked = confirmation(kind, site: kind == .file ? nil : "shop.example")
            #expect(!asked.offersSiteGrant)
            confirmations.ask(asked)
            confirmations.answer(asked.id, .allowOnSite)
            #expect(confirmations.grant(for: kind, site: "shop.example", session: "a") == nil)
        }
        #expect(confirmations.grants.isEmpty)
        #expect(confirmation(.password).offersSiteGrant)
    }

    @Test func endingASessionDropsItsGrantsAndCancelsItsPrompts() {
        let confirmations = AgentConfirmations()
        for session in ["a", "b"] {
            let granted = confirmation(.download, session: session)
            confirmations.ask(granted)
            confirmations.answer(granted.id, .allowOnSite)
        }
        let waiting = confirmation(.upload, session: "a")
        let other = confirmation(.upload, session: "b")
        confirmations.ask(waiting)
        confirmations.ask(other)
        confirmations.end(session: "a")
        #expect(confirmations.grants.map(\.session) == ["b"])
        #expect(confirmations.answers[waiting.id] == .cancelled)
        #expect(confirmations.pending == [other])
    }

    @Test func oneBannerAtATimeTheSelectedTabFirst() {
        let confirmations = AgentConfirmations()
        let (first, second) = (UUID(), UUID())
        let older = confirmation(.download, tab: first)
        let newer = confirmation(.download, tab: second)
        let later = confirmation(.upload, tab: second)
        [older, newer, later].forEach(confirmations.ask)
        #expect(confirmations.front(selected: nil) == older)
        #expect(confirmations.front(selected: second) == newer)
        confirmations.cancel(tab: second)
        #expect(confirmations.pending == [older])
        #expect(confirmations.answers[later.id] == .cancelled)
        #expect(confirmations.isAsking(about: first, .download))
        #expect(!confirmations.isAsking(about: first, .upload))
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
