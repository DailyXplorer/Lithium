import SwiftUI
import WebKit

/// One puzzle-piece button for every running extension, as in Chrome. It lists them with their
/// badge; choosing one runs its action, which usually opens its popup under this button.
struct ExtensionsButton: View {
    let tab: Tab?
    @Environment(Browser.self) private var browser
    @State private var isPresented = false

    var body: some View {
        let extensions = browser.extensions
        if !extensions.contexts.isEmpty {
            IconButton(icon: .puzzle, help: "Extensions") { isPresented.toggle() }
                .background(PopupAnchor { extensions.popupAnchor = $0 })
                .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                    ExtensionsList(tab: tab) { id in
                        isPresented = false
                        // The extension's own popover opens once this one has closed.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { extensions.performAction(id: id, in: tab) }
                    }
                }
        }
    }
}

private struct ExtensionsList: View {
    let tab: Tab?
    let choose: (String) -> Void
    @Environment(Browser.self) private var browser

    var body: some View {
        let extensions = browser.extensions
        let _ = extensions.actionsRevision
        VStack(alignment: .leading, spacing: 0) {
            Text("Extensions")
                .font(Theme.font(15, .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            Divider()
            VStack(spacing: 2) {
                ForEach(extensions.installed.filter(\.isEnabled)) { entry in
                    if let action = extensions.contexts[entry.id]?.action(for: tab) {
                        ExtensionRow(name: action.label.isEmpty ? entry.name : action.label, action: action) { choose(entry.id) }
                    }
                }
            }
            .padding(6)
            Divider()
            Button("Manage Extensions") { browser.openSettings(section: "extensions") }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(12)
        }
        .font(Theme.font(13))
        .frame(width: 280)
    }
}

private struct ExtensionRow: View {
    let name: String
    let action: WKWebExtension.Action
    let choose: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Group {
                    if let icon = action.icon(for: CGSize(width: 18, height: 18)) {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Icon(.puzzle, size: 18)
                    }
                }
                .frame(width: 18, height: 18)
                Text(name).lineLimit(1)
                Spacer(minLength: 4)
                if !action.badgeText.isEmpty {
                    Text(action.badgeText)
                        .font(Theme.font(10, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minHeight: 16)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isHovered && action.isEnabled ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 }
        .help(name)
    }
}

/// The AppKit view behind the button, which extension popovers point at.
private struct PopupAnchor: NSViewRepresentable {
    let register: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        register(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        register(view)
    }
}
