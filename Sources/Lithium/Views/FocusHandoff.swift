import AppKit
import SwiftUI

/// Moves keyboard focus into a SwiftUI text field. A SwiftUI field can't take focus from an
/// AppKit field that is editing (the address bar): setting its FocusState is silently ignored
/// and keystrokes keep going to the address bar. Releasing the current responder first, then
/// focusing on the next run-loop turn, works whatever held focus before.
@MainActor
func claimFocus(_ focus: FocusState<Bool>.Binding) {
    focus.wrappedValue = false
    NSApp.keyWindow?.makeFirstResponder(nil)
    DispatchQueue.main.async { focus.wrappedValue = true }
}
