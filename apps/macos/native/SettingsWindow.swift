import AppKit

/// Accessory apps have no Edit menu, so standard text-editing shortcuts would never reach the field editor.
/// Window-scoped: handled before normal dispatch (sendEvent and performKeyEquivalent share one helper; a handled
/// event is consumed, so it can never be applied twice), only while a field editor is first responder.
class SettingsWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if handleEditingKey(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleEditingKey(event) || super.performKeyEquivalent(with: event)
    }

    private func handleEditingKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let editor = firstResponder as? NSText, editor.isFieldEditor else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        // Command-applied characters stay Latin under non-Latin input sources (e.g. Korean), unlike charactersIgnoringModifiers.
        guard flags == .command || flags == [.command, .shift],
              let key = event.characters(byApplyingModifiers: .command)?.lowercased() else { return false }
        switch (key, flags.contains(.shift)) {
        case ("a", false): editor.selectAll(nil)
        case ("c", false): editor.copy(nil)
        case ("x", false): editor.cut(nil)
        case ("v", false): editor.paste(nil)
        case ("z", false): editor.undoManager?.undo()
        case ("z", true): editor.undoManager?.redo()
        default: return false
        }
        return true
    }
}
