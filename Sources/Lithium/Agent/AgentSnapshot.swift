import Foundation

/// The viewport of a frame as `agent.js` reports it, in CSS pixels: size, scroll, page size,
/// device pixel ratio (pageZoom and magnification included), and the visual viewport.
struct PageViewport: Codable, Equatable {
    let w: Double, h: Double, sx: Double, sy: Double, pw: Double, ph: Double
    let dpr: Double, vx: Double, vy: Double, vs: Double
}

/// One frame's answer to `snapshot`, in that frame's own viewport.
struct FrameReport: Decodable {
    let token: String
    var unchanged: Bool?
    var gen: Int?
    var path: String?
    var url: String?
    var title: String?
    var viewport: PageViewport?
    var nodes: [Node]?
    var frames: [Frame]?
    var focused: Int?
    var focusedFrame: Int?
    var challenge: String?
    var truncated: Bool?

    struct Node: Decodable {
        let id: Int
        let role: String
        var name: String?
        var level: Int?
        var href: String?
        var value: String?
        var filled: Bool?
        var state: [String]?
        var options: Int?
        var `guard`: String?
        var frame: Int?
        let box: [Double]
    }

    /// An `<iframe>`: its index in `window.frames`, its border box, and its content box
    /// `[x, y, width, height, scale]`, where the child frame's viewport sits.
    struct Frame: Decodable {
        let id: Int
        let index: Int
        let box: [Double]
        let content: [Double]
        let src: String
    }
}

/// A snapshot line: an element, a text block, or a frame, in top-level viewport CSS pixels.
struct SnapshotNode: Equatable {
    var ref: String
    let role: String
    var name: String?
    var level: Int?
    var href: String?
    var value: String?
    var filled = false
    var state: [String] = []
    var options: Int?
    var guardKind: String?
    var origin: String?
    var box: [Int]
    var off: String?
    /// The frame ref of the frame it is in.
    var frame: String?
    var depth = 0

    /// Content, without the box: scrolling moves every box, which a diff doesn't repeat.
    func hasSameContent(as other: SnapshotNode) -> Bool {
        var moved = other
        moved.box = box
        moved.off = off
        return moved == self
    }

    var json: JSONValue {
        var fields: [String: JSONValue] = ["ref": .string(ref), "role": .string(role), "box": .array(box.map { .int($0) })]
        if let name { fields["name"] = .string(name) }
        if let level { fields["level"] = .int(level) }
        if let href { fields["href"] = .string(href) }
        if let value { fields["value"] = .string(value) }
        if filled { fields["filled"] = true }
        if !state.isEmpty { fields["state"] = .array(state.map { .string($0) }) }
        if let options { fields["options"] = .int(options) }
        if let guardKind { fields["guard"] = .string(guardKind) }
        if let origin { fields["origin"] = .string(origin) }
        if let off { fields["off"] = .string(off) }
        if let frame { fields["in"] = .string(frame) }
        return .object(fields)
    }

    /// `[e5] textbox "Email" = "ann@example.com" focused required @100,250 180x24`. Page text is
    /// quoted and escaped, so it can't pass itself off as another line.
    var line: String {
        var parts = ["[\(ref)]", role + (level.map(String.init) ?? "")]
        if let name { parts.append(Self.quoted(name)) }
        if let origin { parts.append(origin) }
        if let href { parts.append("→ " + href.replacing(/\s/, with: "%20")) }
        if let value { parts.append("= " + (value == "[redacted]" ? value : Self.quoted(value))) }
        if filled { parts.append("filled") }
        parts += state
        if let options { parts.append("\(options) options") }
        if let guardKind { parts.append("guard:\(guardKind)") }
        if box.count == 4 { parts.append("@\(box[0]),\(box[1]) \(box[2])x\(box[3])") }
        if let off { parts.append("(\(off))") }
        return String(repeating: "  ", count: depth) + parts.joined(separator: " ")
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x2028 || scalar.value == 0x2029:
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

/// What `snapshot` returns (design section 4.2), before and after it is numbered for a session.
struct PageSnapshot {
    let tab: String
    let url: String
    let title: String
    var seq = 0
    let viewport: PageViewport
    let zoom: Double
    let focused: String?
    let challenge: AgentChallenge?
    /// Nodes left out over the cap, nearest the viewport kept.
    let dropped: Int
    var nodes: [SnapshotNode]
    /// The main frame's document: a diff from a snapshot of another one (a reload, the next
    /// page) would remove and add every node, so the whole snapshot is given instead.
    var document = ""
    /// Frames read before that didn't answer this time (too slow), by ref: their nodes are left out, not removed.
    var unread: Set<String> = []
    /// The scope and node cap it was taken with: diffs only compare snapshots of the same view.
    var view = ""

    func hasSameContent(as other: PageSnapshot) -> Bool {
        document == other.document && url == other.url && title == other.title && focused == other.focused && challenge == other.challenge
            && nodes.count == other.nodes.count && zip(nodes, other.nodes).allSatisfy { $0.hasSameContent(as: $1) }
    }

    var viewportJSON: JSONValue {
        [
            "w": .int(Int(viewport.w)), "h": .int(Int(viewport.h)), "sx": .int(Int(viewport.sx)), "sy": .int(Int(viewport.sy)),
            "pw": .int(Int(viewport.pw)), "ph": .int(Int(viewport.ph)), "dpr": .double(viewport.dpr), "zoom": .double(zoom),
        ]
    }

    private var head: [String: JSONValue] {
        var fields: [String: JSONValue] = ["tab": .string(tab), "url": .string(url), "title": .string(title), "seq": .int(seq), "viewport": viewportJSON]
        if let focused { fields["focused"] = .string(focused) }
        if let challenge { fields["challenge"] = challenge.json }
        if dropped > 0 {
            fields["truncated"] = true
            fields["dropped"] = .int(dropped)
        }
        return fields
    }

    var json: JSONValue {
        var fields = head
        fields["nodes"] = .array(nodes.map(\.json))
        return .object(fields)
    }

    var header: String {
        var parts = ["\(tab) \(url) \(SnapshotNode.quoted(title)) seq \(seq)"]
        parts.append("viewport \(Int(viewport.w))x\(Int(viewport.h)) scroll \(Int(viewport.sx)),\(Int(viewport.sy))")
        parts.append("page \(Int(viewport.pw))x\(Int(viewport.ph))")
        if zoom != 1 { parts.append("zoom \(zoom.formatted())") }
        if let focused { parts.append("focused \(focused)") }
        if let challenge { parts.append("challenge \(challenge.kind)\(challenge.ref.map { " " + $0 } ?? ""): ask the user to solve it") }
        if dropped > 0 { parts.append("truncated: \(dropped) nodes left out") }
        return parts.joined(separator: " · ")
    }

    var text: String {
        ([header] + nodes.map(\.line)).joined(separator: "\n")
    }

    /// What changed since `earlier`: nodes added, removed, and changed (given whole).
    func diff(since earlier: PageSnapshot) -> JSONValue {
        let before = Dictionary(earlier.nodes.map { ($0.ref, $0) }) { first, _ in first }
        let now = Set(nodes.map(\.ref))
        var added: [SnapshotNode] = []
        var changed: [SnapshotNode] = []
        for node in nodes {
            guard let old = before[node.ref] else {
                added.append(node)
                continue
            }
            if !old.hasSameContent(as: node) { changed.append(node) }
        }
        let inUnreadFrame = earlier.inside(unread)
        let removed = earlier.nodes.filter { !now.contains($0.ref) && !inUnreadFrame($0) }.map(\.ref)
        var fields = head
        fields["since"] = .int(earlier.seq)
        fields["added"] = .array(added.map(\.json))
        fields["removed"] = .array(removed.map { .string($0) })
        fields["changed"] = .array(changed.map(\.json))
        var lines = [header + " · since \(earlier.seq)"]
        lines += added.map { "+ " + $0.line.trimmingCharacters(in: .whitespaces) }
        lines += removed.map { "- \($0)" }
        lines += changed.map { "~ " + $0.line.trimmingCharacters(in: .whitespaces) }
        if lines.count == 1 { lines.append("no changes") }
        fields["text"] = .string(lines.joined(separator: "\n"))
        return .object(fields)
    }

    /// Whether a node of this snapshot is inside one of `frames`, at any depth.
    private func inside(_ frames: Set<String>) -> (SnapshotNode) -> Bool {
        let parents = Dictionary(nodes.filter { $0.role == "frame" }.map { ($0.ref, $0.frame) }) { first, _ in first }
        return { node in
            var frame = node.frame
            while let ref = frame {
                if frames.contains(ref) { return true }
                frame = parents[ref] ?? nil
            }
            return false
        }
    }

    /// This snapshot with what `earlier` showed in the frames that didn't answer this time, each
    /// after its frame, as the diff left it: the baseline the next snapshot compares with.
    func keepingUnread(from earlier: PageSnapshot) -> PageSnapshot {
        guard !unread.isEmpty, earlier.document == document else { return self }
        var kept = self
        kept.nodes = nodes.flatMap { node in
            unread.contains(node.ref) ? [node] + earlier.nodes.filter(earlier.inside([node.ref])) : [node]
        }
        return kept
    }
}

extension AgentTab {
    /// Puts the frames' reports together in top-level viewport CSS pixels: each child frame's
    /// nodes follow its frame node, offset by the content boxes on its path and clipped to them.
    func compose(tab id: String, main: FrameReport, children: [FrameReport], origins: [String: String], zoom: Double, maxNodes: Int) -> PageSnapshot {
        let viewport = main.viewport ?? PageViewport(w: 0, h: 0, sx: 0, sy: 0, pw: 0, ph: 0, dpr: 1, vx: 0, vy: 0, vs: 1)
        var byPath: [String: FrameReport] = [:]
        for child in children {
            if let path = child.path, byPath[path] == nil { byPath[path] = child }
        }
        var nodes: [SnapshotNode] = []
        var focused: String?
        var challenge = main.challenge.map { AgentChallenge(kind: $0, page: true) }
        var unread: Set<String> = []

        // Focus goes down from the main frame through the frames focused in their parents: a frame
        // left may keep its activeElement, as the HTML standard has it. `document.hasFocus()` can't tell:
        // it is false in every frame of a tab not shown in the key window, as agents' tabs often are.
        func add(_ report: FrameReport, path: String, offset: (x: Double, y: Double), scale: Double, clip: CGRect, depth: Int, inFrame: String?, focusing: Bool) {
            let document = report.token
            let facts = Dictionary((report.frames ?? []).map { ($0.id, $0) }) { first, _ in first }
            if focusing, let element = report.focused { focused = ref(for: ElementAddress(document: document, id: element)) }
            let place = { (box: [Double]) -> CGRect in
                CGRect(x: offset.x + box[0] * scale, y: offset.y + box[1] * scale, width: box[2] * scale, height: box[3] * scale)
            }
            // Challenge frames count wherever they are, in the snapshot's scope or not.
            for frame in report.frames ?? [] where challenge == nil {
                let child = frame.index >= 0 ? byPath[Self.childPath(path, frame.index)] : nil
                let address = child.flatMap { origins[$0.token] } ?? frame.src
                guard frame.box.count == 4, frame.box[2] >= 20, frame.box[3] >= 20,
                      let kind = (AgentChallenge.isProvider(frame.src) ? AgentChallenge.kind(of: frame.src) : AgentChallenge.kind(of: address)) ?? child?.challenge else { continue }
                let ref = child.map { self.frameRef(for: $0.token) } ?? self.ref(for: ElementAddress(document: document, id: frame.id))
                challenge = AgentChallenge(kind: kind, ref: ref, page: AgentChallenge.pageKinds.contains(kind))
            }
            for raw in report.nodes ?? [] where raw.box.count == 4 {
                let rect = place(raw.box)
                if depth > 0, !rect.intersects(clip) { continue }
                let address = ElementAddress(document: document, id: raw.id)
                var node = SnapshotNode(
                    ref: "", role: raw.role, name: raw.name, level: raw.level, href: raw.href, value: raw.value,
                    filled: raw.filled == true, state: (raw.state ?? []).filter { focusing || $0 != "focused" }, options: raw.options, guardKind: raw.guard,
                    box: [Int(rect.minX.rounded()), Int(rect.minY.rounded()), Int(rect.width.rounded()), Int(rect.height.rounded())],
                    frame: inFrame, depth: depth
                )
                node.off = Self.off(rect, viewport: viewport)
                guard raw.role == "frame", let frame = facts[raw.id], frame.content.count == 5 else {
                    node.ref = ref(for: address)
                    nodes.append(node)
                    continue
                }
                let childPath = Self.childPath(path, frame.index)
                let child = frame.index >= 0 ? byPath[childPath] : nil
                node.origin = child.flatMap { origins[$0.token] } ?? Self.origin(of: frame.src)
                guard let child else {
                    // A frame read before that didn't answer this time keeps its ref; what it showed isn't removed.
                    if let known = frameRef(at: address) {
                        node.ref = known
                        unread.insert(known)
                    } else {
                        node.ref = ref(for: address)
                    }
                    nodes.append(node)
                    continue
                }
                let childRef = frameRef(for: child.token)
                setFrameElement(childRef, address)
                node.ref = childRef
                nodes.append(node)
                let inFocus = focusing && report.focusedFrame == frame.index
                if inFocus, child.focused == nil { focused = childRef }
                let content = frame.content
                let origin = (x: offset.x + content[0] * scale, y: offset.y + content[1] * scale)
                let inner = CGRect(x: origin.x, y: origin.y, width: content[2] * scale, height: content[3] * scale)
                add(child, path: childPath, offset: origin, scale: scale * content[4], clip: depth == 0 ? inner : inner.intersection(clip), depth: depth + 1, inFrame: childRef, focusing: inFocus)
            }
        }
        add(main, path: "", offset: (0, 0), scale: 1, clip: .infinite, depth: 0, inFrame: nil, focusing: true)

        // Over the cap, the nodes nearest the viewport stay, in page order.
        var dropped = 0
        if nodes.count > maxNodes {
            let distance = { (node: SnapshotNode) -> Double in
                guard node.off != nil, node.box.count == 4 else { return 0 }
                let rect = CGRect(x: node.box[0], y: node.box[1], width: node.box[2], height: node.box[3])
                let dx = max(0, -rect.maxX, rect.minX - viewport.w)
                let dy = max(0, -rect.maxY, rect.minY - viewport.h)
                return dx + dy
            }
            let kept = Set(nodes.indices.sorted { (distance(nodes[$0]), $0) < (distance(nodes[$1]), $1) }.prefix(maxNodes))
            dropped = nodes.count - maxNodes
            nodes = nodes.indices.filter(kept.contains).map { nodes[$0] }
        }
        if main.truncated == true || children.contains(where: { $0.truncated == true }) { dropped = max(dropped, 1) }
        return PageSnapshot(
            tab: id, url: main.url ?? "", title: main.title ?? "", viewport: viewport, zoom: zoom,
            focused: focused, challenge: challenge, dropped: dropped, nodes: nodes, document: main.token, unread: unread
        )
    }

    /// Numbers the snapshot for the session: the same number as its last snapshot in the same view
    /// when nothing but boxes changed, the next number otherwise. Returns that last snapshot, the
    /// only one a diff may compare with: a view of another scope or size shows other nodes. What a
    /// frame too slow this time showed before stays in the one kept for the next diff.
    func record(_ snapshot: inout PageSnapshot, session: String) -> PageSnapshot? {
        let key = "\(session) \(snapshot.view)"
        let previous = snapshots[key]
        var baseline = previous.map(snapshot.keepingUnread) ?? snapshot
        if let previous, baseline.hasSameContent(as: previous) {
            snapshot.seq = previous.seq
        } else {
            snapshot.seq = seqs[session, default: 0] + 1
            seqs[session] = snapshot.seq
        }
        baseline.seq = snapshot.seq
        snapshots[key] = baseline
        if shown.count > 20_000 { shown = [:] }
        for node in snapshot.nodes { shown[node.ref] = node }
        return previous
    }

    private static func childPath(_ path: String, _ index: Int) -> String {
        path.isEmpty ? "\(index)" : "\(path).\(index)"
    }

    private static func off(_ rect: CGRect, viewport: PageViewport) -> String? {
        if rect.minY >= viewport.h { return "below" }
        if rect.maxY <= 0 { return "above" }
        if rect.minX >= viewport.w { return "right" }
        if rect.maxX <= 0 { return "left" }
        return nil
    }

    static func origin(of address: String) -> String? {
        guard let url = URL(string: address), let scheme = url.scheme, let host = url.host() else { return nil }
        return "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
    }
}

