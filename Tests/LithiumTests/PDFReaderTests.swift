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

        await browser.find.update(query: "revenue", in: tab)
        #expect(browser.find.matchCount == 2)
        await browser.find.step(forward: true, in: tab)
        #expect(browser.find.currentMatch == 2)
        #expect(tab.pdf?.view.highlightedSelections?.count == 2)
        await browser.find.update(query: "", in: tab)
        #expect(tab.pdf?.view.highlightedSelections?.isEmpty ?? true)

        await browser.find.update(query: "costs", in: tab)
        #expect(tab.pdf?.view.highlightedSelections?.count == 1)
        browser.find.hide()
        #expect(tab.pdf?.view.highlightedSelections?.isEmpty ?? true)
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

        tab.pdf?.download()
        let item = try #require(Downloads.shared.items.first)
        #expect(await waitForPDF(5) { item.state == .finished })
        let saved = try #require(item.destination)
        #expect(saved.deletingLastPathComponent() == URL.downloadsDirectory)
        #expect(try Data(contentsOf: saved) == Data(contentsOf: file))
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
        await browser.find.update(query: "hidden", in: tab)
        #expect(browser.find.matchCount == 1)
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
