import PDFKit
import Testing
@testable import Lithium

/// PDFs in Lithium's own viewer. Part of BrowserTests, which runs one whole Browser at a time
/// in a throwaway home: `CFFIXED_USER_HOME=$(mktemp -d) swift test --filter BrowserTests`.
extension BrowserTests {
    @Test func showsAPDFInLithiumsViewer() async throws {
        let file = try makePDF(title: "Quarterly report", pages: ["Revenue grew", "Costs fell", "Revenue again"])
        let browser = Browser()
        let tab = browser.newTab(url: file)
        // Left open, its page would come back in the next test's session and slow it down.
        defer { browser.close(tab) }
        #expect(await waitForPDF(30) { tab.pdf?.pageCount == 3 })
        #expect(tab.title == "Quarterly report")
        #expect(tab.pdf?.outline.map(\.label) == ["Page 1", "Page 2", "Page 3"])
        #expect(tab.pdf?.outline.map(\.pageIndex) == [0, 1, 2])

        await browser.find.update(query: "revenue", in: tab.findTarget)
        #expect(browser.find.matchCount == 2)
        await browser.find.step(forward: true, in: tab.findTarget)
        #expect(browser.find.currentMatch == 2)
        // Both matches, and the current one again on top in its own color.
        #expect(tab.pdf?.view.highlightedSelections?.count == 3)
        await browser.find.step(forward: false, in: tab.findTarget)
        #expect(browser.find.currentMatch == 1)
        await browser.find.update(query: "", in: tab.findTarget)
        #expect(tab.pdf?.view.highlightedSelections?.isEmpty ?? true)

        await browser.find.update(query: "costs", in: tab.findTarget)
        #expect(tab.pdf?.view.highlightedSelections?.count == 2)
        browser.find.hide()
        #expect(tab.pdf?.view.highlightedSelections?.isEmpty ?? true)
        // ⌘G with the bar closed searches the PDF again: it forgot its matches.
        browser.find.show()
        await browser.find.step(forward: true, in: tab.findTarget)
        #expect(browser.find.matchCount == 1)
        #expect(browser.find.currentMatch == 1)
        #expect(tab.pdf?.view.highlightedSelections?.count == 2)
    }

    /// Fitted whole, two pages side by side fit the view's width, margins included.
    @Test func fitToPageFitsTheView() async throws {
        let file = try makePDF(title: "Wide", pages: ["One", "Two"])
        let browser = Browser()
        let tab = browser.newTab(url: file)
        defer { browser.close(tab) }
        #expect(await waitForPDF(30) { tab.pdf?.pageCount == 2 })
        let reader = try #require(tab.pdf)
        reader.view.frame = NSRect(x: 0, y: 0, width: 700, height: 2000)
        reader.toggleTwoUp()
        reader.setFit(.page)
        reader.view.layoutDocumentView()
        let document = try #require(reader.view.documentView)
        let shown = reader.view.convert(document.bounds, from: document).width
        #expect(shown <= reader.view.bounds.width)
        #expect(shown > reader.view.bounds.width * 0.9)
    }

    /// A PDF from the web can't open local files; a local PDF can open its neighbours.
    @Test func onlyLocalPDFsFollowLinksToFiles() async throws {
        let file = try makePDF(title: "Links", pages: ["Here"])
        let neighbour = file.deletingLastPathComponent().appending(path: "neighbour.html")
        try Data("<title>Neighbour</title>".utf8).write(to: neighbour)
        let browser = Browser()

        let remote = URL(string: "data:application/pdf;base64,\(try Data(contentsOf: file).base64EncodedString())")!
        let web = browser.newTab(url: remote)
        defer { browser.close(web) }
        #expect(await waitForPDF(30) { web.pdf?.pageCount == 1 })
        web.pdf?.onOpenLink?(neighbour, false)
        try await Task.sleep(for: .milliseconds(500))
        #expect(web.url == remote)

        let local = browser.newTab(url: file)
        defer { browser.close(local) }
        #expect(await waitForPDF(30) { local.pdf?.pageCount == 1 })
        local.pdf?.onOpenLink?(neighbour, false)
        #expect(await waitForPDF(30) { local.webView.title == "Neighbour" })
    }

    /// A PDF's link to another app asks first, as a page's does; with no site to name, "Always
    /// allow" isn't offered.
    @Test func aPDFsAppLinkAsksFirst() async throws {
        let file = try makePDF(title: "App link", pages: ["Here"])
        let browser = Browser()
        browser.appLinks.appOpening = { _ in URL(fileURLWithPath: "/Applications/Example.app") }
        let tab = browser.newTab(url: URL(string: "data:application/pdf;base64,\(try Data(contentsOf: file).base64EncodedString())")!)
        defer { browser.close(tab) }
        #expect(await waitForPDF(30) { tab.pdf?.pageCount == 1 })
        let before = ExternalApps.recorded
        let link = URL(string: "lithium-test:open")!
        tab.pdf?.onOpenLink?(link, false)
        #expect(await waitForPDF(5) { browser.appLinks.pending.contains { $0.tabID == tab.id } })
        let request = try #require(browser.appLinks.pending.first)
        #expect(request.url == link)
        #expect(!request.canRemember)
        #expect(ExternalApps.recorded == before)
        browser.appLinks.cancel(tabID: tab.id)
    }

    /// A page restored from the back-forward cache never gets a navigation response; it still shows in the viewer.
    @Test func leavingAndComingBackToAPDF() async throws {
        let file = try makePDF(title: "Menu", pages: ["Soup"])
        let browser = Browser()
        let tab = browser.newTab(url: file)
        defer { browser.close(tab) }
        #expect(await waitForPDF(30) { tab.pdf?.pageCount == 1 })

        tab.load(URL(string: "data:text/html,<title>Next</title>next")!)
        #expect(await waitForPDF(30) { tab.pdf == nil && tab.webView.title == "Next" })

        tab.webView.goBack()
        #expect(await waitForPDF(30) { tab.pdf?.pageCount == 1 })
        #expect(tab.url == file)
        #expect(await waitForPDF(5) { tab.title == "Menu" })
        #expect(tab.favicon === PDFReader.icon)
    }

    @Test func downloadSavesTheBytesThePageReceived() async throws {
        let home = try #require(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"])
        try #require(URL.downloadsDirectory.path.hasPrefix(URL(fileURLWithPath: home).resolvingSymlinksInPath().path)
            || URL.downloadsDirectory.path.hasPrefix(home))
        try FileManager.default.createDirectory(at: URL.downloadsDirectory, withIntermediateDirectories: true)
        let file = try makePDF(title: "Invoice", pages: ["Total 12 EUR"])
        let browser = Browser()
        let tab = browser.newTab(url: file)
        defer { browser.close(tab) }
        #expect(await waitForPDF(30) { tab.pdf?.pageCount == 1 })

        // Twice in a row, before the first file is written: each gets its own name.
        tab.pdf?.download()
        tab.pdf?.download()
        let items = Array(Downloads.shared.items.prefix(2))
        #expect(!items.contains { $0.canCancel })
        #expect(await waitForPDF(5) { items.allSatisfy { $0.state == .finished } })
        let size = try Int64(Data(contentsOf: file).count)
        #expect(items.allSatisfy { $0.completedBytes == size && $0.totalBytes == size })
        let saved = items.compactMap(\.destination)
        #expect(Set(saved.map(\.lastPathComponent)) == ["Invoice.pdf", "Invoice 2.pdf"])
        for file in saved { #expect(file.deletingLastPathComponent() == URL.downloadsDirectory) }
        #expect(try saved.allSatisfy { try Data(contentsOf: $0) == Data(contentsOf: file) })
    }

    /// Recorded, not opened: tests never launch Preview or Finder.
    @Test func toolbarButtonsHandTheFileToOtherApps() async throws {
        let preview = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview"))
        let file = try makePDF(title: "Lease", pages: ["Sign here"])
        let browser = Browser()
        let local = browser.newTab(url: file)
        defer { browser.close(local) }
        #expect(await waitForPDF(30) { local.pdf?.pageCount == 1 })
        var before = ExternalApps.recorded
        local.pdf?.showInFinder()
        local.pdf?.openInPreview()
        #expect(ExternalApps.recorded == before + [.reveal(file), .openWith(file, app: preview)])

        let bytes = try Data(contentsOf: file)
        let web = browser.newTab(url: URL(string: "data:application/pdf;base64,\(bytes.base64EncodedString())")!)
        defer { browser.close(web) }
        #expect(await waitForPDF(30) { web.pdf?.pageCount == 1 })
        before = ExternalApps.recorded
        web.pdf?.openInPreview()
        let handOff = ExternalApps.recorded.dropFirst(before.count)
        guard case .openWith(let copy, let app)? = handOff.first, handOff.count == 1 else {
            Issue.record("\(handOff)")
            return
        }
        #expect(app == preview)
        #expect(copy.lastPathComponent == "Lease.pdf")
        #expect(try Data(contentsOf: copy) == bytes)

        try FileManager.default.createDirectory(at: URL.downloadsDirectory, withIntermediateDirectories: true)
        web.pdf?.download()
        let item = try #require(Downloads.shared.items.first)
        #expect(await waitForPDF(5) { item.state == .finished })
        #expect(item.destination?.deletingLastPathComponent() == URL.downloadsDirectory)
        #expect(try item.destination.map { try Data(contentsOf: $0) } == bytes)
    }

    /// A PDF saved from the viewer goes through a hidden file: a failed write leaves nothing
    /// under the real name, nor a hidden leftover, and never replaces a file that appeared there.
    @Test func savingAPDFNeverLeavesAPartialFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data("%PDF-1.4 new".utf8)

        let fresh = folder.appending(path: "Fresh.pdf")
        try Downloads.write(bytes, to: fresh)
        #expect(try Data(contentsOf: fresh) == bytes)

        let taken = folder.appending(path: "Taken.pdf")
        let old = Data("%PDF-1.4 old".utf8)
        try old.write(to: taken)
        #expect(throws: (any Error).self) { try Downloads.write(bytes, to: taken) }
        #expect(try Data(contentsOf: taken) == old)

        let missing = folder.appending(path: "Gone/Missing.pdf")
        #expect(throws: (any Error).self) { try Downloads.write(bytes, to: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(Set(left) == ["Fresh.pdf", "Taken.pdf"], "no hidden partial is left behind")
    }

    /// Preview's copy of a downloaded PDF would stay on disk: a private tab never makes one.
    @Test func aPrivateTabsPDFNeverGoesToPreview() async throws {
        let file = try makePDF(title: "Statement", pages: ["Balance"])
        let browser = Browser()
        let remote = URL(string: "data:application/pdf;base64,\(try Data(contentsOf: file).base64EncodedString())")!
        let tab = browser.newTab(url: remote, privateStore: .nonPersistent())
        defer { browser.close(tab) }
        #expect(await waitForPDF(30) { tab.pdf?.pageCount == 1 })
        let reader = try #require(tab.pdf)
        #expect(reader.isPrivate)
        #expect(!reader.canOpenInPreview)
        let before = ExternalApps.recorded
        reader.openInPreview()
        #expect(ExternalApps.recorded == before)

        // A file already on disk leaves nothing new there.
        let local = browser.newTab(url: file, privateStore: .nonPersistent())
        defer { browser.close(local) }
        #expect(await waitForPDF(30) { local.pdf?.pageCount == 1 })
        #expect(local.pdf?.canOpenInPreview == true)
    }

    /// Any page can link to `#page=` with `Int.min`, which used to trap subtracting one.
    @Test func opensAtAPageWhateverTheFragmentSays() async throws {
        let base = URL(fileURLWithPath: "/tmp/a.pdf")
        let page = { (fragment: String) in PDFReader.openingPage(of: URL(string: "\(base.absoluteString)#\(fragment)")!) }
        #expect(page("page=3") == 2)
        #expect(page("page=1") == 0)
        #expect(page("page=0") == 0)
        #expect(page("page=-4") == 0)
        #expect(page("page=\(Int.min)") == 0)
        #expect(page("page=\(Int.max)") == Int.max - 1)
        #expect(page("page=99999999999999999999") == 0)
        #expect(page("zoom=2") == 0)
        #expect(PDFReader.openingPage(of: base) == 0)

        let file = try makePDF(title: "Far", pages: ["One", "Two"])
        let browser = Browser()
        let tab = browser.newTab(url: URL(string: "\(file.absoluteString)#page=\(Int.min)")!)
        defer { browser.close(tab) }
        #expect(await waitForPDF(30) { tab.pdf?.pageCount == 2 })
        #expect(tab.pdf?.pageIndex == 0)
    }

    @Test func locksAPasswordProtectedPDFUntilUnlocked() async throws {
        let file = try makePDF(title: "Secret", pages: ["Hidden"], password: "open sesame")
        let browser = Browser()
        let tab = browser.newTab(url: file)
        defer { browser.close(tab) }
        #expect(await waitForPDF(30) { tab.pdf?.isLocked == true })
        #expect(tab.pdf?.pageCount == 0)
        #expect(tab.pdf?.unlock(with: "wrong") == false)
        #expect(tab.pdf?.unlock(with: "open sesame") == true)
        #expect(tab.pdf?.pageCount == 1)
        await browser.find.update(query: "hidden", in: tab.findTarget)
        #expect(browser.find.matchCount == 1)
    }

    /// Summaries read the PDF's own text and selection: the web view under the viewer has none.
    @Test func summariesReadThePDFsText() async throws {
        let file = try makePDF(title: "Quarterly report", pages: ["Revenue grew", "Costs fell"])
        let reader = PDFReader(url: file)
        #expect(reader.open(try Data(contentsOf: file)))
        let content = try #require(await reader.content(limit: SummaryText.maximumLength))
        #expect(content.title == "Quarterly report")
        #expect(content.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) } == ["Revenue grew", "Costs fell"])
        #expect(!content.isTruncated)
        #expect(content.selection.isEmpty)

        reader.view.setCurrentSelection(reader.document?.findString("Costs", withOptions: []).first, animate: false)
        let selected = try #require(await reader.content(limit: 5))
        #expect(selected.selection == "Costs")
        #expect(selected.text == "Reven")
        #expect(selected.isTruncated && !selected.isSelectionTruncated)

        let locked = try makePDF(title: "Secret", pages: ["Hidden"], password: "open sesame")
        let lockedReader = PDFReader(url: locked)
        #expect(lockedReader.open(try Data(contentsOf: locked)))
        #expect(await lockedReader.content(limit: 100) == nil)
    }

    /// A text PDF with one outline entry per page, written by hand: PDFKit drops outlines it is given.
    private func makePDF(title: String, pages: [String], password: String? = nil) throws -> URL {
        let count = pages.count
        // Objects: 1 catalog, 2 page tree, 3 outline root, 4 font, 5 info, then per page: page, content, outline entry.
        func page(_ index: Int) -> Int { 6 + index * 3 }
        func entry(_ index: Int) -> Int { 8 + index * 3 }
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 3 0 R >>",
            "<< /Type /Pages /Kids [\((0..<count).map { "\(page($0)) 0 R" }.joined(separator: " "))] /Count \(count) >>",
            "<< /Type /Outlines /First \(entry(0)) 0 R /Last \(entry(count - 1)) 0 R /Count \(count) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Title (\(title)) >>",
        ]
        for (index, text) in pages.enumerated() {
            let content = "BT /F1 24 Tf 72 700 Td (\(text)) Tj ET"
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(page(index) + 1) 0 R /Resources << /Font << /F1 4 0 R >> >> >>")
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
            let previous = index > 0 ? " /Prev \(entry(index - 1)) 0 R" : ""
            let next = index < count - 1 ? " /Next \(entry(index + 1)) 0 R" : ""
            objects.append("<< /Title (Page \(index + 1)) /Parent 3 0 R /Dest [\(page(index)) 0 R /XYZ 0 792 0]\(previous)\(next) >>")
        }
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let table = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        pdf += offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 5 0 R >>\nstartxref\n\(table)\n%%EOF\n"

        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(title).pdf")
        try Data(pdf.utf8).write(to: file)
        if let password {
            let document = try #require(PDFDocument(url: file))
            try #require(document.write(to: file, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password]))
        }
        return file
    }

    private func waitForPDF(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

@MainActor
struct PDFPageFieldAndOutlineTests {
    /// The page field takes any `Int`: `Int.min` used to trap subtracting one.
    @Test func anyPageNumberGivesAPageIndex() {
        #expect(PDFReader.pageIndex(ofNumber: 3) == 2)
        #expect(PDFReader.pageIndex(ofNumber: 1) == 0)
        #expect(PDFReader.pageIndex(ofNumber: 0) == 0)
        #expect(PDFReader.pageIndex(ofNumber: Int.min) == 0)
        #expect(PDFReader.pageIndex(ofNumber: Int.max) == Int.max - 1)
    }

    /// Any page's PDF writes its outline: one nested past reason or with a huge number of
    /// entries is cut short, rather than overflowing the stack or holding up the window.
    @Test func aDeepOrHugeOutlineIsCutShort() {
        let document = PDFDocument()
        let deep = PDFOutline()
        var parent = deep
        for level in 0..<500 {
            let child = PDFOutline()
            child.label = "Level \(level)"
            parent.insertChild(child, at: 0)
            parent = child
        }
        var depth = 0
        var level = PDFReader.entries(of: deep, in: document)
        while let first = level.first {
            depth += 1
            level = first.children ?? []
        }
        #expect(depth == PDFReader.outlineDepthLimit)

        let wide = PDFOutline()
        for index in 0..<(PDFReader.outlineEntryLimit + 50) {
            let child = PDFOutline()
            child.label = "Entry \(index)"
            wide.insertChild(child, at: index)
        }
        #expect(PDFReader.entries(of: wide, in: document).count == PDFReader.outlineEntryLimit)
    }
}
