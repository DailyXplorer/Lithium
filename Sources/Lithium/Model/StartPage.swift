import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What the start page, shown when no tab is selected, is drawn with. Each kind keeps its own
/// preferences, so going back to one finds its colors or picture as they were.
enum StartBackground: String, CaseIterable {
    case lithium, color, gradient, image, wallpaper

    static let defaultColor = "#2B2D42"

    var showsPicture: Bool { self == .image || self == .wallpaper }
    static let defaultGradient = ("#D5DAF5", "#F6DDE4")
}

extension Preference {
    static let startBackground = "startBackground"
    static let startColor = "startColor"
    static let startGradientFrom = "startGradientFrom"
    static let startGradientTo = "startGradientTo"
    /// The picture's file name in `StartImage.folder`.
    static let startImage = "startImage"
}

/// The picture chosen for the start page, copied into Lithium's own folder so it outlives
/// the original. A new picture gets a new name: the page notices the change, and never shows
/// a half-written file.
enum StartImage {
    static let folder = URL.applicationSupportDirectory.appending(path: "Lithium/Start Page")

    static func url(named name: String) -> URL? {
        name.isEmpty ? nil : folder.appending(path: name)
    }

    static var current: URL? {
        UserDefaults.standard.string(forKey: Preference.startImage).flatMap(url(named:))
    }

    /// Asks for a picture and makes it the start page's background. False when none was chosen.
    @MainActor
    static func choose() async -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a picture for the start page."
        let response = if let window = NSApp.keyWindow { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        guard response == .OK, let file = panel.url, (try? use(file)) != nil else { return false }
        StartPictures.forget()
        UserDefaults.standard.set(StartBackground.image.rawValue, forKey: Preference.startBackground)
        return true
    }

    private static func use(_ file: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = UUID().uuidString + "." + (file.pathExtension.isEmpty ? "image" : file.pathExtension.lowercased())
        try fileManager.copyItem(at: file, to: folder.appending(path: name))
        let previous = UserDefaults.standard.string(forKey: Preference.startImage)
        UserDefaults.standard.set(name, forKey: Preference.startImage)
        if let previous, let old = url(named: previous) { try? fileManager.removeItem(at: old) }
    }
}

/// Pictures decoded at the size of the largest screen, off the main thread. The last one is
/// kept, so the start page shows it at once every time.
@MainActor
enum StartPictures {
    private static var last: (url: URL, image: CGImage)?

    /// Drops the kept picture once the start page no longer shows it, so its bitmap (tens of
    /// megabytes at screen size) doesn't outlive it.
    static func forget() {
        last = nil
    }

    static func cached(_ url: URL?) -> CGImage? {
        guard let url, let last, last.url == url else { return nil }
        return last.image
    }

    static func load(_ url: URL?) async -> CGImage? {
        guard let url else { return nil }
        if let image = cached(url) { return image }
        let side = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 3000
        let image = await Task.detached(priority: .userInitiated) { decode(url, maxPixels: side) }.value
        if let image { last = (url, image) }
        return image
    }

    private nonisolated static func decode(_ url: URL, maxPixels: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixels),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
