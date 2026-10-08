import SwiftUI

/// Opened from the lock in the address bar: the site's connection, cookies and permissions; the
/// rest is in its settings.
struct SiteInfoPanel: View {
    let tab: Tab

    var body: some View {
        if let url = tab.url {
            LiveSiteInfo(tab: tab, info: SiteInfo(url: url, loadError: tab.loadError, store: tab.dataStore))
                .id("\(url.absoluteString) \(tab.connection)")
        }
    }
}

private struct LiveSiteInfo: View {
    let tab: Tab
    @State var info: SiteInfo
    @State private var showsCertificate = false
    /// Set once switched here: the preference itself isn't observable.
    @State private var usesSiteFont: Bool?
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let url = tab.url
        SiteInfoView(
            host: info.host,
            favicon: tab.favicon,
            connection: info.connection,
            certificate: info.certificate,
            cookieCount: info.cookieCount,
            canClear: info.hasData && !info.isClearing,
            permissions: browser.permissions.decisions(for: info.host, privateSession: tab.privateSession),
            protections: Binding(
                get: { browser.privacy.isEnabled(for: tab.url, privateSession: tab.privateSession) },
                set: { browser.setProtections($0, for: tab) }
            ),
            usesSiteFont: url.flatMap { url in
                guard PageStyle.offersSiteFont(url) else { return nil }
                return Binding(
                    get: { usesSiteFont ?? !PageStyle.usesPageFont(url, privateSession: tab.privateSession) },
                    set: { keeps in
                        usesSiteFont = keeps
                        browser.changePageFont { PageStyle.setKeepsSiteFont(keeps, for: info.host, privateSession: tab.privateSession) }
                    }
                )
            },
            siteFontIsFixed: PageStyle.isLoopback(info.host),
            showsCertificate: $showsCertificate,
            onClear: {
                Task {
                    await info.clear()
                    browser.navigate(tab, .reload)
                }
            },
            onOpenSettings: {
                dismiss()
                browser.openSettings(section: "site/\(info.host)")
            }
        )
        .task { await info.load() }
        // Read when asked, so it is the trust of the page committed by then.
        .task(id: showsCertificate) {
            if showsCertificate { await info.loadCertificate(trust: tab.loadedWebView?.serverTrust) }
        }
    }
}

/// The panel from plain values, so it also draws without a tab.
struct SiteInfoView: View {
    let host: String
    let favicon: NSImage?
    let connection: SiteInfo.Connection
    let certificate: SiteInfo.CertificateLookup
    let cookieCount: Int?
    let canClear: Bool
    let permissions: [PermissionKind: PermissionDecision]
    /// The ⋯ menu's Site Protections switch, here too: no toolbar button holds it any more.
    var protections: Binding<Bool>?
    /// Nil where the website font wouldn't apply anyway.
    var usesSiteFont: Binding<Bool>?
    var siteFontIsFixed = false
    @Binding var showsCertificate: Bool
    var onClear: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    /// "Ask" until the site has an answer; one answer is named, more are counted.
    static func permissionSummary(_ decisions: [PermissionKind: PermissionDecision]) -> String {
        let allowed = PermissionKind.allCases.filter { decisions[$0] == .allow }
        let blocked = PermissionKind.allCases.filter { decisions[$0] == .deny }
        switch (allowed.count, blocked.count) {
        case (0, 0): return "Ask"
        case (1, 0): return "\(allowed[0].label) allowed"
        case (0, 1): return "\(blocked[0].label) blocked"
        default:
            return [(allowed.count, "allowed"), (blocked.count, "blocked")]
                .filter { $0.0 > 0 }
                .map { "\($0.0) \($0.1)" }
                .joined(separator: ", ")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Favicon(image: favicon, fallback: host, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
                        .font(Theme.font(15, .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if connection == .secure {
                        // Not animated: the popover kept its old height and cut the panel at both ends.
                        Button { showsCertificate.toggle() } label: {
                            HStack(spacing: 3) {
                                Text("Secure")
                                Icon(showsCertificate ? .caretDown : .forward, size: 10)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Certificate")
                        if showsCertificate { certificateLines }
                    } else {
                        Text("Not secure").foregroundStyle(Color.orange)
                        Text(connection.reason).foregroundStyle(.secondary)
                    }
                }
                .font(Theme.font(12))
            }

            Divider().padding(.vertical, 12)

            VStack(spacing: 8) {
                Row(label: "Cookies") {
                    Text(cookieCount.map(String.init) ?? "–").monospacedDigit()
                    if canClear {
                        Button("Clear", action: onClear)
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Row(label: "Permissions") {
                    Text(Self.permissionSummary(permissions))
                }
                if let protections {
                    SwitchRow(label: "Block ads and trackers", isOn: protections)
                }
                if let usesSiteFont {
                    SwitchRow(label: "Use this site's font", isOn: usesSiteFont)
                        .disabled(siteFontIsFixed)
                        .help(siteFontIsFixed ? "Pages on this Mac keep their font" : "Instead of your font")
                }
            }

            Button(action: onOpenSettings) {
                Text("Site settings…")
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.07)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
        }
        .font(Theme.font(13))
        .padding(16)
        .frame(width: 280)
    }

    @ViewBuilder private var certificateLines: some View {
        Group {
            switch certificate {
            case .loading:
                Text("Loading…")
            case .unavailable:
                Text("Certificate unavailable")
            case .found(let certificate):
                Text("Issued by \(certificate.issuer)").lineLimit(1).truncationMode(.tail)
                if let validUntil = certificate.validUntil {
                    Text("Expires \(validUntil.formatted(date: .abbreviated, time: .omitted))")
                }
            }
        }
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
    }
}

private struct Row<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    var body: some View {
        HStack(spacing: 10) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value
        }
    }
}

/// A switch laid out as a `Row`: label on the left with the others, switch on the right with
/// their values. A bare `Toggle` only takes its own width, so the column centred it.
private struct SwitchRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Row(label: label) {
            Toggle(label, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}
