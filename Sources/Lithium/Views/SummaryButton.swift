import SwiftUI

struct SummaryButton: View {
    let tab: Tab?
    @Environment(Browser.self) private var browser

    var body: some View {
        @Bindable var summaries = browser.summaries
        let page = PageSummaries.page(of: tab?.url)
        if summaries.isEnabled {
            IconButton(icon: .sparkle, help: "Summarize (⇧⌘S)", isEnabled: page != nil) {
                if let tab { summaries.togglePanel(for: tab) }
            }
            .popover(isPresented: $summaries.isPanelPresented, arrowEdge: .bottom) {
                if let tab { SummaryPanel(tab: tab) }
            }
            // The popover belongs to one tab and one page.
            .onChange(of: tab?.id) { summaries.isPanelPresented = false }
            .onChange(of: page) { summaries.isPanelPresented = false }
        }
    }
}

private struct SummaryPanel: View {
    let tab: Tab
    @Environment(Browser.self) private var browser

    var body: some View {
        let summaries = browser.summaries
        let state = summaries.state(for: tab)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Summary").font(Theme.font(15, .semibold))
                Text(subtitle(state)).font(Theme.font(12)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let reason = summaries.unavailableReason {
                note(reason)
            } else {
                switch state {
                case .ready(let summary):
                    SummaryBody(summary: summary)
                case .failed(let message):
                    note(message)
                case .working(let source, let isLong):
                    progress(source == .page ? "Reading the page…" : "Reading the selection…", detail: isLong ? "Long pages take a minute or so." : nil)
                case nil:
                    progress("Reading the page…", detail: nil)
                }
            }
            Divider()
            Text("Summaries can contain mistakes.")
                .font(Theme.font(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.font(13))
        .padding(16)
        .frame(width: 340)
    }

    private func subtitle(_ state: PageSummaries.State?) -> String {
        let source: SummarySource? = switch state {
        case .ready(let summary): summary.source
        case .working(let source, _): source
        default: nil
        }
        if source == .selection { return "Selected text" }
        let url = PageSummaries.page(of: tab.url)
        return url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url?.lastPathComponent ?? ""
    }

    private func note(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func progress(_ text: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).foregroundStyle(.secondary)
                if let detail { Text(detail).font(Theme.font(11)).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SummaryBody: View {
    let summary: PageSummaries.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !summary.content.overview.isEmpty {
                Text(summary.content.overview).font(Theme.font(13, .medium))
            }
            if !summary.content.points.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(summary.content.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(.secondary)
                            Text(point)
                        }
                    }
                }
            }
            if summary.isPartial {
                Text("This \(summary.source == .page ? "page" : "selection") is long, so the summary covers only its start.")
                    .font(Theme.font(11))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}
