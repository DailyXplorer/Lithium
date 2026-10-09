import SwiftUI

struct ReaderButtons: View {
    let tab: Tab
    @Environment(Browser.self) private var browser
    @State private var showsStyle = false

    /// On pages that look like articles, and in the reader.
    static func isShown(for tab: Tab) -> Bool {
        tab.isReading || tab.isReaderAvailable
    }

    var body: some View {
        HStack(spacing: 0) {
            if tab.isReading {
                Button { showsStyle.toggle() } label: {
                    ReaderButtonLabel(icon: .readerStyle, isOn: false)
                }
                .buttonStyle(.plain)
                .help("Text and colors")
                .popover(isPresented: $showsStyle, arrowEdge: .bottom) {
                    ReaderStylePopover()
                }
            }
            Button { browser.toggleReader(tab) } label: {
                ReaderButtonLabel(icon: .reader, isOn: tab.isReading)
            }
            .buttonStyle(.plain)
            .help(tab.isReading ? "Hide reader (⇧⌘R)" : "Show reader (⇧⌘R)")
        }
    }
}

struct ReaderButtonLabel: View {
    let icon: Phosphor
    let isOn: Bool
    @Environment(\.sidebarPalette) private var palette
    @State private var isHovered = false

    var body: some View {
        Icon(icon, size: 15)
            .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .opacity(isOn ? 1 : 0.6)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(isHovered ? palette.hover : .clear))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

/// Reads the saved style when opened, and saves each change at once.
private struct ReaderStylePopover: View {
    @Environment(Browser.self) private var browser
    @State private var style = ReaderStyle.saved

    var body: some View {
        ReaderStyleView(style: $style)
            .onChange(of: style) { browser.setReaderStyle(style) }
    }
}

/// From plain values, so it also draws without a browser.
struct ReaderStyleView: View {
    @Binding var style: ReaderStyle

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 2) {
                IconButton(icon: .minus, help: "Smaller text", isEnabled: style.size > ReaderStyle.sizes.lowerBound) {
                    style.size = max(style.size - ReaderStyle.sizeStep, ReaderStyle.sizes.lowerBound)
                }
                Text("Aa")
                    .font(Theme.font(CGFloat(style.size - 4), .medium))
                    .frame(maxWidth: .infinity)
                IconButton(icon: .plus, help: "Larger text", isEnabled: style.size < ReaderStyle.sizes.upperBound) {
                    style.size = min(style.size + ReaderStyle.sizeStep, ReaderStyle.sizes.upperBound)
                }
            }
            .frame(height: 30)
            HStack(spacing: 10) {
                ForEach(ReaderStyle.Theme.allCases) { theme in
                    ThemeSwatch(theme: theme, isSelected: style.theme == theme) { style.theme = theme }
                }
            }
            Picker("Font", selection: $style.font) {
                ForEach(ReaderStyle.Font.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .font(Theme.font(13))
        .padding(12)
        .frame(width: 210)
    }
}

private struct ThemeSwatch: View {
    let theme: ReaderStyle.Theme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            fill
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                .padding(3)
                .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(theme.label)
    }

    /// Match system is half light, half dark.
    @ViewBuilder private var fill: some View {
        switch theme {
        case .auto:
            HStack(spacing: 0) {
                Self.color(.light)
                Self.color(.dark)
            }
        default:
            Self.color(theme)
        }
    }

    /// The page colors of `reader.css`.
    private static func color(_ theme: ReaderStyle.Theme) -> Color {
        switch theme {
        case .sepia: Color(red: 0xF5 / 255, green: 0xEE / 255, blue: 0xE1 / 255)
        case .dark: Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x20 / 255)
        default: .white
        }
    }
}
