import AppKit

/// Trailing chevron of a `SettingsSuggestionField`. A real NSButton (press action, label and identifier come from
/// AppKit) that never takes keyboard focus, so opening or closing the list leaves the owner's field editor, caret,
/// selection and marked text untouched.
final class SettingsSuggestionChevron: SettingsHoverButton {
    /// The field whose list this chevron opens (the popup anchor); decides the open/closed glyph.
    weak var owner: NSView?
    override var cornerRadius: CGFloat { 5 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryChange)
        focusRingType = .none
        refusesFirstResponder = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (isHovered || isHighlighted) {
            SettingsPalette.raised.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 5), xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
        let isOpen = owner.map { DropdownPopupController.shared.isPresented(for: $0) } ?? false
        // The view is not flipped: an open list points up, a closed one down.
        let direction: CGFloat = isOpen ? 1 : -1
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x - 4, y: center.y - direction * 2.5))
        path.line(to: NSPoint(x: center.x, y: center.y + direction * 2.5))
        path.line(to: NSPoint(x: center.x + 4, y: center.y - direction * 2.5))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (!isEnabled ? SettingsPalette.muted : (isHovered || isHighlighted || isOpen ? SettingsPalette.text : SettingsPalette.secondary)).setStroke()
        path.stroke()
    }
}

/// A real editable `NSTextField` (field editor, caret, selection, undo, clipboard and IME exactly as for
/// `SettingsTextField`) with an explicit suggestion affordance: a trailing chevron or the Down arrow opens the shared
/// custom dropdown list in `preserveEditor` mode. Any exact ID can still be typed; nothing is ever completed or
/// replaced unless a suggestion is deliberately chosen, and cancelling the list changes no text.
///
/// The field keeps its native accessibility untouched; the chevron is a SIBLING placed over its reserved right
/// inset by `SettingsSuggestionControl` (a text field's own AX children resolve back to the field, so the chevron
/// must not be nested in it). Put `SettingsSuggestionControl`, not the bare field, in layouts.
///
/// While the list is open for THIS editor and it is not composing, Up/Down move the highlight, Return chooses the
/// highlighted row (never an un-highlighted one) and Escape closes only the list. Choosing replaces the whole field
/// editor text through the text system (undoable, one `controlTextDidChange`, so the owner's binding sees exactly one
/// edit). The list closes when editing ends, the field is disabled or leaves its window.
final class SettingsSuggestionField: SettingsTextField {
    static let chevronWidth: CGFloat = 26

    let chevron = SettingsSuggestionChevron(frame: .zero)
    private(set) var suggestions: [String] = []
    private var isChoosing = false

    /// Forwards the shared list's tracking hold (true on open, false exactly once on close) to the owner.
    var trackingChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        (cell as? SettingsTextFieldCell)?.trailingInset = Self.chevronWidth
        // One scrolling line like the combo box it replaces; a long idle ID ends in an ellipsis instead of wrapping.
        cell?.isScrollable = true
        cell?.wraps = false
        lineBreakMode = .byTruncatingTail
        chevron.owner = self
        chevron.target = self
        chevron.action = #selector(chevronPressed)
        chevron.toolTip = "Show suggestions (Down arrow). Any exact ID can still be typed."
        refreshChevron()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isEnabled: Bool {
        didSet {
            refreshChevron()
            if !isEnabled { dismissSuggestions() }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { dismissSuggestions() }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: Configuration

    /// Identifier/label of the field; the chevron takes `<identifier>.suggestions` and a matching label.
    func configureAccessibility(identifier: String, label: String) {
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
        chevron.setAccessibilityIdentifier(identifier + ".suggestions")
        chevron.setAccessibilityLabel("Show \(label) suggestions")
        chevron.setAccessibilityHelp("Opens the list of known values. The field still accepts any exact value you type.")
    }

    /// True when `items` is exactly the current list (UTF-8 identity, order included).
    func suggestionsMatch(_ items: [String]) -> Bool {
        suggestions.count == items.count && zip(suggestions, items).allSatisfy { $0.isExactlyEqual(to: $1) }
    }

    /// Replaces the offered values. Never touches the text; a list that is open follows the change.
    func setSuggestions(_ items: [String]) {
        suggestions = items
        refreshChevron()
        guard isPresentingSuggestions else { return }
        if items.isEmpty { dismissSuggestions() } else { presentList() }
    }

    // MARK: State

    /// True while this field's field editor is the window's first responder (the user is editing it).
    var isEditingText: Bool {
        guard let editor = currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    var isPresentingSuggestions: Bool { DropdownPopupController.shared.isPresented(for: self) }

    /// The popup may take navigation keys only for this field's own live editor in the key window, and never while
    /// an input method is composing (marked text) - those keys belong to the input method.
    private var allowsListNavigation: Bool {
        guard let window, window.isKeyWindow, let editor = currentEditor() as? NSTextView,
              window.firstResponder === editor else { return false }
        return !editor.hasMarkedText()
    }

    // MARK: Presentation

    /// Opens (or refreshes) the list for this field's editor, focusing the field first when needed. False when
    /// there is nothing to offer or the field could not take editing focus.
    @discardableResult
    func showSuggestions() -> Bool {
        guard isEnabled, !suggestions.isEmpty, let window else { return false }
        if !isEditingText {
            guard window.makeFirstResponder(self), isEditingText else { return false }
        }
        presentList()
        return isPresentingSuggestions
    }

    func dismissSuggestions() {
        DropdownPopupController.shared.dismiss(for: self)
    }

    /// Applies a navigation command to this field's open list. False when it is not open for this field or the
    /// popup keeps the key (composition, no highlighted row, ...).
    func navigateSuggestions(_ command: DropdownNavigation) -> Bool {
        isPresentingSuggestions && DropdownPopupController.shared.navigate(command)
    }

    /// Editor commands from the owner's `control(_:textView:doCommandBy:)`. Down opens the list; while it is open
    /// Up/Down/Return/Escape drive it. Everything else (and every command while composing) stays with the editor.
    func handleEditorCommand(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveDown(_:)):
            if isPresentingSuggestions { return navigateSuggestions(.down) }
            return allowsListNavigation && showSuggestions()
        case #selector(NSResponder.moveUp(_:)):
            return navigateSuggestions(.up)
        case #selector(NSResponder.insertNewline(_:)):
            return navigateSuggestions(.activate)
        case #selector(NSResponder.cancelOperation(_:)):
            return navigateSuggestions(.cancel)
        default:
            return false
        }
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        // Keep the selected check in step with typing; never while composing or while a choice is being applied.
        if !isChoosing, allowsListNavigation, isPresentingSuggestions { presentList() }
    }

    override func textDidEndEditing(_ notification: Notification) {
        dismissSuggestions()
        super.textDidEndEditing(notification)
    }

    private func presentList() {
        // Captured strongly on purpose: the owner must receive the release even if this field is gone by then.
        let forward = trackingChanged
        DropdownPopupController.shared.show(
            anchor: self, items: makeItems(), focusMode: .preserveEditor,
            trackingChanged: { [weak self] held in
                self?.chevron.needsDisplay = true
                forward?(held)
            },
            navigationAllowed: { [weak self] in self?.allowsListNavigation ?? false },
            didClose: { [weak self] in self?.chevron.needsDisplay = true })
        chevron.needsDisplay = true
    }

    private func makeItems() -> [DropdownItem] {
        let current = currentEditor()?.string ?? stringValue
        var seen = Set<ExactString>()
        var items: [DropdownItem] = []
        for value in suggestions {
            guard seen.insert(value.exactKey).inserted else { continue }
            let identity = "suggestion:" + Data(value.utf8).map { String(format: "%02x", $0) }.joined()
            items.append(DropdownItem(id: identity, title: value, isSelected: value.isExactlyEqual(to: current),
                                      action: { [weak self] in self?.choose(value) }))
        }
        return items
    }

    /// Replaces the whole editor text with `value` as one native, undoable edit. The text system's change
    /// notification reaches the owner's `controlTextDidChange`, so the binding is applied exactly once.
    private func choose(_ value: String) {
        guard isEnabled, let editor = currentEditor() as? NSTextView else { return }
        isChoosing = true
        defer { isChoosing = false }
        if editor.hasMarkedText() { editor.unmarkText() }
        guard !editor.string.isExactlyEqual(to: value) else { return }
        editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    }

    private func refreshChevron() {
        chevron.isEnabled = isEnabled && !suggestions.isEmpty
        chevron.alphaValue = isEnabled ? 1 : 0.55
        chevron.needsDisplay = true
    }

    @objc private func chevronPressed() {
        if isPresentingSuggestions { dismissSuggestions() } else { showSuggestions() }
    }
}

/// Layout unit for one suggestion field: the native editable field fills it and the chevron button sits over the
/// field's reserved right inset as its SIBLING. The container itself is not an accessibility element, so the
/// accessibility tree is simply [text field, chevron button] with the field's native value/selection attributes
/// untouched (nesting the chevron inside the field produced a self-referencing AXChildren cycle).
final class SettingsSuggestionControl: NSView {
    let field = SettingsSuggestionField(frame: .zero)

    init(fixedWidth: CGFloat?) {
        super.init(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        addSubview(field.chevron, positioned: .above, relativeTo: field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.chevron.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            field.chevron.topAnchor.constraint(equalTo: field.topAnchor),
            field.chevron.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            field.chevron.widthAnchor.constraint(equalToConstant: SettingsSuggestionField.chevronWidth),
        ])
        if let fixedWidth { widthAnchor.constraint(equalToConstant: fixedWidth).isActive = true }
        else { setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
