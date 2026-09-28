import AppKit
import Observation
import PDFKit
import UniformTypeIdentifiers
import WebKit

/// A PDF shown in a tab. WebKit loads the file as usual, so its address, reload and history stay
/// the file's own; Lithium then takes the bytes WebKit received and draws the document itself with
/// PDFKit, over WebKit's viewer. Without the two WebKit calls this relies on, WebKit's viewer stays.
@MainActor
@Observable
final class PDFReader: NSObject {
    enum Fit {
        case width, page
    }

    struct OutlineEntry: Identifiable {
        let id: Int
        let label: String
        let pageIndex: Int?
        let children: [OutlineEntry]?
    }

    let url: URL
    private(set) var document: PDFDocument?
    private(set) var isLocked = false
    private(set) var pageIndex = 0
    private(set) var pageCount = 0
    private(set) var scale: CGFloat = 1
    private(set) var fit: Fit? = .width
    private(set) var isTwoUp = false
    private(set) var outline: [OutlineEntry] = []
    /// Bumped when pages change how they look (rotation), so thumbnails redraw.
    private(set) var revision = 0

    @ObservationIgnored let view = ReaderView()
    @ObservationIgnored var onOpenLink: ((URL, _ inNewTab: Bool) -> Void)?
    @ObservationIgnored private var data: Data?
    @ObservationIgnored private var matches: [PDFSelection] = []
    @ObservationIgnored private var fittedScale: CGFloat = 0
    /// Where to open once the view has a size: before that, PDFKit scrolls to the wrong place.
    @ObservationIgnored private var openingPage: Int?

    /// The tab's icon when the site has none, as for a file on disk.
    static let icon = NSWorkspace.shared.icon(for: .pdf)

    static let zoomLevels: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]

    init(url: URL) {
        self.url = url
        super.init()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        view.backgroundColor = .pdfCanvas
        view.delegate = self
        view.onResize = { [weak self] in self?.resized() }
        NotificationCenter.default.addObserver(self, selector: #selector(pageDidChange), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleDidChange), name: .PDFViewScaleChanged, object: view)
    }

    // MARK: Loading

    /// WebKit's own answer to "is the main frame a PDF", right from commit, including pages
    /// restored from the back-forward cache, which never ask for a navigation response.
    static func isShowingPDF(_ webView: WKWebView) -> Bool {
        let key = "_isDisplayingPDF"
        guard webView.responds(to: NSSelectorFromString(key)) else { return false }
        return (webView.value(forKey: key) as? Bool) == true
    }

    /// The bytes WebKit received for the main frame, without a second request.
    static func mainResourceData(of webView: WKWebView) async -> Data? {
        let selector = NSSelectorFromString("_getMainResourceDataWithCompletionHandler:")
        guard webView.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector, @escaping @convention(block) (NSData?, NSError?) -> Void) -> Void
        let getter = unsafeBitCast(webView.method(for: selector), to: Getter.self)
        return await withCheckedContinuation { continuation in
            getter(webView, selector) { data, _ in continuation.resume(returning: data as Data?) }
        }
    }

    /// False when the bytes are not a PDF PDFKit can read; the tab then keeps WebKit's viewer.
    func open(_ data: Data) -> Bool {
        guard let document = PDFDocument(data: data) else { return false }
        self.data = data
        self.document = document
        isLocked = document.isLocked
        if !isLocked { show(document) }
        return true
    }

    func unlock(with password: String) -> Bool {
        guard let document, document.unlock(withPassword: password) else { return false }
        isLocked = false
        show(document)
        return true
    }

    private func show(_ document: PDFDocument) {
        view.document = document
        pageCount = document.pageCount
        outline = document.outlineRoot.map { Self.entries(of: $0, in: document) } ?? []
        // Links like file.pdf#page=3, as in Chrome and Safari.
        let fragment = url.fragment() ?? ""
        openingPage = fragment.hasPrefix("page=") ? (Int(fragment.dropFirst(5)) ?? 1) - 1 : 0
        goToOpeningPage()
        pageDidChange()
    }

    private static func entries(of parent: PDFOutline, in document: PDFDocument, id: inout Int) -> [OutlineEntry] {
        (0..<parent.numberOfChildren).compactMap { index in
            guard let child = parent.child(at: index) else { return nil }
            id += 1
            let entryID = id
            let children = entries(of: child, in: document, id: &id)
            return OutlineEntry(
                id: entryID,
                label: child.label ?? "",
                pageIndex: child.destination?.page.map(document.index(for:)),
                children: children.isEmpty ? nil : children
            )
        }
    }

    private static func entries(of root: PDFOutline, in document: PDFDocument) -> [OutlineEntry] {
        var id = 0
        return entries(of: root, in: document, id: &id)
    }

    /// The document's own title, or its file name, as Chrome shows it.
    var title: String {
        let metadata = document?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        if let metadata = metadata?.trimmingCharacters(in: .whitespacesAndNewlines), !metadata.isEmpty { return metadata }
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? (url.host() ?? "PDF") : name
    }

    var filename: String {
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(".pdf") { return name }
        return title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".pdf"
    }

    // MARK: Navigation and zoom

    func goToPage(_ index: Int) {
        guard let page = document?.page(at: min(max(index, 0), pageCount - 1)) else { return }
        view.go(to: page)
    }

    func setFit(_ fit: Fit) {
        self.fit = fit
        refit()
    }

    func setScale(_ scale: CGFloat) {
        fit = nil
        view.autoScales = false
        view.scaleFactor = min(max(scale, Self.zoomLevels[0]), Self.zoomLevels.last!)
    }

    func zoomIn() {
        setScale(Self.zoomLevels.first { $0 > scale + 0.005 } ?? Self.zoomLevels.last!)
    }

    func zoomOut() {
        setScale(Self.zoomLevels.last { $0 < scale - 0.005 } ?? Self.zoomLevels[0])
    }

    func rotate() {
        guard let document else { return }
        let page = view.currentPage
        for index in 0..<document.pageCount {
            document.page(at: index)?.rotation += 90
        }
        view.layoutDocumentView()
        refit()
        if let page { view.go(to: page) }
        revision += 1
    }

    func toggleTwoUp() {
        isTwoUp.toggle()
        view.displayMode = isTwoUp ? .twoUpContinuous : .singlePageContinuous
        refit()
    }

    private func goToOpeningPage() {
        guard let page = openingPage, view.bounds.width > 0, view.bounds.height > 0 else { return }
        openingPage = nil
        view.layoutDocumentView()
        goToPage(page)
    }

    private func resized() {
        refit()
        goToOpeningPage()
    }

    private func refit() {
        switch fit {
        case .width:
            view.autoScales = true
        case .page:
            guard let page = view.currentPage else { return }
            let box = page.bounds(for: view.displayBox).size
            let size = page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
            let columns: CGFloat = isTwoUp ? 2 : 1
            let margin: CGFloat = 16
            let available = CGSize(width: view.bounds.width - margin * (columns + 1), height: view.bounds.height - margin * 2)
            guard available.width > 0, available.height > 0 else { return }
            view.autoScales = false
            fittedScale = min(available.width / (size.width * columns), available.height / size.height)
            view.scaleFactor = fittedScale
            view.go(to: page)
        case nil:
            break
        }
    }

    @objc private func pageDidChange() {
        guard let document, let page = view.currentPage else { return }
        pageIndex = document.index(for: page)
    }

    /// A pinch or a scroll-wheel zoom leaves the fit mode, as in Chrome.
    @objc private func scaleDidChange() {
        scale = view.scaleFactor
        switch fit {
        case .width where !view.autoScales: fit = nil
        case .page where abs(view.scaleFactor - fittedScale) > 0.001: fit = nil
        default: break
        }
    }

    // MARK: Find

    /// Highlights every match and returns how many there are.
    func find(_ query: String) -> Int {
        guard let document, !isLocked else { return 0 }
        matches = document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        for match in matches { match.color = Self.matchColor }
        view.highlightedSelections = matches
        return matches.count
    }

    private static let matchColor = NSColor.findHighlightColor.withAlphaComponent(0.5)
    private static let currentMatchColor = NSColor.systemOrange.withAlphaComponent(0.8)

    /// The current match stands out from the others, as in Chrome.
    func showMatch(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        for (position, match) in matches.enumerated() {
            match.color = position == index ? Self.currentMatchColor : Self.matchColor
        }
        // PDFView only redraws highlights for a new list.
        view.highlightedSelections = nil
        view.highlightedSelections = matches
        view.go(to: matches[index])
    }

    func clearFind() {
        matches = []
        view.highlightedSelections = nil
    }

    var selectedText: String? {
        view.currentSelection?.string
    }

    // MARK: Files

    var isLocalFile: Bool { url.isFileURL }

    /// Saves the bytes the page received, so it works even where the link has since expired.
    func download() {
        guard let data else { return }
        Downloads.shared.save(data, suggestedFilename: filename)
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Preview signs, annotates and fills in forms; a downloaded PDF goes there as a temporary copy.
    func openInPreview() {
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { return }
        var file = url
        if !isLocalFile {
            guard let data else { return }
            let folder = FileManager.default.temporaryDirectory.appending(path: "Lithium PDFs/\(UUID().uuidString)")
            file = folder.appending(path: filename)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file)
            } catch {
                return
            }
        }
        NSWorkspace.shared.open([file], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }

    func print() {
        guard let document, !isLocked,
              let operation = document.printOperation(for: .shared, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
        operation.jobTitle = title
        if let window = view.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}

extension PDFReader: @preconcurrency PDFViewDelegate {
    /// PDFKit would hand web links to the default browser; they open in Lithium instead.
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        let inNewTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        onOpenLink?(url, inNewTab)
    }
}

/// Tells the reader when its size changes, so a page fitted whole stays whole.
final class ReaderView: PDFView {
    var onResize: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }
}

extension NSColor {
    /// Behind the pages: a soft gray that lets white pages stand out, in light and dark.
    static let pdfCanvas = NSColor(name: "pdfCanvas") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.93, alpha: 1)
    }
}
