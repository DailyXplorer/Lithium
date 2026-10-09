import Foundation
import Observation

enum PermissionKind: String, Codable, CaseIterable, Identifiable {
    case camera, microphone, location, downloads
    var id: Self { self }

    var label: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .downloads: "Downloads"
        }
    }

    var icon: Phosphor {
        switch self {
        case .camera: .camera
        case .microphone: .microphone
        case .location: .location
        case .downloads: .download
        }
    }
}

enum PermissionDecision: String, Codable {
    case allow, deny
}

/// A site asking for one or more capabilities; answered once for all of them.
struct PermissionRequest: Identifiable, Equatable {
    let id = UUID()
    let tabID: Tab.ID
    let host: String
    let kinds: [PermissionKind]
    /// The private session (its tabs' data store) the request comes from; nil for a normal tab.
    var privateSession: ObjectIdentifier? = nil
    /// The space keeping its data apart the request comes from (`Tab.siteSpace`).
    var space: Space.ID? = nil
}

/// Per-site answers to camera, microphone, location and download prompts. Answers are remembered
/// until the user changes them in Settings; pending prompts wait for the user in the tab.
/// A private tab's answers stay in memory for its private session only: saved, they would
/// record the site it visited, and carry its grant into normal browsing. A space that keeps its
/// data apart has its own answers too, as another identity, kept until Lithium quits: Settings
/// lists only the shared ones, so a saved grant there could never be taken back.
@MainActor
@Observable
final class SitePermissions {
    private(set) var decisions: [String: [PermissionKind: PermissionDecision]]
    private(set) var pending: [PermissionRequest] = []
    @ObservationIgnored private var waiting: [PermissionRequest.ID: [CheckedContinuation<Bool, Never>]] = [:]
    private var privateDecisions: [ObjectIdentifier: [String: [PermissionKind: PermissionDecision]]] = [:]
    private var spaceDecisions: [Space.ID: [String: [PermissionKind: PermissionDecision]]] = [:]

    /// Saved answers this build doesn't know (a newer build's kind or decision), written back as
    /// they were, so running an older build doesn't erase them.
    @ObservationIgnored private var unknown: [String: [String: String]] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    private static let storageKey = "sitePermissions"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.storageKey) as? [String: [String: String]] ?? [:]
        var decisions: [String: [PermissionKind: PermissionDecision]] = [:]
        for (host, entries) in stored {
            for (key, value) in entries {
                if let kind = PermissionKind(rawValue: key), let decision = PermissionDecision(rawValue: value) {
                    decisions[host, default: [:]][kind] = decision
                } else {
                    unknown[host, default: [:]][key] = value
                }
            }
        }
        self.decisions = decisions
    }

    /// The answers that count for `host`: a private session's own, a separate space's own, or the
    /// saved ones.
    func decisions(for host: String, privateSession: ObjectIdentifier?, space: Space.ID? = nil) -> [PermissionKind: PermissionDecision] {
        let stored = if let privateSession {
            privateDecisions[privateSession]?[host]
        } else if let space {
            spaceDecisions[space]?[host]
        } else {
            decisions[host]
        }
        return stored ?? [:]
    }

    /// Resolves from stored answers when every kind has one; otherwise asks in the tab.
    /// `privateSession` is set for a private tab: only that session's own answers count, as the
    /// normal ones would tell the site who this is; likewise `space` for a separate space's tab.
    func request(_ kinds: [PermissionKind], host: String, tabID: Tab.ID, privateSession: ObjectIdentifier? = nil, space: Space.ID? = nil) async -> Bool {
        let stored = decisions(for: host, privateSession: privateSession, space: space)
        let known = kinds.map { stored[$0] }
        if known.contains(.deny) { return false }
        if known.allSatisfy({ $0 == .allow }) { return true }

        // The same question again (a frame retrying its download) waits on the prompt already shown.
        if let shown = pending.first(where: { $0.tabID == tabID && $0.host == host && $0.kinds == kinds }) {
            return await withCheckedContinuation { waiting[shown.id, default: []].append($0) }
        }
        let request = PermissionRequest(tabID: tabID, host: host, kinds: kinds, privateSession: privateSession, space: space)
        return await withCheckedContinuation { continuation in
            waiting[request.id] = [continuation]
            pending.append(request)
        }
    }

    func answer(_ request: PermissionRequest, allow: Bool) {
        if let session = request.privateSession {
            for kind in request.kinds {
                privateDecisions[session, default: [:]][request.host, default: [:]][kind] = allow ? .allow : .deny
            }
        } else if let space = request.space {
            for kind in request.kinds {
                spaceDecisions[space, default: [:]][request.host, default: [:]][kind] = allow ? .allow : .deny
            }
        } else {
            for kind in request.kinds {
                set(allow ? .allow : .deny, for: kind, host: request.host)
            }
        }
        resolve(request.id, allow)
    }

    /// The private session's last tab closed: its answers go with its cookies.
    func forget(privateSession: ObjectIdentifier) {
        privateDecisions[privateSession] = nil
    }

    /// The space was deleted, its store with it.
    func forget(space: Space.ID) {
        spaceDecisions[space] = nil
    }

    /// Denied this once, without remembering anything: the prompt dismissed with Escape.
    func dismiss(_ request: PermissionRequest) {
        resolve(request.id, false)
    }

    /// Unanswered prompts of a closed tab, or of the page it left, are denied, without remembering anything.
    func cancel(tabID: Tab.ID) {
        pending.filter { $0.tabID == tabID }.forEach { resolve($0.id, false) }
    }

    func set(_ decision: PermissionDecision?, for kind: PermissionKind, host: String) {
        var entries = decisions[host] ?? [:]
        entries[kind] = decision
        decisions[host] = entries.isEmpty ? nil : entries
        // A newer build's decision for this kind gives way to the user's answer here.
        unknown[host]?[kind.rawValue] = nil
        save()
    }

    private func resolve(_ id: PermissionRequest.ID, _ allow: Bool) {
        pending.removeAll { $0.id == id }
        waiting.removeValue(forKey: id)?.forEach { $0.resume(returning: allow) }
    }

    private func save() {
        var stored = unknown
        for (host, entries) in decisions {
            for (kind, decision) in entries { stored[host, default: [:]][kind.rawValue] = decision.rawValue }
        }
        defaults.set(stored, forKey: Self.storageKey)
    }
}
