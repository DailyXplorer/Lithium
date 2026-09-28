import SwiftUI

struct ToolbarView: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let tab = browser.selectedTab
        HStack(spacing: 2) {
            if !browser.isSidebarVisible {
                SidebarToggle()
            }
            IconButton(icon: .back, help: "Back (⌘[)", isEnabled: tab?.canGoBack == true) {
                tab?.webView.goBack()
            }
            IconButton(icon: .forward, help: "Forward (⌘])", isEnabled: tab?.canGoForward == true) {
                tab?.webView.goForward()
            }
            IconButton(
                icon: tab?.isLoading == true ? .close : .reload,
                help: tab?.isLoading == true ? "Stop" : "Reload (⌘R)",
                isEnabled: tab?.url != nil
            ) {
                if tab?.isLoading == true { tab?.webView.stopLoading() } else { tab?.reload() }
            }
            Spacer(minLength: 16)
            AddressBar(tab: tab)
                .frame(maxWidth: 560)
            Spacer(minLength: 16)
            ExtensionsButton(tab: tab)
            DownloadsButton()
            SummaryButton(tab: tab)
            ShieldButton(tab: tab)
            CaptureButton()
            PageMenu(tab: tab)
        }
        .padding(.horizontal, Layout.margin)
    }
}

private struct AddressBar: View {
    let tab: Tab?
    @Environment(Browser.self) private var browser
    @Environment(\.sidebarPalette) private var palette
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 4) {
            if !isEditing, let tab, let scheme = tab.url?.scheme, ["http", "https"].contains(scheme) {
                ConnectionButton(tab: tab, isSecure: scheme == "https")
            } else {
                Icon(.search, size: 15)
                    .opacity(0.5)
                    .frame(width: 22, height: 22)
            }
            AddressField(
                url: tab?.url,
                focusToken: browser.addressFocusToken,
                isEditing: $isEditing,
                onDarkBackground: palette.isDark,
                browser: browser
            )
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(height: 28)
        .anchorPreference(key: AddressBarBounds.self, value: .bounds) { $0 }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isEditing ? Color(nsColor: .textBackgroundColor) : palette.field)
                .shadow(color: .black.opacity(isEditing ? 0.12 : 0), radius: 2, y: 1)
        )
        .overlay {
            if let tab, !isEditing {
                LoadingBar(tab: tab)
                    .id(tab.id)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

/// Lock in the address bar; opens the site's connection, cookies and permissions.
private struct ConnectionButton: View {
    let tab: Tab
    let isSecure: Bool
    @Environment(\.sidebarPalette) private var palette
    @State private var isHovered = false
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Icon(isSecure ? .lock : .lockOpen, size: 15)
                .foregroundStyle(isSecure ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.orange))
                .opacity(isSecure ? 0.6 : 1)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(isHovered ? palette.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Site information")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SiteInfoPanel(tab: tab)
        }
    }
}

private struct ShieldButton: View {
    let tab: Tab?
    @Environment(Browser.self) private var browser
    @State private var isPresented = false

    var body: some View {
        let enabled = browser.privacy.isEnabled(for: tab?.url)
        IconButton(
            icon: enabled ? .shield : .shieldOff,
            help: enabled ? "Protections are on for this site (⇧⌘P turns them off)" : "Protections are off for this site (⇧⌘P turns them on)",
            isEnabled: tab?.url?.scheme?.hasPrefix("http") == true
        ) {
            isPresented.toggle()
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ShieldPanel(tab: tab)
        }
    }
}

private struct ShieldPanel: View {
    let tab: Tab?
    @Environment(Browser.self) private var browser

    var body: some View {
        let privacy = browser.privacy
        let host = Privacy.siteHost(tab?.url) ?? ""
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Protections").font(Theme.font(15, .semibold))
                Text(host).font(Theme.font(12)).foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(
                get: { privacy.isEnabled(for: tab?.url) },
                set: { browser.setProtections($0, for: tab) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On for this site")
                    Text("Ad and tracker blocking, fingerprinting protection")
                        .font(Theme.font(11))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Divider()
            Text(summary(privacy))
                .font(Theme.font(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.font(13))
        .padding(16)
        .frame(width: 300)
    }

    private func summary(_ privacy: Privacy) -> String {
        let count = privacy.ruleCount.formatted()
        let date = privacy.filtersUpdated?.formatted(date: .abbreviated, time: .omitted) ?? "—"
        return "\(count) rules from uBlock Origin, EasyList, EasyPrivacy, Peter Lowe and URLhaus. Lists updated \(date)."
    }
}

private struct PageMenu: View {
    let tab: Tab?
    @Environment(Browser.self) private var browser

    var body: some View {
        Menu {
            Button("Copy Link") {
                guard let url = tab?.url else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            .disabled(tab?.url == nil)
            Button(tab?.pinID == nil ? "Pin Tab" : "Unpin Tab") {
                browser.togglePinForSelectedTab()
            }
            .disabled(tab?.url == nil)
            Button("Pop Out Video") { browser.videoPopout.showSelected() }
                .disabled(!browser.videoPopout.canShowSelected)
            Divider()
            Button("Show All History") { browser.openHistory() }
            Button("Extensions") { browser.openSettings(section: "extensions") }
            Divider()
            Button("Settings…") { browser.openSettings() }
        } label: {
            Icon(.more, size: 18)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(0.85)
    }
}

/// AppKit text field so a click selects the whole URL, Escape restores it, and ⌘L/⌘T can focus it.
private struct AddressField: NSViewRepresentable {
    let url: URL?
    let focusToken: Int
    @Binding var isEditing: Bool
    let onDarkBackground: Bool
    let browser: Browser

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> URLTextField {
        let field = URLTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.nsFont(13)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.placeholderString = "Search or enter address"
        field.delegate = context.coordinator
        field.onFocusChange = { editing in context.coordinator.parent.isEditing = editing }
        context.coordinator.focusToken = focusToken
        return field
    }

    func updateNSView(_ field: URLTextField, context: Context) {
        context.coordinator.parent = self
        field.textColor = onDarkBackground && !isEditing ? .white : .labelColor
        if field.url != url || !field.isEditing {
            field.url = url
            if !field.isEditing { field.showSummary() }
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        var focusToken = 0

        init(_ parent: AddressField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? URLTextField else { return false }
            let suggestions = parent.browser.suggestions
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Submit before resigning: ending the edit clears the suggestions being read.
                parent.browser.submitAddress(field.stringValue)
                field.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.moveDown(_:)) where !suggestions.items.isEmpty:
                suggestions.move(by: 1)
                return true
            case #selector(NSResponder.moveUp(_:)) where !suggestions.items.isEmpty:
                suggestions.move(by: -1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                field.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? URLTextField else { return }
            parent.browser.addressTextChanged(field.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? URLTextField else { return }
            field.showSummary()
            field.onFocusChange?(false)
            // A click on a suggestion ends editing first; keep the list until that click lands.
            let suggestions = parent.browser.suggestions
            if NSEvent.pressedMouseButtons == 0 {
                suggestions.clear()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { suggestions.clear() }
            }
        }
    }
}

final class URLTextField: NSTextField {
    var url: URL?
    var onFocusChange: ((Bool) -> Void)?

    var isEditing: Bool { currentEditor() != nil }

    override func becomeFirstResponder() -> Bool {
        stringValue = url?.absoluteString ?? ""
        alignment = .left
        let accepted = super.becomeFirstResponder()
        if accepted {
            // Deferred so it lands after the click's own caret placement.
            perform(#selector(selectEverything), with: nil, afterDelay: 0)
            onFocusChange?(true)
        }
        return accepted
    }

    @objc private func selectEverything() {
        currentEditor()?.selectAll(nil)
    }

    func showSummary() {
        alignment = .center
        guard let url else {
            stringValue = ""
            return
        }
        if let host = url.host(), ["http", "https"].contains(url.scheme) {
            stringValue = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        } else {
            stringValue = url.absoluteString
        }
    }
}
