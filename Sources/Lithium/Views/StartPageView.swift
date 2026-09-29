import SwiftUI

/// Shown when no tab is selected. Nothing but the background: typing goes to the address bar,
/// which keeps the keyboard, and a click on the page hands it back.
struct StartPageView: View {
    @Environment(Browser.self) private var browser
    @AppStorage(Preference.startBackground) private var kind = StartBackground.lithium
    @AppStorage(Preference.startColor) private var colorHex = StartBackground.defaultColor
    @AppStorage(Preference.startGradientFrom) private var fromHex = StartBackground.defaultGradient.0
    @AppStorage(Preference.startGradientTo) private var toHex = StartBackground.defaultGradient.1
    @AppStorage(Preference.startImage) private var imageName = ""

    var body: some View {
        background
            .contentShape(Rectangle())
            .onTapGesture { browser.requestAddressFocus() }
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .lithium: LithiumGradient()
        case .color: Color(hex: colorHex)
        case .gradient: LinearGradient(colors: [Color(hex: fromHex), Color(hex: toHex)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .image: PictureBackground(url: StartImage.url(named: imageName))
        case .wallpaper: PictureBackground(url: NSScreen.main.flatMap(NSWorkspace.shared.desktopImageURL(for:)))
        }
    }
}

/// Fills the page without stretching, cropping what overflows. The Lithium gradient shows
/// until the picture is decoded, and stays if it can't be.
private struct PictureBackground: View {
    let url: URL?
    @State private var image: CGImage?

    var body: some View {
        let shown = image ?? StartPictures.cached(url)
        LithiumGradient()
            .overlay {
                if let shown {
                    Image(decorative: shown, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .animation(.easeOut(duration: 0.2), value: shown != nil)
            .task(id: url) { image = await StartPictures.load(url) }
    }
}

struct LithiumGradient: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.58, 0.44], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: (scheme == .dark ? Self.dark : Self.light).map(Color.init(hex:))
        )
    }

    private static let light = [
        "#D5DAF5", "#E6DDF6", "#F6DDE4",
        "#D8ECF3", "#EEEAF8", "#F7E7D4",
        "#DDEFE3", "#E2E5F6", "#F3E1EA",
    ]
    private static let dark = [
        "#1D2036", "#282342", "#35223A",
        "#18293A", "#22233A", "#372A2A",
        "#172B27", "#1E2138", "#2E1F32",
    ]
}
