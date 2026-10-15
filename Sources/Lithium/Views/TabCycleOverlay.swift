import SwiftUI

/// The tabs Control-Tab goes through, most recently shown first, while Control is held.
struct TabCycleLayer: View {
    @Environment(Browser.self) private var browser
    @Environment(BrowserWindow.self) private var window

    var body: some View {
        let recent = window.recentTabs
        if !recent.cycle.isEmpty {
            TabCycleOverlay(
                rows: recent.cycle.map { TabCycleOverlay.Row(id: $0.id, icon: $0.favicon, host: $0.url?.host() ?? "", title: $0.displayTitle) },
                highlighted: recent.cycleIndex
            )
        }
    }
}

struct TabCycleOverlay: View {
    struct Row: Identifiable {
        let id: UUID
        let icon: NSImage?
        let host: String
        let title: String
    }

    let rows: [Row]
    let highlighted: Int
    private static let visible = 10

    var body: some View {
        // A window of rows around the highlighted one, so a long list stays small.
        let start = max(0, min(highlighted - Self.visible / 2, rows.count - Self.visible))
        VStack(spacing: 2) {
            ForEach(Array(rows.enumerated().dropFirst(start).prefix(Self.visible)), id: \.element.id) { index, row in
                HStack(spacing: 10) {
                    Favicon(image: row.icon, fallback: row.host, size: 16)
                        .frame(width: 18, height: 18)
                    Text(row.title.isEmpty ? row.host : row.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(index == highlighted ? Color.accentColor.opacity(0.14) : .clear)
                )
            }
        }
        .padding(6)
        .frame(width: 360)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .font(Theme.font(13))
        .foregroundStyle(.primary)
        .allowsHitTesting(false)
    }
}
