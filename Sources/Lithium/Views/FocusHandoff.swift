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

/// Gives the keyboard to a page (its web view or PDF viewer), as a click into it would, unless a
/// text field of the window is being edited: the address bar after ⌘L, a tab being renamed.
@MainActor
func focusPage(_ view: NSView) {
    guard let window = view.window, !isEditingText(in: window) else { return }
    window.makeFirstResponder(view)
}

/// Whether a text field of the window is being edited (the address bar, the find bar, a tab's name).
@MainActor
func isEditingText(in window: NSWindow?) -> Bool {
    guard let window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
    return (editor.delegate as? NSView)?.window === window
}
