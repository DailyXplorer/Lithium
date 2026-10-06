import AppKit
import MachO

/// Every hand-off from Lithium to another app: an address of another app's scheme (`mailto:`), a
/// file to open, one to show in Finder. In tests nothing opens: the hand-off is only recorded, so a
/// test can't launch the user's mail app or PDF viewer on their screen.
@MainActor
enum ExternalApps {
    enum HandOff: Equatable {
        case open(URL)
        case openWith(URL, app: URL)
        case reveal(URL)
    }

    /// Fails closed: anything but the Lithium app itself, out of any test, only records.
    /// `scripts/test` sets `LITHIUM_NO_EXTERNAL_OPEN`; a test bundle loaded some other way
    /// (`swift test` run directly, Xcode) is caught by what the process has loaded.
    static let isRecording = ProcessInfo.processInfo.environment["LITHIUM_NO_EXTERNAL_OPEN"] != nil
        || runsTests
        || !Bundle.main.bundlePath.hasSuffix(".app")

    static let runsTests: Bool = {
        if NSClassFromString("XCTestCase") != nil { return true }
        let name = ProcessInfo.processInfo.processName.lowercased()
        if name.contains("xctest") || name.contains("swiftpm-testing-helper") || name.hasSuffix("packagetests") { return true }
        return (0..<_dyld_image_count()).contains { index in
            _dyld_get_image_name(index).map { isTestImage(String(cString: $0)) } ?? false
        }
    }()

    /// Whole names only: every AppKit app loads the system's RecapPerformanceTesting.framework,
    /// which once made Lithium itself record its hand-offs and open nothing.
    static func isTestImage(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.contains { $0 == "XCTest.framework" || $0 == "Testing.framework" || $0.hasSuffix(".xctest") }
            || components.last?.hasPrefix("lib_Testing") == true
    }

    private(set) static var recorded: [HandOff] = []

    static func open(_ url: URL) { handOff(.open(url)) }

    static func open(_ file: URL, withApplicationAt app: URL) { handOff(.openWith(file, app: app)) }

    static func reveal(_ file: URL) { handOff(.reveal(file)) }

    private static func handOff(_ handOff: HandOff) {
        guard !isRecording else {
            recorded.append(handOff)
            return
        }
        switch handOff {
        case .open(let url): NSWorkspace.shared.open(url)
        case .openWith(let file, let app): NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .reveal(let file): NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
}
