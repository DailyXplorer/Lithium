import AppKit
import CryptoKit
import Observation
import PDFKit
import Synchronization
import UniformTypeIdentifiers
import WebKit

/// A PDF shown in a tab: WebKit loads the file as usual, then Lithium draws the bytes it received
/// with PDFKit, over WebKit's viewer. Without the two WebKit calls this relies on, WebKit's viewer stays.
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
    /// Search and thumbnails, which would stall the main thread. Made on first use and dropped
    /// while the reader is out of sight, so a PDF in the history holds one parsed copy, not two.
    @ObservationIgnored private var loadedWorker: PDFWorker?
    @ObservationIgnored private var password: String?
    @ObservationIgnored private var matches: [PDFWorker.Match] = []
    /// The first matches only: tens of thousands of selections would stall the main thread.
    @ObservationIgnored private var highlighted: [PDFSelection] = []
    @ObservationIgnored private var currentMatch: Int?
    @ObservationIgnored private var fittedScale: CGFloat = 0
    /// Where to open once the view has a size: before that, PDFKit scrolls to the wrong place.
    @ObservationIgnored private var openingPage: Int?

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
            let answer = Answer(continuation)
            getter(webView, selector) { data, _ in answer.resume(data as Data?) }
        }
    }

    /// Resumes once; with nothing if WebKit drops the callback unanswered (a web view torn down),
    /// so the waiting task never hangs.
    private final class Answer: Sendable {
        private let continuation: Mutex<CheckedContinuation<Data?, Never>?>

        init(_ continuation: CheckedContinuation<Data?, Never>) {
            self.continuation = Mutex(continuation)
        }

        func resume(_ data: Data?) {
            continuation.withLock { $0.take() }?.resume(returning: data)
        }

        deinit {
            resume(nil)
        }
    }

    /// False when the bytes are not a PDF PDFKit can read; the tab then keeps WebKit's viewer.
    func open(_ data: Data) -> Bool {
        guard let document = PDFDocument(data: data) else { return false }
        self.data = data
        self.document = document
        isLocked = document.isLocked
        if !isLocked { show(document) }
        // Loads the model while the PDF is read, not when it is saved: the load would eat the
        // naming budget. Nothing when Tidy downloads is off.
        Downloads.shared.tidy.prepare()
        return true
    }

    func unlock(with password: String) -> Bool {
        guard let document, document.unlock(withPassword: password) else { return false }
        self.password = password
        isLocked = false
        show(document)
        return true
    }

    private var worker: PDFWorker? {
        guard let data else { return nil }
        if let loadedWorker { return loadedWorker }
        let worker = PDFWorker(data: data)
        loadedWorker = worker
        return worker
    }

    /// The tab moved on to another page; the reader stays in its history.
    func putAway() {
        clearMatches()
        loadedWorker = nil
    }

    private func show(_ document: PDFDocument) {
        view.document = document
        pageCount = document.pageCount
        outline = document.outlineRoot.map { Self.entries(of: $0, in: document) } ?? []
        openingPage = Self.openingPage(of: url)
        goToOpeningPage()
        pageDidChange()
    }

    /// Links like file.pdf#page=3, as in Chrome and Safari.
    static func openingPage(of url: URL) -> Int {
        let fragment = url.fragment() ?? ""
        guard fragment.hasPrefix("page=") else { return 0 }
        return pageIndex(ofNumber: Int(fragment.dropFirst(5)) ?? 1)
    }

    /// Counted from 1; clamped first, as `Int.min` (from a link or the page field) would trap subtracting one.
    static func pageIndex(ofNumber number: Int) -> Int {
        max(number, 1) - 1
    }

    /// The outline is the PDF's to write: a deep, looping or huge one would overflow the stack, never
    /// end, or hold up the main thread. Past these, entries are left out.
    static let outlineDepthLimit = 64
    static let outlineEntryLimit = 10_000

    private static func entries(of parent: PDFOutline, in document: PDFDocument, depth: Int, id: inout Int) -> [OutlineEntry] {
        guard depth < outlineDepthLimit else { return [] }
        var entries: [OutlineEntry] = []
        for index in 0..<parent.numberOfChildren {
            guard id < outlineEntryLimit else { break }
            guard let child = parent.child(at: index) else { continue }
            id += 1
            let entryID = id
            let children = self.entries(of: child, in: document, depth: depth + 1, id: &id)
            entries.append(OutlineEntry(
                id: entryID,
                label: child.label ?? "",
                pageIndex: child.destination?.page.map(document.index(for:)),
                children: children.isEmpty ? nil : children
            ))
        }
        return entries
    }

    static func entries(of root: PDFOutline, in document: PDFDocument) -> [OutlineEntry] {
        var id = 0
        return entries(of: root, in: document, depth: 0, id: &id)
    }

    var title: String {
        if let metadataTitle { return metadataTitle }
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? (url.host() ?? "PDF") : name
    }

    private var metadataTitle: String? {
        let metadata = (document?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return metadata?.isEmpty == false ? metadata : nil
    }

    /// The URL's last segment comes percent-decoded: an encoded "/" would lead the saved file out of its folder.
    var filename: String {
        let name = url.lastPathComponent
        let chosen = name.lowercased().hasSuffix(".pdf") ? name : title + ".pdf"
        let safe = chosen.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return Downloads.fileName(String(safe.dropLast(4)), String(safe.suffix(4)))
    }

    // MARK: Navigation and zoom

    func goToPage(_ index: Int) {
        guard let page = document?.page(at: min(max(index, 0), pageCount - 1)) else { return }
        view.go(to: page)
    }

    func setFit(_ fit: Fit) {
        self.fit = fit
        refitShowingCurrentPage()
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
        for index in 0..<document.pageCount {
            document.page(at: index)?.rotation += 90
        }
        view.layoutDocumentView()
        refitShowingCurrentPage()
        revision += 1
    }

    func toggleTwoUp() {
        isTwoUp.toggle()
        view.displayMode = isTwoUp ? .twoUpContinuous : .singlePageContinuous
        refitShowingCurrentPage()
    }

    /// A change of fit the user asked for starts the current page at the top; a resize keeps the place.
    private func refitShowingCurrentPage() {
        let page = view.currentPage
        refit()
        if let page { view.go(to: page) }
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
            // PDFView pads every page with its break margins; a little more keeps scroll bars away.
            let margins = view.pageBreakMargins
            let slack: CGFloat = 4
            let available = CGSize(
                width: view.bounds.width - columns * (margins.left + margins.right) - slack,
                height: view.bounds.height - margins.top - margins.bottom - slack
            )
            guard available.width > 0, available.height > 0 else { return }
            view.autoScales = false
            fittedScale = min(available.width / (size.width * columns), available.height / size.height)
            view.scaleFactor = fittedScale
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

    private static let matchColor = NSColor.findHighlightColor.withAlphaComponent(0.5)
    private static let currentMatchColor = NSColor.systemOrange.withAlphaComponent(0.8)

    func thumbnail(of index: Int, size: CGSize) async -> NSImage? {
        guard let worker, let page = document?.page(at: index) else { return nil }
        let rotation = page.rotation
        let password = password
        guard let image = await worker.thumbnail(of: index, rotation: rotation, size: size, password: password) else { return nil }
        return NSImage(cgImage: image, size: size)
    }

    // MARK: Files

    var isLocalFile: Bool { url.isFileURL }

    /// In a private tab: nothing it received may be left on disk.
    @ObservationIgnored var isPrivate = false

    /// A downloaded PDF reaches Preview only as a copy on disk, which Lithium can't take back
    /// once Preview has it (its Recents, its autosave): never for a private tab's.
    var canOpenInPreview: Bool { document != nil && (isLocalFile || !isPrivate) }

    /// Saves the bytes the page received, so it works even where the link has since expired.
    func download() {
        guard let data else { return }
        Downloads.shared.save(data, suggestedFilename: filename, from: url, title: metadataTitle)
    }

    func showInFinder() {
        ExternalApps.reveal(url)
    }

    /// Preview signs, annotates and fills in forms; a downloaded PDF goes there as a temporary copy.
    func openInPreview() {
        guard canOpenInPreview, let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { return }
        var file = url
        if !isLocalFile {
            guard let data else { return }
            // Named by address and content, so opening the same PDF again reuses its copy, and a
            // document regenerated at the same address (even at the same size) gets a new one.
            var hash = SHA256()
            hash.update(data: Data(url.absoluteString.utf8))
            hash.update(data: data)
            let digest = hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
            let folder = FileManager.default.temporaryDirectory.appending(path: "Lithium PDFs/\(digest)")
            file = folder.appending(path: filename)
            if !FileManager.default.fileExists(atPath: file.path) {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    // Whole or not at all, and quarantined: Preview can save it anywhere.
                    try Downloads.write(data, to: file, from: url)
                } catch {
                    // Another open of the same PDF may have just written it.
                    guard FileManager.default.fileExists(atPath: file.path) else { return }
                }
            }
        }
        ExternalApps.open(file, withApplicationAt: preview)
    }

    /// What a summary reads: WebKit's PDF viewer in the tab has no text to give.
    func content(limit: Int) async -> PageContent? {
        guard !isLocked, let worker, let read = await worker.text(limit: limit, password: password) else { return nil }
        let selection = view.currentSelection?.string ?? ""
        return PageContent(
            title: title, text: read.text, selection: String(selection.prefix(limit)),
            isTruncated: read.isTruncated, isSelectionTruncated: selection.count > limit
        )
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

/// The PDF searched through a copy of the document, so a long document never stalls typing.
extension PDFReader: FindTarget {
    func countMatches(of query: String) async -> Int {
        guard !isLocked, let worker else { return 0 }
        let search = worker.startSearch()
        guard let found = await worker.find(query, search: search, password: password), worker.isLatest(search) else { return 0 }
        matches = found
        currentMatch = nil
        highlighted = found.prefix(Self.highlightLimit).compactMap(selection(for:))
        for selection in highlighted { selection.color = Self.matchColor }
        highlight(current: nil)
        return matches.count
    }

    func showNextMatch(of query: String, forward: Bool) async -> FindStep {
        guard !matches.isEmpty else { return .none }
        let index = switch currentMatch {
        case nil: forward ? 0 : matches.count - 1
        case let current?: (current + (forward ? 1 : -1) + matches.count) % matches.count
        }
        currentMatch = index
        guard let selection = highlight(current: index) else { return .none }
        reveal(selection)
        return .shown(position: index + 1)
    }

    /// `go(to:)` with a selection leaves the view where it is when the match is pages away.
    func reveal(_ selection: PDFSelection) {
        guard let page = selection.pages.first, let document = view.documentView,
              let scrollView = document.enclosingScrollView else {
            view.go(to: selection)
            return
        }
        view.layoutDocumentView()
        let clip = scrollView.contentView
        let match = view.convert(view.convert(selection.bounds(for: page), from: page), to: document)
        let visible = clip.documentVisibleRect
        // Clear of the edges, where the find bar floats over the top.
        guard !visible.insetBy(dx: 0, dy: min(Self.revealMargin, visible.height / 4)).contains(match) else { return }
        // Midpoints come out the same whether the document view is flipped or not.
        var shown = visible
        shown.origin.y = match.midY - visible.height / 2
        if match.minX < visible.minX || match.maxX > visible.maxX { shown.origin.x = match.midX - visible.width / 2 }
        clip.scroll(to: clip.constrainBoundsRect(shown).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private static let revealMargin: CGFloat = 56

    @discardableResult
    private func highlight(current: Int?) -> PDFSelection? {
        let currentSelection = current.flatMap { matches.indices.contains($0) ? selection(for: matches[$0]) : nil }
        currentSelection?.color = Self.currentMatchColor
        // PDFView only redraws highlights for a new list.
        view.highlightedSelections = nil
        view.highlightedSelections = highlighted + [currentSelection].compactMap { $0 }
        return currentSelection
    }

    private static let highlightLimit = 1_000

    private func selection(for match: PDFWorker.Match) -> PDFSelection? {
        document?.page(at: match.page)?.selection(for: match.range)
    }

    func selectedText() async -> String? {
        view.currentSelection?.string
    }

    func clearMatches() {
        _ = loadedWorker?.startSearch()
        matches = []
        highlighted = []
        currentMatch = nil
        view.highlightedSelections = nil
    }
}

extension PDFReader: @preconcurrency PDFViewDelegate {
    /// PDFKit would hand web links to the default browser; they open in Lithium instead.
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        let inNewTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        onOpenLink?(url, inNewTab)
    }
}

/// Search and thumbnails on a second copy of the document, away from the main thread. PDFKit
/// objects are not shared across threads, so the copy never leaves this actor.
actor PDFWorker {
    struct Match: Sendable {
        let page: Int
        let range: NSRange
    }

    private let data: Data
    /// Parsed here on first use, never on the caller's thread.
    private var parsed: PDFDocument?
    /// The newest search; older ones stop at their next match.
    private nonisolated let latestSearch = Mutex(0)

    init(data: Data) {
        self.data = data
    }

    nonisolated func startSearch() -> Int {
        latestSearch.withLock { latest in
            latest += 1
            return latest
        }
    }

    nonisolated func isLatest(_ search: Int) -> Bool {
        latestSearch.withLock { $0 == search }
    }

    /// Yields between matches, so a thumbnail asked for meanwhile isn't kept waiting.
    func find(_ query: String, search: Int, password: String?) async -> [Match]? {
        guard let document = unlocked(password) else { return nil }
        var found: [Match] = []
        var selection: PDFSelection?
        while isLatest(search) {
            guard let next = document.findString(query, fromSelection: selection, withOptions: [.caseInsensitive, .diacriticInsensitive]),
                  let page = next.pages.first else { return found }
            let match = Match(page: document.index(for: page), range: next.range(at: 0, on: page))
            // PDFKit wraps around to the first match once it reaches the end.
            let seen = [found.first, found.last].contains { $0?.page == match.page && $0?.range == match.range }
            if seen { return found }
            found.append(match)
            selection = next
            await Task.yield()
        }
        return nil
    }

    func text(limit: Int, password: String?) -> (text: String, isTruncated: Bool)? {
        guard let document = unlocked(password) else { return nil }
        var text = ""
        var length = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.string, !page.isEmpty else { continue }
            if !text.isEmpty {
                text += "\n"
                length += 1
            }
            text += page
            length += page.count
            if length > limit { return (String(text.prefix(limit)), true) }
        }
        return (text, false)
    }

    func thumbnail(of index: Int, rotation: Int, size: CGSize, password: String?) -> CGImage? {
        guard let page = unlocked(password)?.page(at: index) else { return nil }
        page.rotation = rotation
        return page.thumbnail(of: size, for: .cropBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func unlocked(_ password: String?) -> PDFDocument? {
        if parsed == nil { parsed = PDFDocument(data: data) }
        guard let document = parsed else { return nil }
        if document.isLocked, let password { document.unlock(withPassword: password) }
        return document.isLocked ? nil : document
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
    static let pdfCanvas = NSColor(name: "pdfCanvas") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.93, alpha: 1)
    }
}
