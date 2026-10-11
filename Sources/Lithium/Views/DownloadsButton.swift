import SwiftUI

struct DownloadsButton: View {
    private let downloads = Downloads.shared
    @State private var isPresented = false

    var body: some View {
        IconButton(icon: .download, help: "Downloads") {
            isPresented.toggle()
            downloads.hasUnseen = false
        }
        .overlay {
            if !downloads.active.isEmpty {
                ProgressRing(fraction: downloads.overallFraction)
                    .frame(width: 24, height: 24)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if downloads.hasUnseen, downloads.active.isEmpty {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: -3, y: 4)
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DownloadsList()
        }
    }
}

private struct ProgressRing: View {
    let fraction: Double?

    var body: some View {
        ZStack {
            Circle().stroke(Color.accentColor.opacity(0.18), lineWidth: 2)
            if let fraction {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: fraction)
            } else {
                Spinner()
            }
        }
    }
}

/// Its own view so it's removed once the size is known: a later animation doesn't cancel
/// a `repeatForever`, only removing the view that runs it does.
private struct Spinner: View {
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(spin ? 270 : -90))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

private struct DownloadsList: View {
    private let downloads = Downloads.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Downloads").font(Theme.font(15, .semibold))
                Text(subtitle).font(Theme.font(12)).foregroundStyle(.secondary)
            }
            if !downloads.items.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(downloads.items) { DownloadRow(item: $0) }
                    }
                }
                .frame(maxHeight: 360)
                .padding(.horizontal, -8)
            }
            Divider()
            HStack {
                Button("Open Downloads Folder") { ExternalApps.open(URL.downloadsDirectory) }
                Spacer()
                if downloads.items.contains(where: { $0.state != .downloading }) {
                    Button("Clear") { downloads.clearFinished() }
                }
            }
            .buttonStyle(.plain)
            .font(Theme.font(12))
            .foregroundStyle(Color.accentColor)
        }
        .font(Theme.font(13))
        .padding(16)
        .frame(width: 340)
        .onAppear { downloads.isListShown = true }
        .onDisappear { downloads.isListShown = false }
    }

    private var subtitle: String {
        let active = downloads.active.count
        if active > 0 { return active == 1 ? "1 file downloading" : "\(active) files downloading" }
        let count = downloads.items.count
        switch count {
        case 0: return "Files you download appear here."
        case 1: return "1 file"
        default: return "\(count) files"
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.fileIcon)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The site's name, crossed out, for a file Lithium named.
                if let original = item.originalFilename {
                    Text(original)
                        .strikethrough()
                        .font(Theme.font(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if item.state == .downloading {
                    ProgressView(value: item.fraction ?? 0)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Text(status)
                    .font(Theme.font(11))
                    .foregroundStyle(isFailure ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.state == .downloading {
                if item.canCancel { RowButton(icon: .close, help: "Cancel") { item.cancel() } }
            } else if item.state == .finished, let destination = item.destination {
                if item.canUseOriginalName {
                    RowButton(icon: .undo, help: "Use original name") { item.useOriginalName() }
                }
                RowButton(icon: .search, help: "Show in Finder") {
                    ExternalApps.reveal(destination)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if item.state == .finished, let destination = item.destination { ExternalApps.open(destination) }
        }
    }

    private var isFailure: Bool {
        if case .failed = item.state { return true }
        return false
    }

    private var status: String {
        let done = ByteCountFormatter.string(fromByteCount: item.completedBytes, countStyle: .file)
        switch item.state {
        case .downloading:
            guard item.totalBytes > 0 else { return done }
            return "\(done) of \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))"
        case .finished: return ByteCountFormatter.string(fromByteCount: max(item.totalBytes, item.completedBytes), countStyle: .file)
        case .failed(let message): return message
        case .cancelled: return "Cancelled"
        }
    }
}

private struct RowButton: View {
    let icon: Phosphor
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 14)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
