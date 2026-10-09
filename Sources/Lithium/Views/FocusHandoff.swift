import AppKit
import SwiftUI

/// A SwiftUI field can't take focus from an editing AppKit field (the address bar): FocusState is
/// silently ignored. Releasing the responder first, then focusing on the next run-loop turn, works.
@MainActor
func claimFocus(_ focus: FocusState<Bool>.Binding) {
    focus.wrappedValue = false
    NSApp.keyWindow?.makeFirstResponder(nil)
    DispatchQueue.main.async { focus.wrappedValue = true }
}

/// Gives the keyboard to a page, unless a text field of the window is being edited.
@MainActor
func focusPage(_ view: NSView) {
    guard let window = view.window, !isEditingText(in: window) else { return }
    window.makeFirstResponder(view)
}

@MainActor
func isEditingText(in window: NSWindow?) -> Bool {
    guard let window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
    return (editor.delegate as? NSView)?.window === window
}
