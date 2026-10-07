import SwiftUI

/// A strip along the top of the page, like Safari's, instead of a floating card. No button has a
/// key: Return typed for the page or the address bar must never grant (and remember) a permission.
/// Escape dismisses it without remembering anything (`Browser.dismissOverlay`).
struct PermissionPrompt: View {
    let request: PermissionRequest
    @Environment(Browser.self) private var browser

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(request.kinds) { Icon($0.icon, size: 16) }
            }
            .foregroundStyle(Color.accentColor)
            (Text(request.host).fontWeight(.semibold) + Text(Self.asks(request.kinds)))
                .lineLimit(1)
            Text("Remembered in Settings")
                .font(Theme.font(12))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 12)
            Button("Don’t Allow") { browser.permissions.answer(request, allow: false) }
            Button("Allow") { browser.permissions.answer(request, allow: true) }
        }
        .font(Theme.font(13))
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
    }

    private static func asks(_ kinds: [PermissionKind]) -> String {
        if kinds == [.downloads] { return " wants to download a file" }
        return " wants to use your " + kinds.map { $0.label.lowercased() }.formatted(.list(type: .and))
    }
}
