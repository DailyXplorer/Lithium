import SwiftUI

/// Over a tab whose page a filter list blocked: what blocked it and why, and the ways on.
struct BlockedPageLayer: View {
    let tab: Tab
    @Environment(Browser.self) private var browser

    var body: some View {
        if let page = tab.blockedPage {
            BlockedPageView(page: page, isPrivate: tab.isEphemeral) {
                // Like a browser's warning page: with nowhere to go back to, the tab goes.
                if tab.canGoBack { browser.navigate(tab, .back) } else { browser.close(tab) }
            } onOpen: { always in
                Task { await tab.letBlockedPageThrough(always: always) }
            }
        }
    }
}

struct BlockedPageView: View {
    let page: BlockedPage
    let isPrivate: Bool
    let onBack: () -> Void
    let onOpen: (_ always: Bool) -> Void
    /// The page appears where a click was on its way to a link: that click can't land on a button.
    @State private var protection = ClickProtection()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Icon(.shield, size: 36)
                .foregroundStyle(Color.accentColor)
            Text("Lithium blocked this page")
                .font(Theme.font(22, .semibold))
            Text(page.url.absoluteString)
                .font(Theme.font(13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let reason = page.reason {
                VStack(alignment: .leading, spacing: 8) {
                    Text(BlockedPage.explanation(of: BlockedPage.kind(of: reason.list)))
                    if let list = reason.list {
                        (Text("Blocked by ") + Text(BlockedPage.title(of: list)).fontWeight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let filter = reason.filter {
                        // Some filters name hundreds of sites: the buttons stay in view, the
                        // whole filter in the tooltip.
                        Text(filter)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(4)
                            .truncationMode(.middle)
                            .help(filter)
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
                .font(Theme.font(14))
                .transition(.opacity)
            }
            HStack(spacing: 8) {
                Button("Go back") { act(onBack) }
                    .buttonStyle(.borderedProminent)
                Button("Open anyway") { act { onOpen(false) } }
                Button("Always allow this site") { act { onOpen(true) } }
            }
            .controlSize(.large)
            .padding(.top, 6)
            Text(isPrivate ? "Always allow lasts until the private tabs close." : "Sites you always allow are listed in Settings.")
                .font(Theme.font(12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .animation(.snappy(duration: 0.2), value: page.reason)
        .onAppear { protection.rearm() }
        .onChange(of: page.url) { protection.rearm() }
    }

    private func act(_ action: () -> Void) {
        guard protection.accepts() else { return }
        action()
    }
}
