import SwiftUI
@preconcurrency import Translation

/// The selected text, translated on the Mac by Apple's Translation, in the context menu's popover.
struct TranslationPanel: View {
    let text: String
    @State var target: Locale.Language
    @State private var state = TranslationState.working
    @State private var languages: [Locale.Language] = []

    private enum TranslationState {
        case working
        case translated(String, from: Locale.Language)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Translation").font(Theme.font(15, .semibold))
                languageLine
            }
            switch state {
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Translating…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            case .translated(let translation, _):
                ScrollView {
                    Text(translation)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Text("Translated on this Mac.").font(Theme.font(11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(translation, forType: .string)
                    }
                    .controlSize(.small)
                }
            case .failed(let message):
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Theme.font(13))
        .padding(16)
        .frame(width: 340)
        .task { languages = await LanguageAvailability().supportedLanguages.sorted { Self.name(of: $0) < Self.name(of: $1) } }
        .translationTask(TranslationSession.Configuration(target: target)) { session in
            state = .working
            do {
                let response = try await session.translate(text)
                state = .translated(response.targetText, from: response.sourceLanguage)
            } catch {
                state = .failed("This text couldn’t be translated into \(Self.name(of: target)).")
            }
        }
    }

    private var languageLine: some View {
        HStack(spacing: 4) {
            if case .translated(_, let source) = state {
                Text("\(Self.name(of: source)) to").foregroundStyle(.secondary)
            }
            Menu(Self.name(of: target)) {
                ForEach(languages, id: \.minimalIdentifier) { language in
                    Button(Self.name(of: language)) { target = language }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
        }
        .font(Theme.font(12))
    }

    /// "French" for fr-US, as the region doesn't change the translation; "Chinese (Taiwan)" does.
    private static func name(of language: Locale.Language) -> String {
        let identifier = language.languageCode == "zh" ? language.minimalIdentifier : language.languageCode?.identifier
        return identifier.flatMap { Locale.current.localizedString(forIdentifier: $0) } ?? language.minimalIdentifier
    }
}
