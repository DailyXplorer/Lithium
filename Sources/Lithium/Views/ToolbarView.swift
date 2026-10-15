import SwiftUI

struct ToolbarView: View {
    @Environment(Browser.self) private var browser
    @Environment(BrowserWindow.self) private var window

    var body: some View {
        let tab = window.selectedTab
        HStack(spacing: 2) {
            if !window.showsSidebar {
                SidebarToggle()
            }
            IconButton(icon: .back, help: "Back (⌘[)", isEnabled: tab?.canGoBack == true) {
                browser.navigate(tab, .back)
            }
            IconButton(icon: .forward, help: "Forward (⌘])", isEnabled: tab?.canGoForward == true) {
                browser.navigate(tab, .forward)
            }
            IconButton(
                icon: tab?.isLoading == true ? .close : .reload,
                help: tab?.isLoading == true ? "Stop" : "Reload (⌘R)",
                isEnabled: tab?.url != nil
            ) {
                browser.navigate(tab, tab?.isLoading == true ? .stop : .reload)
            }
            Spacer(minLength: 16)
            AddressBar(tab: tab)
                .frame(maxWidth: 560)
            Spacer(minLength: 16)
            // Only while an agent is connected, for its Stop; otherwise in the ⋯ menu.
            if let agent = browser.agent, agent.isConnected {
                AgentButton(agent: agent)
            }
            ExtensionsButton(tab: tab)
            DownloadsButton()
            SummaryButton(tab: tab)
            CaptureButton()
            PageMenu(tab: tab)
        }
        .padding(.horizontal, Layout.margin)
    }
}

private struct AddressBar: View {
    let tab: Tab?
    @Environment(Browser.self) private var browser
    @Environment(BrowserWindow.self) private var window
    @Environment(\.sidebarPalette) private var palette
    @State private var isEditing = false
    @State private var showsZoom = false

    var body: some View {
        HStack(spacing: 4) {
            if !isEditing, let tab, let scheme = tab.url?.scheme, ["http", "https"].contains(scheme) {
                ConnectionButton(tab: tab, isSecure: tab.connection == .secure)
            } else {
                Icon(.search, size: 15)
                    .opacity(0.5)
                    .frame(width: 22, height: 22)
            }
            AddressField(
                url: tab?.url,
                focusToken: window.addressFocusToken,
                pickToken: window.tabPickToken,
                isEditing: $isEditing,
                onDarkBackground: palette.isDark,
                window: window
            )
            if !isEditing, let tab, TranslateButton.isShown(for: tab) {
                TranslateButton(tab: tab)
            }
            if !isEditing, let tab, ReaderButtons.isShown(for: tab) {
                ReaderButtons(tab: tab)
            }
            if !isEditing, let tab, ZoomPill.isShown(for: tab, isPresented: showsZoom) {
                ZoomPill(tab: tab, isPresented: $showsZoom)
            }
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

private struct ShieldPanel: View {
    let tab: Tab?
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let privacy = browser.privacy
        ShieldView(
            host: Privacy.siteHost(tab?.url) ?? "",
            isOn: Binding(
                get: { privacy.isEnabled(for: tab?.url, privateSession: tab?.privateSession, space: tab?.siteSpace) },
                set: { browser.setProtections($0, for: tab) }
            ),
            updated: privacy.filtersUpdated,
            onOpenSettings: {
                dismiss()
                browser.openSettings(section: "privacy")
            }
        )
    }
}

/// The shield's panel from plain values, so it also draws without a browser.
struct ShieldView: View {
    let host: String
    @Binding var isOn: Bool
    let updated: Date?
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Protections").font(Theme.font(15, .semibold))
                Text(host).font(Theme.font(12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On for this site")
                    Text("Blocks ads and trackers")
                        .font(Theme.font(11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("On for this site", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Divider()
            HStack {
                if let updated {
                    Text("Updated \(updated.formatted(date: .abbreviated, time: .omitted))")
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Button("Settings…", action: onOpenSettings)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
            .font(Theme.font(11))
        }
        .font(Theme.font(13))
        .padding(16)
        .frame(width: 260)
    }
}

/// What an item of the ⋯ menu opens: a menu can't hold a popover, so it opens from the ⋯ button.
enum PageMenuPanel: Hashable, Identifiable {
    case qrCode(URL)
    case protections
    case agents
    var id: Self { self }
}

private struct PageMenu: View {
    let tab: Tab?
    @Environment(Browser.self) private var browser
    @State private var panel: PageMenuPanel?

    var body: some View {
        Menu {
            PageMenuItems(tab: tab, panel: $panel)
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
        .popover(item: $panel, arrowEdge: .bottom) { panel in
            switch panel {
            case .qrCode(let url): QRCodeView(url: url)
            case .protections: ShieldPanel(tab: tab)
            case .agents: if let agent = browser.agent { AgentPanel(agent: agent) }
            }
        }
    }
}

/// The ⋯ menu's items, apart so a test can draw them.
struct PageMenuItems: View {
    let tab: Tab?
    @Binding var panel: PageMenuPanel?
    @Environment(Browser.self) private var browser
    @Environment(BrowserWindow.self) private var window

    var body: some View {
        Button("Copy Link") {
            guard let url = tab?.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        .disabled(tab?.url == nil)
        Button("QR Code for This Page") { panel = tab?.url.map(PageMenuPanel.qrCode) }
            .disabled(tab?.url?.scheme?.hasPrefix("http") != true)
        Button("Site Protections…") { panel = .protections }
            .disabled(tab?.url?.scheme?.hasPrefix("http") != true)
        Button(tab?.pinID == nil ? "Pin Tab" : "Unpin Tab") {
            window.togglePinForSelectedTab()
        }
        .disabled(tab?.url == nil || tab?.isEphemeral == true)
        Button(tab?.pageTranslation?.isActive == true ? "Show Original" : "Translate Page") { browser.toggleTranslation(tab) }
            .disabled(tab?.canTranslate != true)
        Button("Pop Out Video") { window.videoPopout.showSelected() }
            .disabled(!window.videoPopout.canShowSelected)
        // Checked while it is on, whatever the setting: the toolbar shows no indicator for it.
        Toggle("Energy Saving", isOn: Binding(get: { browser.energy.isOn }, set: { browser.turnEnergySaving(on: $0) }))
        Divider()
        Button("Show All History") { browser.openHistory(in: window) }
        Button("Extensions") { browser.openSettings(section: "extensions", in: window) }
        Button("Agents") {
            if browser.agent == nil { browser.openSettings(section: "agents", in: window) } else { panel = .agents }
        }
        Divider()
        Button("Settings…") { browser.openSettings(in: window) }
    }
}

/// AppKit text field so a click selects the whole URL, Escape restores it, and ⌘L/⌘T can focus it.
private struct AddressField: NSViewRepresentable {
    let url: URL?
    let focusToken: Int
    let pickToken: Int
    @Binding var isEditing: Bool
    let onDarkBackground: Bool
    let window: BrowserWindow

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
        field.onFocusChange = { editing in
            let coordinator = context.coordinator
            let window = coordinator.parent.window
            if editing {
                window.suggestions.editedTabID = window.selectedTabID
                window.suggestions.editingBegan()
            }
            coordinator.parent.isEditing = editing
            window.isEditingAddress = editing
        }
        context.coordinator.focusToken = focusToken
        context.coordinator.pickToken = pickToken
        return field
    }

    func updateNSView(_ field: URLTextField, context: Context) {
        context.coordinator.parent = self
        // Another tab was picked: the edit ends so Return can't send it to the old tab. Queued
        // before a focus request of the same change (⌘T), which wins.
        if context.coordinator.pickToken != pickToken {
            context.coordinator.pickToken = pickToken
            DispatchQueue.main.async { [window] in
                guard field.isEditing else { return }
                field.window?.makeFirstResponder(nil)
                window.returnKeyboardToPage(fieldHadKeyboard: true)
            }
        }
        field.textColor = onDarkBackground && !isEditing ? .white : .labelColor
        if let font = Theme.nsFont(13), field.font != font { field.font = font }
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
        var pickToken = 0

        init(_ parent: AddressField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? URLTextField else { return false }
            let suggestions = parent.window.suggestions
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Submit before resigning: ending the edit clears the suggestions being read.
                parent.window.submitAddress(field.stringValue, editing: suggestions.editedTabID)
                field.window?.makeFirstResponder(nil)
                // Left on the window, keys beep and the page can't scroll until clicked.
                parent.window.returnKeyboardToPage(fieldHadKeyboard: true)
                return true
            case #selector(NSResponder.moveDown(_:)) where !suggestions.items.isEmpty:
                suggestions.move(by: 1)
                return true
            case #selector(NSResponder.moveUp(_:)) where !suggestions.items.isEmpty:
                suggestions.move(by: -1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                field.window?.makeFirstResponder(nil)
                parent.window.returnKeyboardToPage(fieldHadKeyboard: true)
                return true
            default:
                return false
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? URLTextField else { return }
            parent.window.addressTextChanged(field.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? URLTextField else { return }
            field.showSummary()
            field.onFocusChange?(false)
            // A click on a suggestion ends editing first; keep the list until that click lands.
            let suggestions = parent.window.suggestions
            if NSEvent.pressedMouseButtons == 0 {
                suggestions.clear()
            } else {
                suggestions.clearAfterMouseUp()
                DispatchQueue.main.async { [weak field] in suggestions.focusSettled(on: field?.window?.firstResponder) }
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
