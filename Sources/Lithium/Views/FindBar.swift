import SwiftUI
import WebKit

struct FindBar: View {
    let webView: WKWebView
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
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
        .onAppear {
            text = find.query
            claimFocus($isFocused)
        }
        .onChange(of: find.focusToken) { claimFocus($isFocused) }
        .onChange(of: find.query) { text = find.query }
        .onChange(of: text) {
            guard text != find.query else { return }
            Task { await find.update(query: text, in: webView) }
        }
    }

    private func status(_ find: FindInPage) -> String {
        if find.query.isEmpty { return "" }
        if find.matchCount == 0 { return "No matches" }
        return "\(find.currentMatch)/\(find.matchCount)"
    }

    private func step(forward: Bool) {
        Task { await browser.find.step(forward: forward, in: webView) }
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
