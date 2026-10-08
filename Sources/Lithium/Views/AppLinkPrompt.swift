import SwiftUI

/// "Open Zoom?" along the top of the page, like the permission prompt: no button has a key, so
/// Return typed for the page never opens the app, and Escape cancels (`Browser.dismissOverlay`).
struct AppLinkPrompt: View {
    let request: AppLinkRequest
    @Environment(Browser.self) private var browser
    @State private var always = false
    @State private var protection = ClickProtection()

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: request.app.path))
                .resizable()
                .frame(width: 20, height: 20)
            Text("Open \(request.appName)?")
                .fontWeight(.semibold)
                .lineLimit(1)
            if request.canRemember {
                Toggle("Always allow \(request.host) to open these links", isOn: $always)
                    .toggleStyle(.checkbox)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button("Cancel") { answer(open: false) }
            Button("Open") { answer(open: true) }
        }
        .font(Theme.font(13))
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
        .onAppear { protection.rearm() }
        // Sliding in, or moved up under the pointer when a strip above it goes.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { _ in protection.rearm() }
    }

    /// A click within half a second of the prompt appearing or moving was aimed at the page or at
    /// the strip that was there (the second click of a double click): it does nothing.
    private func answer(open: Bool) {
        guard protection.accepts() else { return }
        browser.appLinks.answer(request, open: open, always: always)
    }
}
