import SwiftUI

/// A strip along the top of the page, like Safari's, instead of a floating card. No button has a
/// key: Return typed for the page or the address bar must never grant (and remember) a permission.
/// Escape dismisses it without remembering anything (`Browser.dismissOverlay`).
struct PermissionPrompt: View {
    let request: PermissionRequest
    @Environment(Browser.self) private var browser
    @State private var protection = ClickProtection()

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(request.kinds) { Icon($0.icon, size: 16) }
            }
            .foregroundStyle(Color.accentColor)
            (Text(request.host).fontWeight(.semibold) + Text(Self.asks(request.kinds)))
                .lineLimit(1)
            Text(request.privateSession != nil ? "Remembered until the private tabs close"
                 : request.space != nil ? "Remembered in this space until you quit" : "Remembered in Settings")
                .font(Theme.font(12))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 12)
            Button("Don’t Allow") { answer(allow: false) }
            Button("Allow") { answer(allow: true) }
        }
        .font(Theme.font(13))
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
        .onAppear { protection.rearm() }
        .onChange(of: request.id) { protection.rearm() }
        // Sliding in, or moved by a banner above it coming or going.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { _ in protection.rearm() }
    }

    private func answer(allow: Bool) {
        guard protection.accepts() else { return }
        browser.permissions.answer(request, allow: allow)
    }

    private static func asks(_ kinds: [PermissionKind]) -> String {
        if kinds == [.downloads] { return " wants to download a file" }
        return " wants to use your " + kinds.map { $0.label.lowercased() }.formatted(.list(type: .and))
    }
}

/// The prompt's buttons take clicks only once it has stayed in place a moment, like Chrome's
/// input protection: a page can't make it appear, or move, under a pointer already clicking (a
/// double click's second click, a game's rapid clicks) and have that click land on Allow.
struct ClickProtection {
    static let delay = Duration.milliseconds(500)
    private(set) var since: ContinuousClock.Instant

    init(at now: ContinuousClock.Instant = .now) { since = now }

    mutating func rearm(at now: ContinuousClock.Instant = .now) { since = now }

    func accepts(at now: ContinuousClock.Instant = .now) -> Bool { now - since >= Self.delay }
}
