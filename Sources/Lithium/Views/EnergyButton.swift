import SwiftUI

/// Shown while energy saving is on, so tabs sleeping sooner never comes as a surprise.
struct EnergyButton: View {
    @Environment(Browser.self) private var browser
    @State private var isPresented = false

    var body: some View {
        IconButton(icon: .leaf, help: "Energy saving on") {
            isPresented.toggle()
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            EnergyPanel(mode: browser.energy.mode) {
                isPresented = false
                browser.openSettings(section: "advanced")
            }
        }
    }
}

struct EnergyPanel: View {
    let mode: EnergySaving
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Icon(.leaf, size: 18).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Energy saving is on").font(Theme.font(15, .semibold))
                    Text(mode == .always ? "Always" : "On battery or in Low Power Mode")
                        .font(Theme.font(12))
                        .foregroundStyle(.secondary)
                }
            }
            Text("Background tabs sleep after 5 minutes and their silent videos pause. The tab you’re on and tabs playing sound are left alone.")
                .font(Theme.font(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Button("Settings", action: openSettings)
                .buttonStyle(.plain)
                .font(Theme.font(12))
                .foregroundStyle(Color.accentColor)
        }
        .font(Theme.font(13))
        .padding(16)
        .frame(width: 280)
    }
}
