import SwiftUI

/// In the toolbar while agent access is on, so an agent is never connected unseen: an outline
/// robot with no agent, filled with one, accent-colored and pulsing while one acts. Its panel
/// lists the sessions and holds Stop.
struct AgentButton: View {
    let agent: AgentHub
    @State private var isPresented = false
    @State private var pulse = false

    var body: some View {
        IconButton(icon: agent.sessions.isEmpty ? .robot : .robotFill, help: help) {
            isPresented.toggle()
        }
        .foregroundStyle(agent.isActing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
        .opacity(agent.isActing && pulse ? 0.45 : 1)
        .animation(agent.isActing ? .easeInOut(duration: 0.6).repeatForever() : .default, value: pulse)
        .onChange(of: agent.isActing, initial: true) { _, acting in pulse = acting }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AgentPanel(agent: agent)
        }
    }

    private var help: String {
        switch agent.state {
        case .stopped: "Agents stopped"
        case .failed: "Agent access isn’t working"
        case .starting, .listening: agent.sessions.isEmpty ? "Agent access on" : "Agent connected"
        }
    }
}

private struct AgentPanel: View {
    let agent: AgentHub
    @Environment(Browser.self) private var browser

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agents").font(Theme.font(15, .semibold))
                Text(AgentStatus.text(agent)).font(Theme.font(12)).foregroundStyle(.secondary)
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

/// One sentence on agent access, shared by the toolbar panel and Settings.
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
