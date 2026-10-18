import SwiftUI

/// The list under a sign-in field, over the page. Its rows are buttons that never take the keyboard,
/// so typing goes on in the field.
struct PasswordDropdownLayer: View {
    let tab: Tab
    @Environment(Browser.self) private var browser
    @State private var page = CGSize.zero

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onGeometryChange(for: CGSize.self, of: \.size) { page = $0 }
            .overlay(alignment: .topLeading) {
                if let dropdown = browser.passwords.dropdown, dropdown.tabID == tab.id, page != .zero {
                    let frame = dropdown.frame(in: page)
                    PasswordDropdownView(dropdown: dropdown) { row in
                        Task { await browser.passwords.choose(row) }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                }
            }
    }
}

struct PasswordDropdownView: View {
    let dropdown: PasswordDropdown
    let choose: (PasswordDropdown.Row) -> Void
    @State private var hovered: PasswordDropdown.Row.ID?
    @State private var protection = ClickProtection()

    var body: some View {
        VStack(spacing: 0) {
            ForEach(dropdown.rows) { row in
                Button {
                    // A click aimed at the page as the list came up under the pointer fills nothing.
                    if protection.accepts() { choose(row) }
                } label: {
                    label(for: row)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: PasswordDropdown.rowHeight, maxHeight: PasswordDropdown.rowHeight, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovered == row.id ? Color.primary.opacity(0.08) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { inside in
                    if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
                }
            }
        }
        .padding(PasswordDropdown.padding)
        .font(Theme.font(13))
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .onAppear { protection.rearm() }
        .onChange(of: dropdown.rect) { protection.rearm() }
    }

    @ViewBuilder private func label(for row: PasswordDropdown.Row) -> some View {
        HStack(spacing: 10) {
            switch row {
            case let .account(_, username, host):
                Icon(.key, size: 15).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(username.isEmpty ? "No username" : username).fontWeight(.medium)
                    Text(host).font(Theme.font(11.5)).foregroundStyle(.secondary)
                }
            case .strongPassword:
                Icon(.magicWand, size: 15).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Use a strong password").fontWeight(.medium)
                    Text("Lithium saves it for this site").font(Theme.font(11.5)).foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }
}

/// "Save password for example.com?" along the top of the page. No button has a key, so Return
/// typed for the page never saves.
struct PasswordSaveBar: View {
    let request: PasswordSaveRequest
    let answer: (PasswordSaveAnswer) -> Void
    @State private var protection = ClickProtection()

    var body: some View {
        HStack(spacing: 12) {
            Icon(.key, size: 18).foregroundStyle(.secondary)
            Text(request.title)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Button("Never for this site") { reply(.never) }
            Button("Not now") { reply(.notNow) }
            Button(request.confirmTitle) { reply(.save) }
        }
        .font(Theme.font(13))
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
        .onAppear { protection.rearm() }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { _ in protection.rearm() }
    }

    /// A click within half a second of the bar appearing or moving was aimed elsewhere: it does nothing.
    private func reply(_ choice: PasswordSaveAnswer) {
        guard protection.accepts() else { return }
        answer(choice)
    }
}
