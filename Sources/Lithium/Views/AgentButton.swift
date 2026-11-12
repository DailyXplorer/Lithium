import SwiftUI

/// In the toolbar while an agent is connected, so one is never connected unseen.
struct AgentButton: View {
    let agent: AgentHub
    @State private var isPresented = false

    var body: some View {
        IconButton(icon: .robotFill, help: help) {
            isPresented.toggle()
        }
        .foregroundStyle(agent.isActing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
        .modifier(ActingPulse(isOn: agent.isActing))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AgentPanel(agent: agent)
        }
    }

    private var help: String { agent.isActing ? "Agent acting" : "Agent connected" }
}

/// Dims what it wraps to 0.45 and back every 1.2 s while `isOn`. A timeline paused when off, not
/// a `repeatForever` animation: SwiftUI never ended that one once a call did (the opacity went
/// back to 1 without an animation to replace it), and the toolbar then redrew at the display's
/// rate for as long as the agent stayed connected, idle page or not.
struct ActingPulse: ViewModifier {
    let isOn: Bool
    @State private var start = Date()

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !isOn)) { context in
            content.opacity(isOn ? Self.opacity(after: context.date.timeIntervalSince(start)) : 1)
        }
        .onChange(of: isOn) { _, isOn in if isOn { start = Date() } }
    }

    /// Eased in and out, as `easeInOut(duration: 0.6).repeatForever()` was.
    static func opacity(after elapsed: TimeInterval) -> Double {
        let dip = (1 - cos(2 * .pi * max(0, elapsed) / 1.2)) / 2
        return 1 - 0.55 * dip
    }
}

struct AgentPanel: View {
    let agent: AgentHub
    @Environment(Browser.self) private var browser

    /// Tabs where the agent met a CAPTCHA or bot check, which only the user can pass.
    private var challenges: [(tab: Tab, challenge: AgentChallenge)] {
        browser.tabs.compactMap { tab in agent.tabs[tab.id]?.challenge.map { (tab, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agents").font(Theme.font(15, .semibold))
                Text(AgentStatus.text(agent)).font(Theme.font(12)).foregroundStyle(.secondary)
            }
            ForEach(challenges, id: \.tab.id) { item in
                ChallengeRow(tab: item.tab, challenge: item.challenge)
            }
            if !agent.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(agent.sessions) { session in
                        SessionRow(session: session, tools: agent.calls.values.filter { $0.session == session.label }.map(\.tool))
                    }
                }
            }
            if !agent.recentLog.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(agent.recentLog.reversed()) { line in
                        LogLineRow(line: line)
                    }
                }
            }
            Divider()
            HStack(spacing: 14) {
                Button("Settings") { browser.openSettings(section: "agents") }
                Button("Open Log") { browser.openAgentLog() }
                Spacer()
                if agent.state == .stopped {
                    Button("Allow Agents Again") { agent.allowAgain() }
                } else {
                    Button("Stop Agent") { agent.stop() }
                        .foregroundStyle(.red)
                        .disabled(agent.state != .listening)
                }
            }
            .buttonStyle(.plain)
            .font(Theme.font(12))
            .foregroundStyle(Color.accentColor)
        }
        .font(Theme.font(13))
        .padding(16)
        .frame(width: 300)
    }
}

private struct SessionRow: View {
    let session: MCPSession
    let tools: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(session.clientName).font(Theme.font(13, .medium)).lineLimit(1)
                Text(session.label).font(Theme.font(11)).foregroundStyle(.tertiary)
            }
            // The name is whatever the client sent in `initialize`.
            Text(tools.isEmpty ? "Self-reported name · idle" : "Self-reported name · running \(tools.sorted().joined(separator: ", "))")
                .font(Theme.font(11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct ChallengeRow: View {
    let tab: Tab
    let challenge: AgentChallenge
    @Environment(Browser.self) private var browser

    var body: some View {
        HStack(spacing: 10) {
            Icon(.hand, size: 18).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("The agent needs you").font(Theme.font(13, .medium))
                Text("\(challenge.label) in “\(tab.displayTitle)”")
                    .font(Theme.font(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Show Tab") { browser.select(tab) }
                .buttonStyle(.plain)
                .font(Theme.font(12))
                .foregroundStyle(Color.accentColor)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// "12:03:05  s1 navigate t3 example.com", with the error code when the call failed.
private struct LogLineRow: View {
    let line: AgentLogLine

    var body: some View {
        HStack(spacing: 6) {
            Text(line.date.formatted(date: .omitted, time: .standard))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Text([line.session, line.tool, line.tab, line.host].compactMap { $0 }.joined(separator: " "))
                .lineLimit(1)
                .truncationMode(.middle)
            if let error = line.error {
                Text(error).foregroundStyle(.red)
            }
        }
        .font(Theme.font(11))
    }
}

enum AgentStatus {
    @MainActor static func text(_ agent: AgentHub?) -> String {
        guard let agent else { return "Off. Agents can’t reach Lithium." }
        switch agent.state {
        case .starting: return "Starting…"
        case .failed(let message): return message
        case .stopped: return "Stopped. Agents can’t connect until you allow them again."
        case .listening:
            switch agent.sessions.count {
            case 0: return "On. No agent connected."
            case 1: return "On. 1 agent connected."
            case let count: return "On. \(count) agents connected."
            }
        }
    }
}
