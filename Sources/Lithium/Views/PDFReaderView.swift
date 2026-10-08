import PDFKit
import SwiftUI

/// Lithium's PDF viewer, over the tab's web view: a strip of controls, the pages or the outline
/// on the side, and the document.
struct PDFReaderView: View {
    let reader: PDFReader
    /// False on the split side the keyboard isn't on: its password prompt waits for it.
    var takesKeyboard = true
    @AppStorage(Preference.pdfSidebar) private var showsSidebar = true
    @State private var showsOutline = false

    var body: some View {
        VStack(spacing: 0) {
            PDFToolbar(reader: reader, showsSidebar: $showsSidebar)
            HStack(spacing: 0) {
                if showsSidebar, reader.pageCount > 0 {
                    PDFSidebar(reader: reader, showsOutline: $showsOutline)
                        .frame(width: 176)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Hairline(vertical: true)
                }
                ZStack {
                    PageContainer(view: reader.view)
                    if reader.isLocked {
                        PasswordPrompt(reader: reader, takesKeyboard: takesKeyboard)
                    }
                }
            }
            .animation(.snappy(duration: 0.2), value: showsSidebar)
        }
        .background(Color(nsColor: .pdfCanvas))
        // The page area sits on the window's own background, not the sidebar color, so it takes the system's ink.
        .foregroundStyle(Color.primary)
        .font(Theme.font(13))
    }
}

struct PDFToolbar: View {
    let reader: PDFReader
    @Binding var showsSidebar: Bool

    var body: some View {
        let isReady = reader.pageCount > 0
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                PDFButton(icon: .sidebar, help: showsSidebar ? "Hide Pages" : "Show Pages", isOn: showsSidebar && isReady) {
                    showsSidebar.toggle()
                }
                Text(reader.title)
                    .font(Theme.font(13, .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(reader.title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                PageField(reader: reader)
                Divider().frame(height: 18).padding(.horizontal, 6)
                PDFButton(icon: .minus, help: "Zoom Out (⌘-)") { reader.zoomOut() }
                ZoomMenu(reader: reader)
                PDFButton(icon: .plus, help: "Zoom In (⌘+)") { reader.zoomIn() }
                Divider().frame(height: 18).padding(.horizontal, 6)
                if reader.fit == .page {
                    PDFButton(icon: .fitWidth, help: "Fit to Width") { reader.setFit(.width) }
                } else {
                    PDFButton(icon: .fitPage, help: "Fit to Page") { reader.setFit(.page) }
                }
                PDFButton(icon: .reload, help: "Rotate") { reader.rotate() }
            }
            .fixedSize()
            .disabled(!isReady)
            .padding(.horizontal, 12)

            HStack(spacing: 2) {
                if reader.isLocalFile {
                    PDFButton(icon: .folder, help: "Show in Finder") { reader.showInFinder() }
                }
                PDFButton(icon: .download, help: "Download") { reader.download() }
                    .disabled(reader.document == nil)
                PDFButton(icon: .printer, help: "Print (⌘P)") { reader.print() }
                    .disabled(!isReady)
                MoreMenu(reader: reader)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) { Hairline(vertical: false) }
    }
}

/// The current page, typed over to jump, and the page count.
private struct PageField: View {
    let reader: PDFReader
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let digits = CGFloat(max(2, String(reader.pageCount).count))
        HStack(spacing: 6) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .frame(width: digits * 8 + 12, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                .focused($isFocused)
                .onSubmit {
                    if let number = Int(text.trimmingCharacters(in: .whitespaces)) { reader.goToPage(PDFReader.pageIndex(ofNumber: number)) }
                    text = "\(reader.pageIndex + 1)"
                    reader.view.window?.makeFirstResponder(reader.view)
                }
            Text("/ \(reader.pageCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .help("Go to page")
        .onChange(of: reader.pageIndex, initial: true) {
            if !isFocused { text = reader.pageCount > 0 ? "\(reader.pageIndex + 1)" : "" }
        }
        .onChange(of: reader.pageCount) { text = reader.pageCount > 0 ? "\(reader.pageIndex + 1)" : "" }
        // A number typed and left without Return goes back to the current page.
        .onChange(of: isFocused) { if !isFocused { text = reader.pageCount > 0 ? "\(reader.pageIndex + 1)" : "" } }
    }
}

private struct ZoomMenu: View {
    let reader: PDFReader
    @State private var isHovered = false

    var body: some View {
        Menu {
            Button("Fit to Width") { reader.setFit(.width) }
            Button("Fit to Page") { reader.setFit(.page) }
            Divider()
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4] as [CGFloat], id: \.self) { level in
                Button("\(Int(level * 100))%") { reader.setScale(level) }
            }
        } label: {
            Text("\(Int((reader.scale * 100).rounded()))%")
                .monospacedDigit()
                .frame(minWidth: 48, minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(isHovered ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help("Zoom")
    }
}

private struct MoreMenu: View {
    let reader: PDFReader

    var body: some View {
        Menu {
            Toggle("Two-Page View", isOn: Binding(get: { reader.isTwoUp }, set: { _ in reader.toggleTwoUp() }))
                .disabled(reader.pageCount == 0)
            Divider()
            Button("Open in Preview") { reader.openInPreview() }
                .disabled(!reader.canOpenInPreview)
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
        .help("More")
    }
}

/// Like the toolbar's buttons, drawn for the page area's own background.
private struct PDFButton: View {
    let icon: Phosphor
    let help: String
    var isOn = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 16)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isOn ? 0.09 : isHovered && isEnabled ? 0.06 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 0.85 : 0.3)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private struct Hairline: View {
    let vertical: Bool

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

private struct PDFSidebar: View {
    let reader: PDFReader
    @Binding var showsOutline: Bool

    var body: some View {
        let hasOutline = !reader.outline.isEmpty
        VStack(spacing: 0) {
            if hasOutline {
                HStack(spacing: 2) {
                    PDFButton(icon: .thumbnails, help: "Pages", isOn: !showsOutline) { showsOutline = false }
                    PDFButton(icon: .outline, help: "Outline", isOn: showsOutline) { showsOutline = true }
                }
                .padding(.vertical, 6)
                Hairline(vertical: false)
            }
            if hasOutline, showsOutline {
                OutlineList(reader: reader)
            } else {
                ThumbnailList(reader: reader)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct ThumbnailList: View {
    let reader: PDFReader

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(0..<reader.pageCount, id: \.self) { index in
                        Thumbnail(reader: reader, index: index, isCurrent: index == reader.pageIndex)
                            .id(index)
                            .onTapGesture { reader.goToPage(index) }
                    }
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: reader.pageIndex) {
                withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(reader.pageIndex) }
            }
            .onAppear { proxy.scrollTo(reader.pageIndex) }
        }
    }
}

private struct Thumbnail: View {
    let reader: PDFReader
    let index: Int
    let isCurrent: Bool
    @State private var image: NSImage?

    private static let maxSize = CGSize(width: 116, height: 150)

    var body: some View {
        let page = reader.document?.page(at: index)
        let size = Self.size(of: page)
        VStack(spacing: 6) {
            ZStack {
                Color.white
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            .padding(4)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2.5)
            )
            Text("\(index + 1)")
                .font(Theme.font(11, isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .task(id: reader.revision) {
            image = await reader.thumbnail(of: index, size: CGSize(width: size.width * 2, height: size.height * 2))
        }
    }

    /// The page's shape as shown, rotation included, fitted in the column.
    private static func size(of page: PDFPage?) -> CGSize {
        guard let page else { return maxSize }
        let box = page.bounds(for: .cropBox).size
        let shown = page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
        guard shown.width > 0, shown.height > 0 else { return maxSize }
        let scale = min(maxSize.width / shown.width, maxSize.height / shown.height)
        return CGSize(width: (shown.width * scale).rounded(), height: (shown.height * scale).rounded())
    }
}

private struct OutlineList: View {
    let reader: PDFReader

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                OutlineGroup(reader.outline, children: \.children) { entry in
                    OutlineRow(entry: entry) { reader.goToPage($0) }
                }
            }
            .padding(8)
        }
    }
}

private struct OutlineRow: View {
    let entry: PDFReader.OutlineEntry
    let go: (Int) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            if let page = entry.pageIndex { go(page) }
        } label: {
            Text(entry.label)
                .font(Theme.font(12.5))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(isHovered ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct PasswordPrompt: View {
    let reader: PDFReader
    let takesKeyboard: Bool
    @State private var password = ""
    @State private var isWrong = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            Icon(.lock, size: 26).opacity(0.6)
            Text("This PDF is protected").font(Theme.font(15, .semibold))
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($isFocused)
                .onSubmit {
                    isWrong = !reader.unlock(with: password)
                    password = ""
                }
            Text("Wrong password, try again.")
                .font(Theme.font(12))
                .foregroundStyle(.red.opacity(0.85))
                .opacity(isWrong ? 1 : 0)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        )
        // The document locks only once loaded, maybe while the user types on the other split side,
        // or in a field of the window (the address bar, the find bar, a tab's name): that keeps the keyboard.
        .onAppear { if takesKeyboard, !isEditingText(in: NSApp.keyWindow) { claimFocus($isFocused) } }
        .onChange(of: takesKeyboard) { if takesKeyboard { claimFocus($isFocused) } }
    }
}
