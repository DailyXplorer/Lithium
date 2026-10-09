import AppKit
import WebKit

/// An agent's input as `NSEvent`s handed straight to one web view, so pages see trusted events.
/// Nothing goes to the window server: the cursor never moves, no other app or Lithium UI can
/// receive them, and no Accessibility permission is needed. Points are in web view coordinates.
@MainActor
final class NativeInput {
    /// The web view left its window mid-action (the user selected the tab); the action may retry.
    struct WindowChanged: Error {
        /// A press was already delivered: the action happened, so it isn't repeated.
        let afterPress: Bool
    }

    /// What `AgentHub.gate` weighed: anything else never reaches the page.
    struct Sends: OptionSet {
        let rawValue: Int
        static let pointer = Sends(rawValue: 1)
        static let buttons = Sends(rawValue: 2)
        static let keys = Sends(rawValue: 4)
    }

    let webView: WKWebView
    private let window: NSWindow
    private let sends: Sends
    /// Runs before every event: the tab closing, the user's own input and Stop end the action there.
    private let check: () throws -> Void
    private let onPointer: (CGPoint) -> Void
    private var held: (button: NSEvent.EventType, at: CGPoint, modifiers: NSEvent.ModifierFlags)?
    private var pressed = false
    private(set) var pointer: CGPoint?

    init(webView: WKWebView, sends: Sends, check: @escaping () throws -> Void, onPointer: @escaping (CGPoint) -> Void) throws {
        guard let window = webView.window else { throw WindowChanged(afterPress: false) }
        self.webView = webView
        self.window = window
        self.sends = sends
        self.check = check
        self.onPointer = onPointer
    }

    private func checkGated(_ kind: Sends) throws {
        guard sends.contains(kind) else {
            assertionFailure("An action sent input its gate didn't weigh.")
            throw AgentToolError(code: "unsupported", message: "Lithium refused input its Guardrails hadn’t weighed.")
        }
    }

    // MARK: Pointer

    func move(to point: CGPoint, steps: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws {
        try checkGated(.pointer)
        let start = pointer ?? point
        for step in 1...max(1, steps) {
            let fraction = Double(step) / Double(max(1, steps))
            let at = CGPoint(x: start.x + (point.x - start.x) * fraction, y: start.y + (point.y - start.y) * fraction)
            try send(mouse: held == nil ? .mouseMoved : .leftMouseDragged, at: at, modifiers: modifiers, clickCount: 0)
        }
    }

    /// The nth press carries clickCount n, so the page sees `dblclick`.
    func click(at point: CGPoint, button: Button, count: Int, modifiers: NSEvent.ModifierFlags) throws {
        for press in 1...max(1, count) {
            try down(at: point, button: button, clickCount: press, modifiers: modifiers)
            try up(clickCount: press)
        }
    }

    func down(at point: CGPoint, button: Button = .left, clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws {
        try checkGated(.buttons)
        if button == .right, let page = webView as? PageWebView { page.agentMenuUntil = .now + .seconds(2) }
        try send(mouse: button.down, at: point, modifiers: modifiers, clickCount: clickCount)
        held = (button.down, point, modifiers)
        pressed = true
    }

    /// Held until sent: an up that fails leaves the button for `release` to let go.
    func up(clickCount: Int = 1) throws {
        guard let held else { return }
        try send(mouse: Self.upType(for: held.button), at: pointer ?? held.at, modifiers: held.modifiers, clickCount: clickCount)
        self.held = nil
    }

    /// A button still down (Stop, the user, an error mid-drag) is let go, wherever the window is.
    func release() {
        guard let held else { return }
        self.held = nil
        post(Self.mouseEvent(Self.upType(for: held.button), at: webView.convert(pointer ?? held.at, to: nil), window: webView.window ?? window, modifiers: held.modifiers, clickCount: 1, pressure: 0))
    }

    /// Phased pixel wheel events of at most 120 px each, at `point`. Returns how many the page will see.
    func wheel(dx: Double, dy: Double, at point: CGPoint) throws -> Int {
        try move(to: point)
        let chunks = max(1, Int((max(abs(dx), abs(dy)) / 120).rounded(.up)))
        var events: [(dx: Double, dy: Double, phase: Int64)] = (0..<chunks).map { index in
            (dx / Double(chunks), dy / Double(chunks), index == 0 ? Self.phaseBegan : Self.phaseChanged)
        }
        events.append((0, 0, Self.phaseEnded))
        for event in events {
            try checkWindow()
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-event.dy.rounded()), wheel2: Int32(-event.dx.rounded()), wheel3: 0) else { continue }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: event.phase)
            // The event has no window: AppKit gives the CG location, flipped by the primary
            // screen's height, as locationInWindow. It is never posted.
            let height = NSScreen.screens.first?.frame.height ?? 0
            let location = webView.convert(point, to: nil)
            cg.location = CGPoint(x: location.x, y: height - location.y)
            guard let wheel = NSEvent(cgEvent: cg) else { continue }
            pressed = true
            post(wheel)
        }
        return events.count
    }

    // MARK: Keys

    func key(_ key: Key, modifiers: NSEvent.ModifierFlags = []) throws {
        try checkGated(.keys)
        let flags = modifiers.union(key.flags)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            try check()
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: (webView.window ?? window).windowNumber, context: nil,
                characters: key.characters(with: flags), charactersIgnoringModifiers: key.charactersIgnoringModifiers(with: flags),
                isARepeat: false, keyCode: key.code
            ) else { continue }
            pressed = true
            post(event)
        }
    }

    /// Text no key types (accents, CJK, emoji), as the Character Viewer and input methods insert it.
    func insert(_ text: String) throws {
        try checkGated(.keys)
        try check()
        pressed = true
        (webView as NSView as? NSTextInputClient)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    // MARK: Delivery

    enum Button: String {
        case left, right, middle

        var down: NSEvent.EventType {
            switch self {
            case .left: .leftMouseDown
            case .right: .rightMouseDown
            case .middle: .otherMouseDown
            }
        }
    }

    private static func upType(for down: NSEvent.EventType) -> NSEvent.EventType {
        switch down {
        case .rightMouseDown: .rightMouseUp
        case .otherMouseDown: .otherMouseUp
        default: .leftMouseUp
        }
    }

    private func checkWindow() throws {
        try check()
        guard webView.window === window else {
            release()
            throw WindowChanged(afterPress: pressed)
        }
    }

    private func send(mouse type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int) throws {
        try checkWindow()
        let pressure: Float = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged].contains(type) ? 1 : 0
        pointer = point
        onPointer(point)
        post(Self.mouseEvent(type, at: webView.convert(point, to: nil), window: window, modifiers: modifiers, clickCount: clickCount, pressure: pressure))
    }

    private static var eventNumber = 1_000_000

    /// A new `eventNumber` per press: WebKit tells a double click from two clicks by it.
    private static func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow, modifiers: NSEvent.ModifierFlags, clickCount: Int, pressure: Float) -> NSEvent {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) { eventNumber += 1 }
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clickCount, pressure: pressure
        )!
        // AppKit's factory leaves an other button's number at 0, which WebKit takes for the left
        // button: a middle click would follow a link in place.
        guard [.otherMouseDown, .otherMouseUp].contains(type), let cg = event.cgEvent else { return event }
        cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
        cg.setIntegerValueField(.mouseEventNumber, value: Int64(eventNumber))
        return NSEvent(cgEvent: cg) ?? event
    }

    /// Straight to the web view, never `window.sendEvent`: it can't land on Lithium's overlays.
    private func post(_ event: NSEvent) {
        Self.note(event)
        switch event.type {
        case .mouseMoved: webView.mouseMoved(with: event)
        case .leftMouseDown: webView.mouseDown(with: event)
        case .leftMouseUp: webView.mouseUp(with: event)
        case .leftMouseDragged: webView.mouseDragged(with: event)
        case .rightMouseDown: webView.rightMouseDown(with: event)
        case .rightMouseUp: webView.rightMouseUp(with: event)
        case .otherMouseDown: webView.otherMouseDown(with: event)
        case .otherMouseUp: webView.otherMouseUp(with: event)
        case .scrollWheel: webView.scrollWheel(with: event)
        case .keyDown: webView.keyDown(with: event)
        case .keyUp: webView.keyUp(with: event)
        default: break
        }
    }

    private static let phaseBegan: Int64 = 1
    private static let phaseChanged: Int64 = 2
    private static let phaseEnded: Int64 = 4

    // MARK: Key guard

    /// Marks agent events on the event itself: WebKit sends keys a page doesn't handle back through
    /// `NSApp.sendEvent`, however much later, where they would reach Lithium's menus.
    private static let agentsKey = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

    private static func note(_ event: NSEvent) {
        objc_setAssociatedObject(event, agentsKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func isAgents(_ event: NSEvent) -> Bool {
        objc_getAssociatedObject(event, agentsKey) != nil
    }

    /// An agent's ⌘W reaches the page as a `keydown` and never closes a tab.
    static func guarded(_ event: NSEvent) -> NSEvent? {
        isAgents(event) ? nil : event
    }

    static func installKeyGuard() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            MainActor.assumeIsolated { isAgents(event) } ? nil : event
        }
    }
}

/// A key on a US keyboard: its virtual key code and the characters it types.
struct NativeKey: Equatable {
    let code: UInt16
    let characters: String
    /// Shift for an uppercase letter or a shifted symbol; Function for arrows and F keys.
    var flags: NSEvent.ModifierFlags = []
    var shifted: String?

    func characters(with flags: NSEvent.ModifierFlags) -> String {
        if flags.contains(.shift), code == 48 { return "\u{19}" }
        if flags.contains(.control), characters.count == 1, let scalar = characters.lowercased().unicodeScalars.first, ("a"..."z").contains(scalar) {
            return String(UnicodeScalar(UInt8(scalar.value - 96)))
        }
        return charactersIgnoringModifiers(with: flags)
    }

    /// As AppKit gives it: every modifier ignored but Shift.
    func charactersIgnoringModifiers(with flags: NSEvent.ModifierFlags) -> String {
        flags.contains(.shift) ? shifted ?? characters : characters
    }

    /// Enter, or a combination that types a carriage return like it (Control+M).
    func isEnter(with modifiers: NSEvent.ModifierFlags) -> Bool {
        code == 36 || characters(with: modifiers.union(flags)) == "\r"
    }

    var isSpace: Bool { code == 49 }

    /// Whether the key types a printable character into a field.
    func types(with modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.union(self.flags)
        return flags.isDisjoint(with: [.command, .control, .function]) && characters(with: flags).unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    /// The key that types `character` on a US layout, nil for one no key types (é, ✓, 日).
    static func typing(_ character: Character) -> NativeKey? {
        let text = String(character)
        if let code = letters[text] { return NativeKey(code: code, characters: text, shifted: text.uppercased()) }
        if let code = letters[text.lowercased()], text != text.lowercased() { return NativeKey(code: code, characters: text.lowercased(), flags: .shift, shifted: text) }
        if let (base, code) = symbols.first(where: { $0.value.shifted == text }).map({ ($0.key, $0.value.code) }) {
            return NativeKey(code: code, characters: base, flags: .shift, shifted: text)
        }
        if let symbol = symbols[text] { return NativeKey(code: symbol.code, characters: text, shifted: symbol.shifted) }
        if text == " " { return named["Space"] }
        return nil
    }

    private static let letters: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    private static let symbols: [String: (code: UInt16, shifted: String)] = [
        "1": (18, "!"), "2": (19, "@"), "3": (20, "#"), "4": (21, "$"), "6": (22, "^"), "5": (23, "%"), "=": (24, "+"),
        "9": (25, "("), "7": (26, "&"), "-": (27, "_"), "8": (28, "*"), "0": (29, ")"), "]": (30, "}"), "[": (33, "{"),
        "'": (39, "\""), ";": (41, ":"), "\\": (42, "|"), ",": (43, "<"), "/": (44, "?"), ".": (47, ">"), "`": (50, "~"),
    ]

    static let named: [String: NativeKey] = {
        let function = { (code: UInt16, key: Int) in NativeKey(code: code, characters: String(UnicodeScalar(UInt32(key))!), flags: .function) }
        var keys: [String: NativeKey] = [
            "Enter": NativeKey(code: 36, characters: "\r"), "Tab": NativeKey(code: 48, characters: "\t"),
            "Space": NativeKey(code: 49, characters: " "), "Backspace": NativeKey(code: 51, characters: "\u{7F}"),
            "Escape": NativeKey(code: 53, characters: "\u{1B}"),
            "ArrowUp": function(126, NSUpArrowFunctionKey), "ArrowDown": function(125, NSDownArrowFunctionKey),
            "ArrowLeft": function(123, NSLeftArrowFunctionKey), "ArrowRight": function(124, NSRightArrowFunctionKey),
            "Home": function(115, NSHomeFunctionKey), "End": function(119, NSEndFunctionKey),
            "PageUp": function(116, NSPageUpFunctionKey), "PageDown": function(121, NSPageDownFunctionKey),
            "Delete": function(117, NSDeleteFunctionKey),
        ]
        let fCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in fCodes.enumerated() { keys["F\(index + 1)"] = function(code, NSF1FunctionKey + index) }
        return keys
    }()

    private static let aliases: [String: String] = {
        var aliases = ["return": "Enter", "esc": "Escape", " ": "Space"]
        for name in named.keys { aliases[name.lowercased()] = name }
        return aliases
    }()

    /// `Meta+K`, `Shift+Tab`, `ArrowDown`: the key and its modifiers, nil for an unknown name.
    static func parse(_ combo: String) -> (key: NativeKey, name: String, modifiers: NSEvent.ModifierFlags)? {
        var parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "+" and "Meta++" name the plus key.
        if combo == "+" || combo.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
        guard let name = parts.popLast(), !name.isEmpty else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts {
            switch part.lowercased() {
            case "meta", "command", "cmd": modifiers.insert(.command)
            case "control", "ctrl": modifiers.insert(.control)
            case "alt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        if let canonical = aliases[name.lowercased()], let key = named[canonical] { return (key, canonical, modifiers) }
        guard name.count == 1, let key = typing(Character(name)) else { return nil }
        // Meta+K is the k key with Command, not Shift-k; Shift+K is K.
        if key.flags.contains(.shift), name.lowercased() != name, !modifiers.isEmpty {
            return (NativeKey(code: key.code, characters: key.characters, shifted: key.shifted), name.lowercased(), modifiers)
        }
        return (key, name, modifiers)
    }
}

extension NativeInput {
    typealias Key = NativeKey
}
