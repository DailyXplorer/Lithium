import AppKit

/// What a file chooser opened in a tab the agent drives gets instead of the user's panel.
enum AgentOpenPanel: Equatable {
    case files([URL])
    case cancelled
}

/// Addresses, downloads and uploads: Lithium asks the user nothing about them. The agent acts as
/// the user's own click would, and what is sensitive is the agent's to raise with its user.
extension AgentHub {
    func checkOpenable(_ url: URL) throws {
        if case .blocked(let reason) = AgentURLs.verdict(for: url) { throw AgentToolError(code: "blocked_page", message: reason) }
    }

    // MARK: Downloads

    /// Hooked from `Tab` before a download starts. True when the agent's input started it: it
    /// then goes ahead with none of the prompts a page's own download gets.
    func startedDownload(in tab: Tab) -> Bool {
        drive(of: tab) != nil
    }

    // MARK: Uploads

    /// Arms the tab's file chooser with `files`, for one use within 5 seconds.
    func armUpload(_ files: [URL], in state: AgentTab) throws {
        for file in files {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            guard file.isFileURL, values?.isRegularFile == true, values?.isReadable == true else {
                throw Arguments.invalid("\(file.path(percentEncoded: false)) isn’t a file Lithium can read.")
            }
        }
        state.armedUpload = (files, .now + .seconds(5))
    }

    /// Hooked from `Tab.runOpenPanelWith`. A chooser the agent opened without armed files is
    /// cancelled, never shown: an agent can't use the user's panel. Nil: the user's own chooser.
    func openPanel(for tab: Tab) -> AgentOpenPanel? {
        guard let state = tabs[tab.id] else { return nil }
        if let armed = state.armedUpload {
            state.armedUpload = nil
            if armed.expires > .now { return .files(armed.files) }
        }
        // The user can't click in a tab out of sight; in the one shown, only the agent's input counts.
        let unseen = state.isBusy && tab.loadedWebView?.userWindow == nil
        guard unseen || drive(of: tab) != nil else { return nil }
        state.fileChoosersCancelled += 1
        return .cancelled
    }
}
