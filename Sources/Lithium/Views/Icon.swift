import AppKit
import SwiftUI

/// Phosphor icons (regular weight, MIT), bundled as SVG and drawn as template images.
enum Phosphor: String {
    case sidebar = "sidebar-simple"
    case back = "caret-left"
    case caretUp = "caret-up"
    case caretDown = "caret-down"
    case forward = "caret-right"
    case reload = "arrow-clockwise"
    case close = "x"
    case lock = "lock-simple"
    case lockOpen = "lock-simple-open"
    case shield = "shield-check"
    case shieldOff = "shield-slash"
    case more = "dots-three"
    case plus
    case search = "magnifying-glass"
    case history = "clock-counter-clockwise"
    case trash
    case globe = "globe-simple"
    case camera = "video-camera"
    case screenshot = "camera"
    case microphone
    case location = "map-pin"
    case download = "download-simple"
    case copy
    case folder = "folder-simple"
    case retry = "arrow-counter-clockwise"
    case settings = "gear-six"
    case sparkle
    case puzzle = "puzzle-piece"
    case minus
    case printer
    case thumbnails = "squares-four"
    case outline = "list-bullets"
    case fitWidth = "arrows-out-line-horizontal"
    case fitPage = "frame-corners"
    case play = "play-fill"
    case pause = "pause-fill"
    case speaker = "speaker-high"
    case speakerOff = "speaker-slash"
    case returnToTab = "arrow-square-in"
    case popout = "picture-in-picture"
    case pen = "pencil-simple"
    case highlighter
    case arrow = "arrow-up-right"
    case rectangle = "square"
    case ellipse = "circle"
    case undo = "arrow-u-up-left"
    case redo = "arrow-u-up-right"
    case robot
    case robotFill = "robot-fill"
    case hand

    @MainActor private static var cache: [Phosphor: NSImage] = [:]

    @MainActor var image: NSImage {
        if let cached = Self.cache[self] { return cached }
        let image = Resources.bundle.url(forResource: rawValue, withExtension: "svg")
            .flatMap(NSImage.init(contentsOf:)) ?? NSImage()
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        Self.cache[self] = image
        return image
    }
}

struct Icon: View {
    let icon: Phosphor
    var size: CGFloat = 16

    init(_ icon: Phosphor, size: CGFloat = 16) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Image(nsImage: icon.image)
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
