import SwiftUI

struct AddressBarBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

struct SuggestionList: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let suggestions = browser.suggestions
        VStack(spacing: 2) {
            ForEach(Array(suggestions.items.enumerated()), id: \.element.id) { index, suggestion in
                SuggestionRow(suggestion: suggestion, isSelected: index == suggestions.selectedIndex)
                    .contentShape(Rectangle())
                    // Every move, not only on entering: a row that came up under the pointer is
                    // picked once the pointer moves within it.
                    .onContinuousHover { if case .active = $0 { suggestions.hover(suggestion) } }
                    .onTapGesture { browser.accept(suggestion) }
            }
        }
        .padding(6)
        // Same surface as the focused address field, so the list reads as its continuation.
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
        .font(Theme.font(13))
        .foregroundStyle(.primary)
    }
}

private struct SuggestionRow: View {
    let suggestion: Suggestion
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 18, height: 18)
            Text(title)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(Theme.font(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            if let badge {
                Text(badge)
                    .font(Theme.font(11, .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        )
    }

    @ViewBuilder private var leading: some View {
        switch suggestion {
        case .search:
            Icon(.search, size: 15)
        case .address, .openTab, .pin, .history:
            if let image = Favicons.shared.cached(host: suggestion.url?.host()) {
                Favicon(image: image, fallback: "", size: 16)
            } else {
                Icon(suggestion.isHistory ? .history : .globe, size: 15)
            }
        }
    }

    private var title: String {
        switch suggestion {
        case .search(let query): query
        case .address(let url): url.absoluteString
        case .openTab(_, let title, let url), .pin(_, let title, let url), .history(let title, let url):
            title.isEmpty ? (url.host() ?? url.absoluteString) : title
        }
    }

    private var detail: String? {
        switch suggestion {
        case .search: "Search with \(SearchEngine.current.name)"
        case .address: nil
        case .openTab(_, _, let url), .pin(_, _, let url), .history(_, let url):
            url.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        }
    }

    private var badge: String? {
        switch suggestion {
        case .openTab: "Switch to Tab"
        case .pin: "Pinned"
        default: nil
        }
    }
}

private extension Suggestion {
    var isHistory: Bool {
        if case .history = self { return true }
        return false
    }
}
