import SwiftUI

/// Shown while an agent acts in the tab (design section 5.7). The system cursor stays where the
/// user left it, and the overlay never takes a click.
struct AgentActingOverlay: View {
    let acting: AgentActing

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
            HStack(spacing: 6) {
                Icon(.robotFill, size: 12)
                Text(acting.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(Theme.font(12, .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.accentColor))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .padding(.top, 10)
            .padding(.horizontal, 40)
            if let pointer = acting.pointer {
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .position(pointer)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("An agent is acting: \(acting.caption)")
    }
}
