import SwiftUI

/// At the foot of the tab list, with two windows or more: each other window's tabs, as they change
/// there. A click shows the tab in its window; its menu moves it into this one.
struct OtherWindowSections: View {
    @Environment(Browser.self) private var browser
    @Environment(BrowserWindow.self) private var window

    var body: some View {
        // With one window, the count is all the sidebar reads.
        if browser.windows.count > 1 {
            ForEach(window.otherWindowSections) { section in
                VStack(spacing: 2) {
                    OtherWindowHeader(section: section, isCollapsed: window.collapsedOtherWindows.contains(section.id))
                    if !window.collapsedOtherWindows.contains(section.id) {
                        ForEach(section.tabs) { OtherWindowTabRow(tab: $0) }
                    }
                }
            }
        }
    }
}

private struct OtherWindowHeader: View {
    let section: BrowserWindow.OtherWindowSection
    let isCollapsed: Bool
    @Environment(BrowserWindow.self) private var window

    var body: some View {
        HStack(spacing: 6) {
            Text(section.title)
            Spacer(minLength: 0)
            if isCollapsed, !section.tabs.isEmpty {
                Text("\(section.tabs.count)")
                    .monospacedDigit()
            }
            Icon(isCollapsed ? .forward : .caretDown, size: 10)
                .frame(width: 18, height: 18)
        }
        .font(Theme.font(11.5, .medium))
        .opacity(0.55)
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { window.toggleOtherWindow(section.id) } }
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
    }
}

private struct OtherWindowTabRow: View {
    let tab: Tab
    @Environment(Browser.self) private var browser
    @Environment(BrowserWindow.self) private var window

    var body: some View {
        SidebarRow(isSelected: false, action: { browser.select(tab) }) {
            Favicon(image: tab.favicon, fallback: tab.url?.host() ?? "", size: 16)
                .frame(width: 16, height: 16)
            Text(tab.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .opacity(0.8)
        .contextMenu {
            Button("Move to This Window") { withAnimation(.snappy(duration: 0.2)) { browser.move(tab, to: window) } }
        }
    }
}
