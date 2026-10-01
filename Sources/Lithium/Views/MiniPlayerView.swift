import SwiftUI

/// The bottom of the sidebar: what the last tab heard plays, with its controls. Clicking the
/// picture or the title goes to the tab.
struct MiniPlayer: View {
    let nowPlaying: NowPlaying
    let tab: Tab
    let media: NowPlaying.Media
    @Environment(\.sidebarPalette) private var palette
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Artwork(url: media.artwork, tab: tab)
                VStack(alignment: .leading, spacing: 1) {
                    Text(media.title ?? tab.displayTitle)
                        .font(Theme.font(12, .medium))
                    if let artist = media.artist {
                        Text(artist)
                            .font(Theme.font(11))
                            .opacity(0.6)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovered ? palette.hover : .clear))
            .contentShape(Rectangle())
            .onTapGesture { nowPlaying.showTab() }
            .onHover { isHovered = $0 }
            .help("Show \(tab.displayTitle)")
            // Counted on between the page's reports, and only while it plays.
            TimelineView(.animation(minimumInterval: 0.5, paused: media.isPaused)) { context in
                Progress(media: media, time: media.elapsed(at: context.date))
            }
            .padding(.horizontal, 4)
            HStack(spacing: 4) {
                PlayerButton(symbol: "backward.end.fill", size: 11, help: "Previous") { nowPlaying.previous() }
                    .disabled(!media.hasPrevious)
                PlayerButton(symbol: media.isPaused ? "play.fill" : "pause.fill", size: 15, help: media.isPaused ? "Play" : "Pause") {
                    nowPlaying.togglePlay()
                }
                PlayerButton(symbol: "forward.end.fill", size: 11, help: "Next") { nowPlaying.next() }
                    .disabled(!media.hasNext)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.tile))
    }
}

private struct Artwork: View {
    let url: URL?
    let tab: Tab
    @Environment(\.sidebarPalette) private var palette

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(palette.field)
            .frame(width: 36, height: 36)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Favicon(image: tab.favicon, fallback: tab.url?.host() ?? "", size: 18)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A thin bar between the time played and the length; a live stream has neither.
private struct Progress: View {
    let media: NowPlaying.Media
    let time: Double
    @Environment(\.sidebarPalette) private var palette

    var body: some View {
        if let duration = media.duration {
            HStack(spacing: 6) {
                Text(PlaybackTime.format(time))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.ink.opacity(0.15))
                        Capsule().fill(palette.ink.opacity(0.7))
                            .frame(width: proxy.size.width * min(max(time / duration, 0), 1))
                    }
                    .frame(height: 3)
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 10)
                Text(PlaybackTime.format(duration))
            }
            .font(Theme.font(10, .medium))
            .monospacedDigit()
            .opacity(0.7)
        } else {
            Text("Live")
                .font(Theme.font(10, .semibold))
                .opacity(0.6)
        }
    }
}

private struct PlayerButton: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.sidebarPalette) private var palette
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 32, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered && isEnabled ? palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 0.85 : 0.3)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
