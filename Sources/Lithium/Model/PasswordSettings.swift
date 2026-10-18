import AppKit
import UniformTypeIdentifiers

/// Settings › Passwords. What the page gets never holds a password: Show answers with one, after
/// Touch ID; Copy puts it on the pasteboard without the page seeing it.
extension PasswordManager {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// One of the page's actions, answered with the section's state unless it says otherwise.
    func answerSettings(_ action: String, _ value: Any?, window: NSWindow?) async -> (Any?, String?) {
        var report = ""
        switch action {
        case "passwords":
            break
        case "setPasswordOffers":
            offersPasswords = value as? Bool ?? true
        case "setPasswordUnlock":
            if let policy = (value as? String).flatMap(UnlockPolicy.init(rawValue:)) { unlockPolicy = policy }
        case "revealPassword":
            guard let credential = await authorized(value, reason: "show a password") else { return (nil, "Not allowed") }
            return (["password": credential.password], nil)
        case "copyPassword":
            guard let credential = await authorized(value, reason: "copy a password") else { return (nil, "Not allowed") }
            let board = pasteboard()
            board.clearContents()
            board.declareTypes([.string, Self.concealedType], owner: nil)
            board.setString(credential.password, forType: .string)
            board.setData(Data(), forType: Self.concealedType)
        case "savePasswordEdit":
            guard let edit = value as? [String: Any], let id = (edit["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let username = edit["username"] as? String else { return (nil, "No account") }
            let password = edit["password"] as? String ?? ""
            if !password.isEmpty, await authorized(id.uuidString, reason: "change a password") == nil { return (nil, "Not allowed") }
            _ = await contents()
            change { vault in
                guard let index = vault.credentials.firstIndex(where: { $0.id == id }) else { return }
                vault.credentials[index].username = username
                if !password.isEmpty { vault.credentials[index].password = password }
                vault.credentials[index].modified = .now
            }
        case "deletePassword":
            guard let id = (value as? String).flatMap(UUID.init(uuidString:)) else { return (nil, "No account") }
            _ = await contents()
            change { $0.credentials.removeAll { $0.id == id } }
        case "removeNeverSaved":
            guard let site = value as? String else { return (nil, "No site") }
            _ = await contents()
            change { $0.neverSaved.removeAll { $0 == site } }
        case "importPasswords":
            report = await importFile(window: window)
        case "exportPasswords":
            report = await exportFile(as: (value as? String).flatMap(PasswordCSV.Format.init(rawValue:)) ?? .chrome, window: window)
        default:
            return (nil, "Unknown action")
        }
        return (await settingsState(report: report), nil)
    }

    /// Sorted by site, then username; ids and names only.
    func settingsState(report: String = "") async -> [String: Any] {
        let loaded = await contents()
        let vault = (try? loaded.get()) ?? VaultContents()
        let accounts = vault.credentials.sorted {
            ($0.site, $0.username.lowercased(), $0.host) < ($1.site, $1.username.lowercased(), $1.host)
        }
        let failure: VaultError? = if case let .failure(error) = loaded { error } else { saveError }
        return [
            "offers": offersPasswords,
            "unlock": unlockPolicy.rawValue,
            "accounts": accounts.map { ["id": $0.id.uuidString, "site": $0.site, "host": $0.host, "username": $0.username] },
            "neverSaved": vault.neverSaved,
            "error": failure.map(Self.message) ?? "",
            "report": report,
        ]
    }

    static func message(for error: VaultError) -> String {
        switch error {
        case .noKey: "Lithium can’t reach the key to your passwords on this Mac."
        case .damaged: "Your passwords file is damaged, so Lithium leaves it as it is."
        case .unknownVersion: "Your passwords were saved by a newer version of Lithium."
        case .unwritable: "Lithium couldn’t save your passwords."
        }
    }

    /// The account `id` names, once the user passed Touch ID or the policy doesn't ask.
    private func authorized(_ id: Any?, reason: String) async -> Credential? {
        guard let id = (id as? String).flatMap(UUID.init(uuidString:)), case let .success(vault) = await contents(),
              let credential = vault.credentials.first(where: { $0.id == id }),
              await lock.authorize(.reveal, reason: reason) else { return nil }
        return credential
    }

    /// Read straight from the chosen file: no copy of it is made.
    private func importFile(window: NSWindow?) async -> String {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        let response = if let window { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        guard response == .OK, let url = panel.url else { return "" }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
              let parsed = PasswordCSV.parse(text) else { return "That file isn’t a password export Lithium can read." }
        guard case .success = await contents() else { return "" }
        guard var report = change({ $0.merge(parsed.entries, now: .now) }) else { return "" }
        report.skipped += parsed.skipped
        return "Added \(report.added), updated \(report.updated), skipped \(report.skipped)"
    }

    /// Warned first, and asked for Touch ID: the file holds every password in clear. Written
    /// straight to the chosen file, readable by its owner only.
    private func exportFile(as format: PasswordCSV.Format, window: NSWindow?) async -> String {
        guard case let .success(vault) = await contents() else { return "" }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Export passwords?"
        alert.informativeText = "The file isn’t encrypted. Anyone who can open it can read your passwords."
        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Cancel")
        let warned = if let window, window.isVisible { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        guard warned == .alertFirstButtonReturn, await lock.authorize(.reveal, reason: "export your passwords") else { return "" }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Lithium Passwords.csv"
        let response = if let window { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        guard response == .OK, let url = panel.url else { return "" }
        let data = Data(PasswordCSV.export(vault.credentials, as: format).utf8)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let file = try? FileHandle(forWritingTo: url) else { return "Lithium couldn’t write that file." }
        defer { try? file.close() }
        guard (try? file.write(contentsOf: data)) != nil else { return "Lithium couldn’t write that file." }
        return vault.credentials.count == 1 ? "Exported 1 password" : "Exported \(vault.credentials.count) passwords"
    }
}
