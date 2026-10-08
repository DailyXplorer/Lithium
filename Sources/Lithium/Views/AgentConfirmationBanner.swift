import SwiftUI

/// An agent's request for the user's Allow, as a strip along the top of the page like the site
/// permission prompt: in Lithium's own UI, out of the page's reach, never a modal that takes the
/// focus. Deny is the default: Escape denies, Return does nothing.
struct AgentConfirmationBanner: View {
    let confirmation: AgentConfirmation
    let confirmations: AgentConfirmations
    /// The tab it is about when another one is shown, for Show Tab.
    var otherTab: Tab?
    /// Prompts waiting behind this one.
    var queued = 0
    @Environment(Browser.self) private var browser
    /// The next prompt in the queue takes this one's place, with Allow once where it was: the
    /// second click of a double click, or one more quick click, must not answer it.
    @State private var protection = ClickProtection()

    var body: some View {
        HStack(spacing: 12) {
            Icon(confirmation.kind.icon, size: 18)
                .foregroundStyle(confirmation.kind == .payment ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                (Text(confirmation.client).fontWeight(.semibold) + Text(" wants to \(confirmation.action)"))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(Theme.font(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if let otherTab {
                Button("Show Tab") { browser.select(otherTab) }
            }
            Button("Deny") { answer(.deny) }
                .keyboardShortcut(.cancelAction)
            if confirmation.offersSiteGrant, let site = confirmation.site {
                Button("Allow on \(site)") { answer(.allowOnSite) }
                    .help("Allows this agent session to \(confirmation.kind.verb) on \(site) without asking, until the agent stops")
            }
            Button("Allow once") { answer(.allowOnce) }
        }
        .font(Theme.font(13))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
        .onAppear { protection.rearm() }
        .onChange(of: confirmation.id) { protection.rearm() }
        // Sliding in, or moved by a strip above it or its own text changing size.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { _ in protection.rearm() }
    }

    private func answer(_ answer: ConfirmationAnswer) {
        Self.answer(answer, to: confirmation.id, in: confirmations, protection: protection)
    }

    /// Answers only once the banner has stayed in place (see `protection`).
    static func answer(_ answer: ConfirmationAnswer, to id: AgentConfirmation.ID, in confirmations: AgentConfirmations, protection: ClickProtection, at now: ContinuousClock.Instant = .now) {
        guard protection.accepts(at: now) else { return }
        confirmations.answer(id, answer)
    }

    /// Who asks (a name the agent gave itself), where, and what a site grant would mean.
    private var detail: String {
        var parts = ["Agent \(confirmation.sessionLabel), name reported by the agent"]
        if let otherTab { parts.append("in “\(otherTab.displayTitle)”") }
        if confirmation.kind == .payment { parts.append("Payments always ask") }
        if confirmation.offersSiteGrant { parts.append("A site Allow lasts until the agent stops") }
        if queued > 0 { parts.append("\(queued) more waiting") }
        return parts.joined(separator: " · ")
    }
}

extension ConfirmationKind {
    var icon: Phosphor {
        switch self {
        case .payment: .shield
        case .password: .lock
        case .download: .download
        case .upload, .file: .folder
        }
    }

    var label: String {
        switch self {
        case .payment: "Payments"
        case .password: "Password fields"
        case .download: "Downloads"
        case .upload: "Uploads"
        case .file: "Local files"
        }
    }

    /// What a site grant lets the agent do, for the button's help.
    var verb: String {
        switch self {
        case .payment: "pay"
        case .password: "use password fields"
        case .download: "download files"
        case .upload: "upload files"
        case .file: "open local files"
        }
    }
}
