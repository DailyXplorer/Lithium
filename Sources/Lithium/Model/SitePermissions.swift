import Foundation
import Observation

enum PermissionKind: String, Codable, CaseIterable, Identifiable {
    case camera, microphone, location
    var id: Self { self }

    var label: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        }
    }

    var icon: Phosphor {
        switch self {
        case .camera: .camera
        case .microphone: .microphone
        case .location: .location
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
}

/// Per-site answers to camera, microphone and location prompts. Answers are remembered
/// until the user changes them in Settings; pending prompts wait for the user in the tab.
@MainActor
@Observable
final class SitePermissions {
    private(set) var decisions: [String: [PermissionKind: PermissionDecision]]
    private(set) var pending: [PermissionRequest] = []
    @ObservationIgnored private var waiting: [PermissionRequest.ID: CheckedContinuation<Bool, Never>] = [:]

    private static let storageKey = "sitePermissions"

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: [String: String]] ?? [:]
        decisions = stored.mapValues { entries in
            Dictionary(uniqueKeysWithValues: entries.compactMap { key, value in
                guard let kind = PermissionKind(rawValue: key), let decision = PermissionDecision(rawValue: value) else { return nil }
                return (kind, decision)
            })
        }
    }

    /// Resolves from stored answers when every kind has one; otherwise asks in the tab.
    func request(_ kinds: [PermissionKind], host: String, tabID: Tab.ID) async -> Bool {
        let known = kinds.map { decisions[host]?[$0] }
        if known.contains(.deny) { return false }
        if known.allSatisfy({ $0 == .allow }) { return true }

        let request = PermissionRequest(tabID: tabID, host: host, kinds: kinds)
        return await withCheckedContinuation { continuation in
            waiting[request.id] = continuation
            pending.append(request)
        }
    }

    func answer(_ request: PermissionRequest, allow: Bool) {
        for kind in request.kinds {
            set(allow ? .allow : .deny, for: kind, host: request.host)
        }
        resolve(request.id, allow)
    }

    /// Unanswered prompts of a closed tab are denied, without remembering anything.
    func cancel(tabID: Tab.ID) {
        pending.filter { $0.tabID == tabID }.forEach { resolve($0.id, false) }
    }

    func set(_ decision: PermissionDecision?, for kind: PermissionKind, host: String) {
        var entries = decisions[host] ?? [:]
        entries[kind] = decision
        decisions[host] = entries.isEmpty ? nil : entries
        save()
    }

    private func resolve(_ id: PermissionRequest.ID, _ allow: Bool) {
        pending.removeAll { $0.id == id }
        waiting.removeValue(forKey: id)?.resume(returning: allow)
    }

    private func save() {
        let stored = decisions.mapValues { entries in
            Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value.rawValue) })
        }
        UserDefaults.standard.set(stored, forKey: Self.storageKey)
    }
}
