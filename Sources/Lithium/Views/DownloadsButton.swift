import SwiftUI

/// Toolbar button with a progress ring while files download; opens the list of the session's downloads.
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
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.accentColor.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction ?? 0.25)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(fraction == nil && spin ? 270 : -90))
                .animation(fraction == nil ? .linear(duration: 1).repeatForever(autoreverses: false) : .easeOut(duration: 0.2), value: spin)
                .animation(.easeOut(duration: 0.2), value: fraction)
        }
        .onAppear { spin = true }
    }
}

private struct DownloadsList: View {
    private let downloads = Downloads.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(Theme.font(15, .semibold))
                Spacer()
                Button("Clear") { downloads.clearFinished() }
                    .disabled(downloads.items.allSatisfy { $0.state == .downloading })
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()
            if downloads.items.isEmpty {
                Text("Files you download appear here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(downloads.items) { DownloadRow(item: $0) }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
            }
            Divider()
            Button {
                NSWorkspace.shared.open(URL.downloadsDirectory)
            } label: {
                HStack(spacing: 6) {
                    Icon(.folder, size: 14)
                    Text("Open Downloads Folder")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(12)
        }
        .font(Theme.font(13))
        .frame(width: 360)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: fileIcon)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
                RowButton(icon: .search, help: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if item.state == .finished, let destination = item.destination { NSWorkspace.shared.open(destination) }
        }
    }

    private var fileIcon: NSImage {
        if let destination = item.destination, FileManager.default.fileExists(atPath: destination.path) {
            return NSWorkspace.shared.icon(forFile: destination.path)
        }
        return NSWorkspace.shared.icon(for: .data)
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
