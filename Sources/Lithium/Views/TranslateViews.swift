import SwiftUI

/// The address bar's offer to translate a page in another language, and its state once translated.
struct TranslateButton: View {
    let tab: Tab
    @Environment(Browser.self) private var browser
    @State private var isPresented = false

    /// Offered until put away; translating, translated or failed, it stays, for Show Original.
    static func isShown(for tab: Tab) -> Bool {
        guard let state = tab.pageTranslation, tab.canTranslate else { return false }
        return state.status != .offered || !state.isDismissed
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            TranslateButtonLabel(status: tab.pageTranslation?.status ?? .offered)
        }
        .buttonStyle(.plain)
        .help(tab.pageTranslation?.isActive == true ? "Translated" : "Translate page")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TranslatePanel(tab: tab, isPresented: $isPresented)
        }
        .onChange(of: tab.id) { isPresented = false }
    }
}

struct TranslateButtonLabel: View {
    let status: TabTranslation.Status

    var body: some View {
        if status == .downloading || status == .translating {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 22, height: 22)
        } else {
            ReaderButtonLabel(icon: .translate, isOn: status == .translated)
        }
    }
}

private struct TranslatePanel: View {
    let tab: Tab
    @Binding var isPresented: Bool
    @Environment(Browser.self) private var browser
    /// The choices as last set here: saved in the defaults, which SwiftUI doesn't watch.
    @State private var always: Bool?
    @State private var never: Bool?

    var body: some View {
        let translator = browser.translator
        if let state = tab.pageTranslation {
            let site = PageTranslator.site(of: tab.url)
            TranslateView(
                state: state,
                site: site,
                alwaysTranslates: Binding(
                    get: { always ?? translator.alwaysTranslates(state.source, privateSession: tab.privateSession) },
                    set: { value in
                        always = value
                        translator.setAlwaysTranslates(value, state.source, privateSession: tab.privateSession)
                        if value, !state.isActive { Task { await translator.translate(tab) } }
                    }
                ),
                neverTranslates: Binding(
                    get: { never ?? translator.neverTranslates(tab.url, privateSession: tab.privateSession) },
                    set: { value in
                        never = value
                        translator.setNeverTranslates(value, site: site ?? "", privateSession: tab.privateSession)
                    }
                ),
                onTranslate: { Task { await translator.translate(tab) } },
                onShowOriginal: { translator.showOriginal(tab) },
                onDismiss: {
                    tab.pageTranslation?.isDismissed = true
                    isPresented = false
                }
            )
        }
    }
}

/// The translate popover from plain values, so it also draws without a tab.
struct TranslateView: View {
    let state: TabTranslation
    let site: String?
    @Binding var alwaysTranslates: Bool
    @Binding var neverTranslates: Bool
    var onTranslate: () -> Void = {}
    var onShowOriginal: () -> Void = {}
    var onDismiss: () -> Void = {}

    var body: some View {
        let source = PageTranslator.name(of: state.source)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Translation").font(Theme.font(15, .semibold))
                Text("\(source) to \(PageTranslator.name(of: state.target))").font(Theme.font(12)).foregroundStyle(.secondary)
            }
            switch state.status {
            case .offered:
                HStack {
                    Button("Translate", action: onTranslate).keyboardShortcut(.defaultAction)
                    Spacer(minLength: 8)
                    Button("Not now", action: onDismiss)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            case .downloading:
                progress("Downloading \(source)…", detail: "macOS asks before it downloads the language.")
            case .translating:
                progress("Translating…", detail: nil)
            case .translated:
                Button("Show original", action: onShowOriginal)
            case .failed(let message):
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Try again", action: onTranslate)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Always translate \(source)", isOn: $alwaysTranslates)
                if site != nil {
                    Toggle("Never translate this site", isOn: $neverTranslates)
                }
            }
            .toggleStyle(.checkbox)
            Text("Translated on this Mac.")
                .font(Theme.font(11))
                .foregroundStyle(.secondary)
        }
        .font(Theme.font(13))
        .padding(16)
        .frame(width: 260)
    }

    private func progress(_ text: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).foregroundStyle(.secondary)
                if let detail {
                    Text(detail).font(Theme.font(11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
