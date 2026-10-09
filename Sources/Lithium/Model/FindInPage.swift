import Observation
import WebKit

/// What find-in-page searches: a web page, or a PDF in Lithium's viewer.
@MainActor
protocol FindTarget: AnyObject {
    func countMatches(of query: String) async -> Int
    func showNextMatch(of query: String, forward: Bool) async -> FindStep
    func selectedText() async -> String?
    func clearMatches()
}

enum FindStep: Equatable {
    case none
    /// The match's place among them, from 1, when the target knows it (a web page can't always tell).
    case shown(position: Int?)
}

/// Find-in-page state. WKWebView's own find panel needs private container APIs, so Lithium
/// drives `WKWebView.find` itself and counts matches in the page text.
@MainActor
@Observable
final class FindInPage {
    var isVisible = false
    private(set) var query = ""
    private(set) var matchCount = 0
    private(set) var currentMatch = 0
    private(set) var focusToken = 0
    /// The link's page (`QuickLinks`) the bar was opened over; nil for the main window's.
    private(set) var linkTab: Tab?
    /// Only Find… takes the keyboard; Find Next and Use Selection leave it where it is, such as a form field.
    @ObservationIgnored private(set) var focusesField = true
    /// Set by the bar while its field has the keyboard: Escape there closes the bar.
    @ObservationIgnored var isFieldFocused = false
    @ObservationIgnored private weak var target: FindTarget?
    /// Only the newest search sets the count: an older one may finish later, even for the same text.
    @ObservationIgnored private var search = 0
    /// Only the last keystroke of a burst searches (`type`).
    @ObservationIgnored private var typing = 0

    func show(focusingField: Bool = true, inLink linkTab: Tab? = nil) {
        self.linkTab = linkTab
        isVisible = true
        focusesField = focusingField
        if focusingField { focusToken &+= 1 }
    }

    func hide() {
        isVisible = false
        linkTab = nil
        // A search still running must not show a match once the bar is closed.
        search += 1
        target?.clearMatches()
        target = nil
    }

    func update(query newQuery: String, in target: FindTarget, forward: Bool = true) async {
        if self.target !== target { self.target?.clearMatches() }
        self.target = target
        search += 1
        let current = search
        query = newQuery
        currentMatch = 0
        guard !newQuery.isEmpty else {
            matchCount = 0
            target.clearMatches()
            return
        }
        let count = await target.countMatches(of: newQuery)
        guard current == search else { return }
        matchCount = count
        await step(forward: forward, in: target)
    }

    /// Typing searches once the keys pause: each count reads the whole page text, and on a long
    /// page one per keystroke queue up behind each other.
    func type(query newQuery: String, in target: FindTarget) async {
        typing &+= 1
        let typed = typing, searched = search
        try? await Task.sleep(for: Self.typingPause)
        // Typed again, closed, or searched another way (Return) meanwhile.
        guard typed == typing, searched == search else { return }
        await update(query: newQuery, in: target)
    }

    static let typingPause: Duration = .milliseconds(120)

    func step(forward: Bool, in target: FindTarget) async {
        guard !query.isEmpty else { return }
        // Its matches were cleared since it was searched (the bar closed): a PDF forgets them.
        guard self.target === target else {
            await update(query: query, in: target, forward: forward)
            return
        }
        let current = search
        let step = await target.showNextMatch(of: query, forward: forward)
        guard current == search else { return }
        guard case .shown(let position) = step else {
            currentMatch = 0
            return
        }
        if matchCount == 0 { matchCount = 1 }
        // A page's text read two ways may disagree by a match: never past the count.
        currentMatch = position.map { min($0, matchCount) } ?? next(forward)
    }

    /// For a target that doesn't say which match it showed, counted here.
    private func next(_ forward: Bool) -> Int {
        guard currentMatch > 0 else { return forward ? 1 : matchCount }
        return forward ? currentMatch % matchCount + 1 : (currentMatch + matchCount - 2) % matchCount + 1
    }

    func useSelection(in target: FindTarget, inLink linkTab: Tab? = nil) async {
        guard let text = await target.selectedText(), !text.isEmpty else { return }
        show(focusingField: false, inLink: linkTab)
        await update(query: text, in: target)
    }
}

extension WKWebView: FindTarget {
    private static let countScript = """
        const text = (document.body && document.body.innerText || '').toLocaleLowerCase();
        const needle = query.toLocaleLowerCase();
        let count = 0;
        for (let i = text.indexOf(needle); i !== -1; i = text.indexOf(needle, i + needle.length)) count++;
        return count;
        """

    func countMatches(of query: String) async -> Int {
        let count = try? await callAsyncJavaScript(Self.countScript, arguments: ["query": query], contentWorld: .defaultClient)
        return (count as? Int) ?? 0
    }

    /// WebKit's find selection is a faint gray outside the focused view, and the find bar covers the
    /// top: the match gets a CSS highlight and is centered near an edge; the selection steps aside
    /// to a caret, and comes back for the next search to start from.
    private static let markScript = """
        const selection = getSelection();
        const range = selection.rangeCount ? selection.getRangeAt(0) : null;
        // Text in a form field selects the field, which has no range to mark.
        if (!range || range.collapsed) {
          CSS.highlights.delete('lithium-find');
          window.__lithiumFind = null;
          return;
        }
        let sheet = window.__lithiumFindSheet;
        if (!sheet) {
          sheet = window.__lithiumFindSheet = new CSSStyleSheet();
          sheet.replaceSync(`::highlight(lithium-find) { background-color: ${color}; color: black; }`);
        }
        if (!document.adoptedStyleSheets.includes(sheet)) document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        const mark = range.cloneRange();
        CSS.highlights.set('lithium-find', new Highlight(mark));
        // Its place: the matches in the text before it, read as the count reads the page (a
        // selection's text, like innerText, leaves out hidden text, scripts and styles).
        let position = null;
        if (document.body && document.body.contains(mark.startContainer)) {
          const before = document.createRange();
          before.setStart(document.body, 0);
          before.setEnd(mark.startContainer, mark.startOffset);
          selection.removeAllRanges();
          selection.addRange(before);
          const text = selection.toString().toLocaleLowerCase();
          const needle = query.toLocaleLowerCase();
          position = 1;
          for (let i = text.indexOf(needle); i !== -1; i = text.indexOf(needle, i + needle.length)) position++;
          selection.removeAllRanges();
          selection.addRange(mark.cloneRange());
        }
        selection.collapseToEnd();
        window.__lithiumFind = { mark, node: selection.anchorNode, offset: selection.anchorOffset };

        const middle = (box, view) => box.top + box.height / 2 - (view.top + view.height / 2);
        const outside = (box, view) => box.top < view.top + margin || box.bottom > view.bottom - margin;
        // Each box scrolling around it first, innermost out, then the window.
        for (let element = mark.startContainer.parentElement; element; element = element.parentElement) {
          if (element === document.scrollingElement || element.scrollHeight <= element.clientHeight) continue;
          if (!/(auto|scroll|overlay)/.test(getComputedStyle(element).overflowY)) continue;
          const box = mark.getBoundingClientRect();
          const view = element.getBoundingClientRect();
          if (outside(box, view)) element.scrollTop += middle(box, view);
        }
        const box = mark.getBoundingClientRect();
        const view = new DOMRect(0, 0, innerWidth, innerHeight);
        const top = outside(box, view) ? middle(box, view) : 0;
        const left = box.left < 0 || box.right > innerWidth ? box.left + box.width / 2 - innerWidth / 2 : 0;
        if (top || left) scrollBy({ top, left, behavior: 'instant' });
        return position;
        """

    /// Puts the match back in the selection, unless the user has clicked or selected since.
    private static let reselectScript = """
        const found = window.__lithiumFind;
        const selection = getSelection();
        if (found && selection.isCollapsed && selection.anchorNode === found.node && selection.anchorOffset === found.offset) {
          selection.removeAllRanges();
          selection.addRange(found.mark);
        }
        """

    private static let unmarkScript = reselectScript + """

        CSS.highlights.delete('lithium-find');
        window.__lithiumFind = null;
        if (window.__lithiumFindSheet) document.adoptedStyleSheets = document.adoptedStyleSheets.filter((sheet) => sheet !== window.__lithiumFindSheet);
        """

    /// Safari's find yellow, on the current match: a web page marks no other.
    private static let matchColor = "#ffd60a"

    /// Clear of the edges, where the find bar floats over the top.
    private static let revealMargin = 56

    func showNextMatch(of query: String, forward: Bool) async -> FindStep {
        _ = try? await callAsyncJavaScript(Self.reselectScript, contentWorld: .defaultClient)
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        guard (try? await find(query, configuration: configuration))?.matchFound == true else {
            _ = try? await callAsyncJavaScript(Self.unmarkScript, contentWorld: .defaultClient)
            return .none
        }
        let arguments: [String: Any] = ["color": Self.matchColor, "margin": Self.revealMargin, "query": query]
        let position = try? await callAsyncJavaScript(Self.markScript, arguments: arguments, contentWorld: .defaultClient)
        return .shown(position: position as? Int)
    }

    func selectedText() async -> String? {
        try? await callAsyncJavaScript("return String(getSelection());", contentWorld: .defaultClient) as? String
    }

    /// Unmarks the match and leaves it selected, as Safari does once its find bar closes.
    func clearMatches() {
        Task { _ = try? await callAsyncJavaScript(Self.unmarkScript, contentWorld: .defaultClient) }
    }
}
