import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithium

/// The reader on real articles, over the network, in a Lithium tab: it opens with the article whole,
/// styled, and leaving it gives the page back every style it had (#158). Opt-in, in a throwaway home:
/// `LMT_ENV="LITHIUM_LIVE_READER=1 LITHIUM_SNAPSHOT_DIR=/tmp/reader-live" lithium-mac-test --filter ReaderLiveTests`,
/// or `LITHIUM_LIVE_READER=1 scripts/test --filter ReaderLiveTests`; `LITHIUM_LIVE_READER_ONLY=verge,wired`
/// runs the pages whose address holds one of these. Each page prints a `LIVE` line, and `LIVE DIAG`
/// lines saying why when it fails; one whose article the site doesn't serve (offline, a bot, cookie
/// or pay wall) is skipped, not failed.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(9)), .enabled(if: ProcessInfo.processInfo.environment["LITHIUM_LIVE_READER"] == "1"
    && ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
struct ReaderLiveTests {
    struct Page: Sendable {
        let url: String
        /// How the article's first and last paragraphs start; empty for a page that may not be one.
        let first: String
        let last: String
    }

    static let pages: [Page] = [
        Page(url: "https://blog.google/innovation-and-ai/models-and-research/gemini-models/gemini-4-argon/", first: "Today, we’re announcing our new frontier", last: "We’re grateful for the initial cohort of"),
        Page(url: "https://www.anthropic.com/claude-haiku-5-5", first: "Claude Haiku 5.5 is designed for high-vo", last: "Haiku 5.5 is especially well-suited to t"),
        Page(url: "https://blog.cloudflare.com/2026-world-cup-internet-traffic/", first: "For 96 years, the World Cup has been a g", last: "HTTP request volume during the final mat"),
        Page(url: "https://github.blog/engineering/user-experience/rendering-huge-pull-requests-in-the-github-copilot-app/", first: "Broad refactors and migrations often hav", last: "If you review code for a living, it’s wo"),
        Page(url: "https://blogs.windows.com/windowsexperience/2026/10/07/building-windows-for-hybrid-intelligence/", first: "Agents are creating a foundational shift", last: "to learn more about putting hybrid intel"),
        Page(url: "https://dropbox.tech/machine-learning/introducing-nova-our-internal-platform-for-coding-agents", first: "To prepare for a future where agents can", last: "As coding agents continue to improve, we"),
        Page(url: "https://stripe.com/blog/giving-agents-the-ability-to-pay", first: "we talked about how agents are becoming", last: "with Link’s wallet for agents, and"),
        Page(url: "https://slack.engineering/managing-context-in-long-run-agentic-applications/", first: "we introduced our agentic security inves", last: "we’ll explore how artifacts serve as a c"),
        Page(url: "https://arstechnica.com/space/2026/10/amazon-builds-1000th-satellite-is-weeks-away-from-space-internet-rollout/", first: "Amazon has been developing a constellati", last: "We start off with 3,232 satellites, and"),
        Page(url: "https://www.bbc.com/news/articles/ckg725z5kgzo", first: "A new report claims a swarm of AI agents", last: "The firm intends to list itself on the s"),
        Page(url: "https://www.theguardian.com/technology/2026/oct/03/openai-safety-leader-quits-warning-ai-companys-culture-is-broken", first: "has quit the company, warning that its c", last: "An OpenAI spokesperson said the company"),
        Page(url: "https://www.npr.org/2026/10/05/nx-s1-5977852/ai-chatbots-midterm-election", first: "On a September evening,",last: "feel too bad if I had to do the election"),
        Page(url: "https://techcrunch.com/2026/10/01/chatgpt-can-now-virtually-try-on-clothes-for-you/", first: "OpenAI is again experimenting with how i", last: "Whether ChatGPT will become"),
        Page(url: "https://www.theverge.com/tech/1003936/home-assistant-says-big-tech-ruined-the-cloud-so-were-out", first: "The open-source smart home platform Home", last: "a win for Home Assistant"),
        Page(url: "https://www.wired.com/story/muse-creates-detailed-profiles-of-all-your-friends-and-family/", first: "has become a viral hit, with millions do", last: "a ballooning of what they know about use"),
        Page(url: "https://www.cnn.com/2026/10/02/politics/ai-campaign-ads-disclosure-invs-vis", first: "Dramatic political attack ads hitting th", last: "It is going to be increasingly difficult"),
        Page(url: "https://www.numerama.com/tech/2349055-irifi-le-drone-dattaque-autonome-francais-concu-pour-voler-2-000-km-sans-gps-et-frapper-tres-loin.html", first: "La start-up française Harmattan AI a pré", last: "fin 2027 pour voir les premières unités"),
        Page(url: "https://www.20minutes.fr/animaux/4251715-20261008-cinq-choses-savoir-blaireau-discret-voisin-forets", first: "À la tombée de la nuit, un museau appara", last: "le blaireau mène ainsi une vie bien plus"),
        Page(url: "https://www.lesnumeriques.com/voiture/hyundai-ioniq-3-n-line-evo-61-kwh-p78958/test.html", first: "Le constructeur sud-coréen Hyundai a su", last: "ne permettant même pas d'opter pour cet"),
        Page(url: "https://www.bfmtv.com/economie/il-va-falloir-qu-on-toilette-ca-le-ministre-de-l-economie-veut-retropedaler-sur-la-suppression-d-un-avantage-fiscal-important-sur-les-transmissions-d-entreprises_AD-202610060891.html", first: "Une disposition du budget, qui aurait ab", last: "Ce qui représente un total de 370.000 po"),
        Page(url: "https://www.frandroid.com/marques/3277829_samsung-va-produire-30-de-smartphones-en-moins-malgre-des-benefices-records", first: "Samsung réduirait jusqu'à 30 % sa produc", last: "Avec moins de smartphones produits, Sams"),
        Page(url: "https://www.01net.com/actualites/chatgpt-gpt-6-intelligent-ui-ce-qui-change.html", first: "OpenAI vient de donner un sacré coup de", last: "Avec l’arrivée de la nouvelle interface,"),
        Page(url: "https://www.tf1info.fr/societe/verif-appels-a-manifester-pour-le-17-octobre-on-est-remonte-aux-origines-de-la-mobilisation-en-ligne-2464500.html", first: "Elle est devenue en quelques jours une d", last: "Nos recherches montrent donc que c'est d"),
        Page(url: "https://www.clubic.com/actualite-631672-prixtel-red-by-sfr-b-you-les-forfaits-mobiles-pas-chers-le-sont-de-moins-en-moins.html", first: "On attendait de la rentrée son lot de pr", last: "Des hausses qui restent loin des bonds o"),
        Page(url: "https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Modules", first: "JavaScript programs started off pretty s", last: "These practices are not unique to module"),
        Page(url: "https://swift.org/blog/swift-at-apple-migrating-the-password-monitoring-service-from-java", first: "The Passwords app, introduced in the fal", last: "Our Swift implementation has run smoothl"),
        Page(url: "https://paulgraham.com/essay.html", first: "Remember the essays you had to write in", last: "Popular magazines made the period betwee"),
        Page(url: "https://www.750g.com/la-recette-de-gateau-la-plus-simple-du-monde-on-vous-partage-la-meilleure-facon-de-reussir-son-quatre-quarts-ideal-pour-le-gouter-a38578.htm", first: "le quatre-quarts semble une recette", last: "Le mieux pour le conserver"),
        Page(url: "https://www.newyorker.com/culture/essay/our-longing-for-inconvenience", first: "When she insists on falling in love the", last: "For instance, I hate to sound like a tra"),
        Page(url: "https://service-public.fr/particuliers/vosdroits/F2689", first: "Vous êtes concerné si vous avez obtenu", last: "Cet accompagnement prend notamment en co"),
        Page(url: "https://www.quantamagazine.org/is-particle-physics-dead-dying-or-just-hard-20260126/", first: "July 2012, physicists at the Large", last: "Clearly, further progress toward the tru"),
        Page(url: "https://www.clubic.com/test-produit-569058-test-ktc-h27e6.html", first: "À 300 Hz, le H27E6 affiche un input lag", last: "Oubliez les plastiques de qualité moyenn"),
        Page(url: "https://davidbussellarchive.substack.com/p/the-long-argument-western-philosophy", first: "Everything in Western philosophy, litera", last: "The series does not answer this question"),
        Page(url: "https://dev.to/morinaga/three-signals-from-284-published-articles-that-changed-how-i-plan-new-content-5cdh", first: "When I started cross-publishing articles", last: "The one concrete change: running this en"),
        Page(url: "https://hashnode.com/blog/ai-agent-security-2026", first: "Two details matter more than the headlin", last: "It can be, inside a deliberately designe"),
        Page(url: "https://thenextrecession.wordpress.com/2026/03/19/iran-and-the-us-economy", first: "Today, crude oil prices hit $116/b", last: "So the hoped for productivity gains from"),
        Page(url: "https://too-deep-zone.ghost.io/stop-worrying-and-learn-to-love-parity", first: "This installment will NOT cover your Eag", last: "You may have a high threshold for domina"),
        Page(url: "https://fr.wikipedia.org/wiki/Intelligence_artificielle", first: "l'ensemble des systèmes informatiques ca", last: "Auparavant, en 2015, le joueur professio"),
        Page(url: "https://en.wikipedia.org/wiki/Artificial_intelligence", first: "The traditional goals of AI research inc", last: "Several works use AI to force us to conf"),
        Page(url: "https://towardsdatascience.com/how-to-govern-ai-agents/", first: "This time last year, I released a Deeple", last: "If you're building agents, the fundament"),
        Page(url: "https://deepmind.google/models/gemini/pro/", first: "", last: ""),
    ]

    enum Outcome: String, Sendable { case pass = "PASS", fail = "FAIL", skip = "SKIP" }

    struct Result: Sendable {
        let page: Page
        let outcome: Outcome
        let detail: String

        func report() -> Outcome {
            print("LIVE \(outcome.rawValue) \(page.url) \(detail)")
            if outcome == .fail { Issue.record("\(page.url): \(detail)") }
            return outcome
        }
    }

    /// A world of the test's own: the page never sees what it keeps, nor does the reader's.
    private static let world = WKContentWorld.world(name: "lithium-reader-live")
    private static let snapshots = ProcessInfo.processInfo.environment["LITHIUM_SNAPSHOT_DIR"].map { URL(filePath: $0) }

    /// A few pages at once, each in its own tab and off-screen window: one after the other, the
    /// forty would outlast the run's time limit.
    @Test func readsRealArticlesAndGivesThePagesBack() async throws {
        if let snapshots = Self.snapshots { try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
        let browser = Browser()
        var outcomes: [Outcome] = []
        // LITHIUM_LIVE_READER_ONLY="verge,wired" runs the pages whose address holds one of these.
        let only = ProcessInfo.processInfo.environment["LITHIUM_LIVE_READER_ONLY"]?.split(separator: ",") ?? []
        let pages = Self.pages.filter { page in only.isEmpty || only.contains { page.url.contains($0) } }
        for start in stride(from: 0, to: pages.count, by: 5) {
            let batch = pages[start..<min(start + 5, pages.count)].map { page in
                Task { await Self.check(page, in: browser) }
            }
            for task in batch { outcomes.append(await task.value.report()) }
        }
        let count = { (outcome: Outcome) in outcomes.filter { $0 == outcome }.count }
        print("LIVE TOTAL pass=\(count(.pass)) fail=\(count(.fail)) skip=\(count(.skip)) of \(pages.count)")
    }

    private static func check(_ page: Page, in browser: Browser) async -> Result {
        let tab = browser.newTab(url: URL(string: page.url)!, selecting: false)
        // In a window far off every screen, see-through and deaf to the mouse, but shown, and with
        // WebKit's occlusion check off: the page draws frames and sees itself on screen, as in a
        // tab. Pages that redraw themselves once back (their header, what scrolled into view) do,
        // where a page never shown would wait for a frame forever.
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = tab.webView
        if tab.webView.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
            tab.webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        }
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            browser.close(tab, remembering: false)
        }
        do {
            let (outcome, detail) = try await read(page, in: tab)
            return Result(page: page, outcome: outcome, detail: detail)
        } catch {
            return Result(page: page, outcome: .fail, detail: "error=\(error)")
        }
    }

    private static func read(_ page: Page, in tab: Lithium.Tab) async throws -> (Outcome, String) {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, tab.commits == 0 || tab.isLoading, !tab.isShowingError {
            try await Task.sleep(for: .milliseconds(100))
        }
        if tab.isShowingError { return (.skip, "unreachable (load failed)") }
        guard tab.commits > 0 else { return (.skip, "unreachable (nothing loaded in 20 s)") }
        let webView = tab.webView
        try await Task.sleep(for: .seconds(2))

        let page0 = try await run(Self.pageScript, ["first": page.first, "last": page.last], in: webView)
        if page0["hasFirst"] as? Bool == false {
            diagnose(page, "page paragraphs: \(page0["story"] as? String ?? "")")
            return (.skip, "not served (first paragraph not in the page: \(page0["title"] as? String ?? "")")
        }
        // Styles that change by themselves (an animation, a late font) say nothing about the reader.
        try await Task.sleep(for: .seconds(1))
        let before = try await styles(in: webView)
        let served = page0["styles"] as? [String: String] ?? [:]
        let volatile = Set(before.keys.filter { before[$0] != served[$0] })

        if await !tab.toggleReader() {
            return page.first.isEmpty ? (.pass, "reader refused (not an article)") : (.fail, "enter returned false")
        }
        let reader = try await run(Self.readerScript, ["first": page.first, "last": page.last], in: webView)
        var problems: [String] = []
        if reader["hasFirst"] as? Bool != true { problems.append("first paragraph missing") }
        let lastServed = page0["hasLast"] as? Bool != false
        if lastServed, reader["hasLast"] as? Bool != true { problems.append("last paragraph missing") }
        if let styling = reader["styling"] as? String, !styling.isEmpty { problems.append("styling: \(styling)") }
        if let chrome = reader["chrome"] as? String, !chrome.isEmpty { problems.append("chrome kept: \(chrome)") }
        if let snapshots {
            try await Task.sleep(for: .milliseconds(300))
            let image = try await webView.takeSnapshot(configuration: nil)
            let index = Self.pages.firstIndex { $0.url == page.url } ?? 0
            let name = String(format: "%02d-", index + 1) + String((webView.url?.host() ?? "page").map { $0.isLetter || $0.isNumber ? $0 : "-" })
            if let png = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]) {
                try png.write(to: snapshots.appending(path: "reader-live-\(name).png"))
            }
        }

        await tab.toggleReader()
        try await Task.sleep(for: .seconds(1))
        let after = try await styles(in: webView)
        let describe = { (key: String) in "\(key): \(before[key] ?? "-") → \(after[key] ?? "-")" }
        // A sheet the page removed, and its rules with it.
        let removed = before.keys.filter { after[$0] == "removed by the page" && before[$0] != after[$0] }
        let removedRules = Set(removed.map { $0.split(separator: " ").prefix(2).joined(separator: " ") + " rules lost" })
        let changed = before.keys.sorted().filter { !$0.hasPrefix("~") && !volatile.contains($0) && before[$0] != after[$0] && !removed.contains($0) && !removedRules.contains($0) }.map(describe)
        if tab.isReading { problems.append("still reading") }
        if !changed.isEmpty {
            problems.append("not restored: \(changed.prefix(3).joined(separator: "; "))")
            let why = Set(before.keys).union(after.keys).sorted().filter { $0.hasPrefix("~") && before[$0] != after[$0] }.map(describe)
            diagnose(page, (changed + why).joined(separator: "; "))
        }
        if reader["hasFirst"] as? Bool != true || lastServed && reader["hasLast"] as? Bool != true {
            diagnose(page, "first paragraph in: \(page0["path"] as? String ?? "?") ;; reader starts: \(reader["start"] as? String ?? "?")")
        }

        let words = reader["words"] as? Int ?? 0
        var detail = "words=\(words) restored=\(changed.isEmpty)"
        if !lastServed { detail += " (last paragraph not served)" }
        if !volatile.isEmpty { detail += " volatile=\(volatile.count)" }
        if !removed.isEmpty { detail += " (the page then removed \(removed.count) of its own sheets)" }
        return problems.isEmpty ? (.pass, detail) : (.fail, "\(detail) — \(problems.joined(separator: ", "))")
    }

    /// In short lines: the runner keeps 300 characters of each.
    private static func diagnose(_ page: Page, _ text: String) {
        let host = URL(string: page.url)?.host() ?? page.url
        var rest = Substring(text)
        while !rest.isEmpty {
            print("LIVE DIAG \(host) \(rest.prefix(220))")
            rest = rest.dropFirst(220)
        }
    }

    private static func run(_ script: String, _ arguments: [String: Any] = [:], in webView: WKWebView) async throws -> [String: Any] {
        let json = try await webView.callAsyncJavaScript(Self.common + script, arguments: arguments, contentWorld: world) as? String
        let object = try JSONSerialization.jsonObject(with: Data((json ?? "{}").utf8)) as? [String: Any]
        return object ?? [:]
    }

    private static func styles(in webView: WKWebView) async throws -> [String: String] {
        try await run("return JSON.stringify(measure());", in: webView) as? [String: String] ?? [:]
    }

    /// Text compared without case, spaces or quotes: sites curl them, or not. The page's elements
    /// are picked once, so the same ones are measured before and after the reader.
    private static let common = """
        const norm = (text) => text.normalize('NFKC').toLowerCase().replace(/[\\s\\u00ad\\u200b'"‘’‚‛“”„«»ʼ′`´]+/g, '');
        const textOf = (root) => {
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, { acceptNode: (node) =>
            node.parentElement?.closest('script, style, noscript, template') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT });
          let text = '';
          while (walker.nextNode()) text += walker.currentNode.data + ' ';
          return text;
        };
        const ownedSheets = (root) => [
          ...[...root.styleSheets].filter((sheet) => sheet.ownerNode),
          ...[...root.querySelectorAll('*')].filter((element) => element.shadowRoot).flatMap((element) => ownedSheets(element.shadowRoot)),
        ];
        const describe = (element) => element ? `${element.localName}${element.id ? '#' + element.id : ''}${typeof element.className === 'string' && element.className ? '.' + element.className.trim().split(/\\s+/).slice(0, 3).join('.') : ''}` : '-';
        // Keys starting with ~ say why, but aren't compared.
        const measure = () => {
          const visible = (selector) => [...document.querySelectorAll(selector)].find((element) => element.checkVisibility());
          window.picked ??= { body: document.body, h1: visible('h1'), p: visible('p'), header: visible('header'), nav: visible('nav') };
          window.sheetNodes ??= ownedSheets(document).map((sheet) => sheet.ownerNode);
          const owned = ownedSheets(document);
          const result = {
            // The page's sheets back, counting those the page itself removed.
            sheets: String(window.sheetNodes.filter((node) => node.sheet || !node.isConnected && !window.picked.body.contains(node)).length),
            adopted: String(document.adoptedStyleSheets.length),
            '~added sheets': String(owned.filter((sheet) => !window.sheetNodes.includes(sheet.ownerNode)).length),
            '~html': `${document.documentElement.className} ${document.documentElement.getAttribute('style') ?? ''}`,
            '~body': `${document.body?.className} ${document.body?.getAttribute('style') ?? ''}`,
            '~scrollbar': String(innerWidth - document.documentElement.clientWidth),
            '~scroll': `${scrollX},${scrollY}`,
            '~elements': String(document.getElementsByTagName('*').length),
          };
          // The rules of each sheet, kept the first time to tell later which went missing.
          const rules = window.sheetNodes.map((node) => { try { return [...(node.sheet?.cssRules ?? [])].map((rule) => rule.cssText); } catch { return []; } });
          window.firstRules ??= rules;
          window.sheetNodes.forEach((node, index) => {
            const missing = window.firstRules[index].filter((text) => !rules[index].includes(text));
            const counts = new Map();
            for (const text of window.firstRules[index]) counts.set(text, (counts.get(text) ?? 0) + 1);
            const added = rules[index].filter((text) => { const left = counts.get(text) ?? 0; counts.set(text, left - 1); return left <= 0; });
            if (added.length) result[`~added in ${index}`] = `${added.length}: ${added.slice(0, 3).map((text) => text.slice(0, 90)).join(' | ')}`;
            if (node.isConnected) result[`sheet ${index} rules lost`] = String(missing.length);
            if (missing.length) result[`~missing in ${index}`] = `${missing.length}: ${missing.slice(0, 3).map((text) => text.slice(0, 90)).join(' | ')}`;
          });
          // Each sheet back, on or off as it was, with every rule it had: rules the page adds are its own.
          window.sheetNodes.forEach((node, index) => {
            const name = `sheet ${index} ${describe(node)} ${(node.href ?? node.textContent.slice(0, 30)).slice(-40)}`;
            if (!node.isConnected) {
              // Left in the page's detached <body>, the reader lost it; cut off anywhere else, the page removed it.
              let top = node.getRootNode();
              while (top.host) top = top.host.getRootNode();
              result[name] = top === window.picked.body ? 'gone' : 'removed by the page';
              return;
            }
            result[name] = `${node.sheet ? 'on' : 'none'}${node.sheet?.disabled ? ' off' : ''}${node.sheet?.media.mediaText ? ` media=${node.sheet.media.mediaText}` : ''}`;
          });
          for (const [name, element] of Object.entries(window.picked)) {
            if (!element) continue;
            result[`~${name}`] = `${describe(element)} connected=${element.isConnected}`;
            const computed = getComputedStyle(element);
            for (const property of ['font-family', 'font-size', 'color', 'background-color', 'background-image', 'display', 'width']) {
              result[`${name} ${property}`] = computed.getPropertyValue(property);
            }
          }
          return result;
        };

        """

    /// The page as served, with the text of its menus and footers, which must not reach the reader.
    private static let pageScript = """
        const text = norm(textOf(document.body));
        window.chromeText = [...document.querySelectorAll('nav, footer, [role=navigation], [role=contentinfo]')]
          .map((element) => norm(textOf(element))).filter((text) => text.length >= 40);
        // Where the article's first paragraph sits, for a reader that misses it.
        const holder = first && [...document.body.querySelectorAll('*')].reverse().find((element) => norm(textOf(element)).includes(norm(first)));
        const path = [];
        for (let element = holder; element && element !== document.documentElement; element = element.parentElement) {
          const computed = getComputedStyle(element);
          const marks = [computed.display === 'none' ? 'none' : '', computed.visibility === 'hidden' ? 'hidden' : '',
            element.getAttribute('role') ?? '', element.getAttribute('aria-live') ? 'live' : '', element.hidden ? 'hidden-attr' : '',
            element.getAttribute('aria-hidden') === 'true' ? 'aria-hidden' : '', element.inert ? 'inert' : '', computed.opacity === '0' ? 'opacity0' : ''].filter(Boolean);
          path.push(describe(element) + (marks.length ? `[${marks}]` : ''));
        }
        // What the page holds instead, for one that doesn't serve the article.
        const story = [...document.querySelectorAll('p')].map((p) => p.textContent.trim()).filter((text) => text.length > 80).slice(0, 2).join(' / ').slice(0, 300);
        return JSON.stringify({ title: document.title, styles: measure(), path: path.join(' < '), story,
          hasFirst: !first || text.includes(norm(first)), hasLast: !last || text.includes(norm(last)) });
        """

    /// The reader as shown: the article whole, in the reader's own size, width, font and colors,
    /// with none of the page's menus.
    private static let readerScript = """
        await document.fonts.ready;
        const article = document.querySelector('article');
        if (!article) return JSON.stringify({ styling: 'no article element' });
        const text = norm(textOf(article));
        const computed = getComputedStyle(article);
        const problems = [];
        const start = textOf(article).replace(/\\s+/g, ' ').slice(0, 300);
        if (computed.maxWidth !== '646px') problems.push(`max-width ${computed.maxWidth}`);
        if (article.getBoundingClientRect().width > 646 + 64 + 1) problems.push(`width ${article.getBoundingClientRect().width}`);
        if (computed.fontSize !== '19px') problems.push(`font-size ${computed.fontSize}`);
        if (!/^"?Lithium DM Sans"?,/.test(computed.fontFamily)) problems.push(`font ${computed.fontFamily}`);
        if (!document.fonts.check('19px "Lithium DM Sans"')) problems.push('DM Sans not loaded');
        if (computed.color !== 'rgb(28, 29, 36)') problems.push(`color ${computed.color}`);
        const background = getComputedStyle(document.body).backgroundColor;
        if (background !== 'rgb(255, 255, 255)') problems.push(`background ${background}`);
        const kept = (window.chromeText ?? []).filter((block) => text.includes(block)).map((block) => block.slice(0, 40));
        const chrome = 'nav, footer, aside, [role=navigation], [role=contentinfo]';
        if (document.body.querySelector(chrome)) kept.push('a nav or footer element');
        if ([...document.querySelectorAll(chrome)].some((element) => element.checkVisibility({ visibilityProperty: true, opacityProperty: true }))) kept.push('the page\\'s menus still shown');
        return JSON.stringify({ hasFirst: text.includes(norm(first)), hasLast: text.includes(norm(last)), start,
          words: textOf(article).split(/\\s+/).filter(Boolean).length, styling: problems.join(', '), chrome: kept.join(' | ') });
        """
}
