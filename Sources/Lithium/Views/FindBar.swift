import SwiftUI

struct FindBar: View {
    let tab: Tab
    @Environment(Browser.self) private var browser
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let find = browser.find
        HStack(spacing: 8) {
            Icon(.search, size: 15).opacity(0.5)
            TextField("Find in page", text: $text)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity)
                .focused($isFocused)
                .onKeyPress(.return, phases: .down) { press in
                    step(forward: !press.modifiers.contains(.shift))
                    return .handled
                }
            // With the arrows it steps through, like Safari and Chrome.
            Text(status(find))
                .font(Theme.font(12))
                .foregroundStyle(find.query.isEmpty || find.matchCount > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red.opacity(0.8)))
                .monospacedDigit()
                .fixedSize()
                .padding(.trailing, 4)
            FindButton(icon: .caretUp, help: "Previous (⇧⌘G)") { step(forward: false) }
            FindButton(icon: .caretDown, help: "Next (⌘G)") { step(forward: true) }
            FindButton(icon: .close, help: "Done (Esc)") { find.hide() }
        }
        .font(Theme.font(13))
        // On the page's background, not the sidebar color the window's ink is chosen for.
        .foregroundStyle(Color.primary)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(maxWidth: 360)
        .frame(height: 40)
        // The address suggestions' surface, since it floats over the page the same way.
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
        .onAppear {
            text = find.query
            if find.focusesField { claimFocus($isFocused) }
            // Closing the bar cleared the last search's matches; reopened, it shows them again.
            if !find.query.isEmpty { searchAgain() }
        }
        .onChange(of: find.focusToken) { claimFocus($isFocused) }
        .onChange(of: isFocused) { find.isFieldFocused = isFocused }
        .onDisappear { find.isFieldFocused = false }
        .onChange(of: find.query) { text = find.query }
        .onChange(of: text) {
            guard text != find.query else { return }
            Task { await find.update(query: text, in: tab.findTarget) }
        }
        // A new page to search (another tab, this tab going to or from a PDF, or a PDF whose
        // pages just arrived or unlocked) is searched again, and the old one cleared.
        .onChange(of: ObjectIdentifier(tab.findTarget)) { searchAgain() }
        .onChange(of: tab.pdf?.pageCount) { searchAgain() }
    }

    private func status(_ find: FindInPage) -> String {
        if find.query.isEmpty { return "" }
        if find.matchCount == 0 { return "No matches" }
        return "\(find.currentMatch)/\(find.matchCount)"
    }

    private func searchAgain() {
        Task { await browser.find.update(query: text, in: tab.findTarget) }
    }

    private func step(forward: Bool) {
        Task { await browser.find.step(forward: forward, in: tab.findTarget) }
    }
}

private struct FindButton: View {
    let icon: Phosphor
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 14)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
