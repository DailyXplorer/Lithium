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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Extensions").font(Theme.font(15, .semibold))
                if tab?.url?.scheme?.hasPrefix("http") == true, let host = Privacy.siteHost(tab?.url) {
                    Text(host).font(Theme.font(12)).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 2) {
                ForEach(extensions.installed.filter(\.isEnabled)) { entry in
                    if let action = extensions.contexts[entry.id]?.action(for: tab) {
                        ExtensionRow(name: action.label.isEmpty ? entry.name : action.label, action: action) { choose(entry.id) }
                    }
                }
            }
            .padding(.horizontal, -8)
            Divider()
            Button("Manage Extensions") { browser.openSettings(section: "extensions") }
                .buttonStyle(.plain)
                .font(Theme.font(12))
                .foregroundStyle(Color.accentColor)
        }
        .font(Theme.font(13))
        .padding(16)
        .frame(width: 300)
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
