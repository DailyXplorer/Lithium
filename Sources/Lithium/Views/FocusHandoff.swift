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
    guard let window = view.window else { return }
    if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
       (editor.delegate as? NSView)?.window === window { return }
    window.makeFirstResponder(view)
}
