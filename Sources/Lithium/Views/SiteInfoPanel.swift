import SwiftUI

/// Opened from the lock in the address bar: connection, cookies and site data, permissions.
/// Built fresh on every opening: the certificate only exists once the page has committed.
struct SiteInfoPanel: View {
    let tab: Tab

    var body: some View {
        if let url = tab.url {
            SiteInfoContent(tab: tab, info: SiteInfo(url: url, trust: tab.webView.serverTrust))
                .id(url.absoluteString + String(tab.webView.serverTrust != nil))
        }
    }
}

private struct SiteInfoContent: View {
    let tab: Tab
    @State var info: SiteInfo
    @Environment(Browser.self) private var browser
    @State private var showsCookies = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Favicon(image: tab.favicon, fallback: info.host, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.host.hasPrefix("www.") ? String(info.host.dropFirst(4)) : info.host)
                        .font(Theme.font(15, .semibold))
                        .lineLimit(1)
                    Text(info.isSecure ? "Connection is secure" : "Connection is not secure")
                        .font(Theme.font(12))
                        .foregroundStyle(info.isSecure ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
            }
            .padding(.bottom, 14)

            Section(title: "Connection") {
                if let certificate = info.certificate {
                    Detail(label: "Issued to", value: certificate.subject)
                    Detail(label: "Issued by", value: certificate.issuer)
                    if let validUntil = certificate.validUntil {
                        Detail(label: "Valid until", value: validUntil.formatted(date: .long, time: .omitted))
                    }
                } else {
                    Text("Information you send or receive on this site could be read by others.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(title: "Cookies and site data") {
                if info.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cookieSummary)
                            if !info.dataKinds.isEmpty {
                                Text(info.dataKinds.joined(separator: " · "))
                                    .font(Theme.font(12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if !info.cookies.isEmpty {
                            Button(showsCookies ? "Hide" : "Show") { withAnimation(.snappy(duration: 0.15)) { showsCookies.toggle() } }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    if showsCookies {
                        CookieList(cookies: info.cookies)
                    }
                    Button {
                        Task {
                            await info.clear()
                            tab.reload()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if info.isClearing { ProgressView().controlSize(.mini) } else { Icon(.trash, size: 14) }
                            Text("Clear cookies and site data")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .disabled(info.isClearing || (info.cookies.isEmpty && info.dataKinds.isEmpty))
                    .opacity(info.cookies.isEmpty && info.dataKinds.isEmpty ? 0.4 : 1)
                    .padding(.top, 4)
                }
            }

            Section(title: "Permissions") {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(kind: kind, host: info.host)
                }
            }

            Divider().padding(.vertical, 12)
            Button("Site settings") { browser.openSettings(section: "permissions") }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .font(Theme.font(13))
        .padding(18)
        .frame(width: 340)
        .task { await info.load() }
    }

    private var cookieSummary: String {
        switch info.cookies.count {
        case 0: "No cookies"
        case 1: "1 cookie"
        default: "\(info.cookies.count) cookies"
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(title.uppercased())
                .font(Theme.font(10.5, .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            content
        }
        .padding(.bottom, 12)
    }
}

private struct Detail: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value).lineLimit(2).textSelection(.enabled)
        }
    }
}

private struct CookieList: View {
    let cookies: [HTTPCookie]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(cookies.sorted { $0.name < $1.name }, id: \.self) { cookie in
                    HStack(alignment: .firstTextBaseline) {
                        Text(cookie.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(cookie.domain)
                            .font(Theme.font(11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxHeight: 140)
    }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    let host: String
    @Environment(Browser.self) private var browser

    var body: some View {
        let permissions = browser.permissions
        HStack {
            Icon(kind.icon, size: 15).opacity(0.7)
            Text(kind.label)
            Spacer()
            Picker("", selection: Binding(
                get: { permissions.decisions[host]?[kind] },
                set: { permissions.set($0, for: kind, host: host) }
            )) {
                Text("Ask").tag(PermissionDecision?.none)
                Text("Allow").tag(PermissionDecision?.some(.allow))
                Text("Block").tag(PermissionDecision?.some(.deny))
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}
