import AppKit

/// One dark surface language for the Settings window, derived from `DockPalette` (same text tones and charcoal
/// steps as the dock/detail views). Every control below is a REAL AppKit control (NSButton / NSSegmentedControl /
/// NSTextField) with a custom face: state, enabled state, accessibility, keyboard focus and native text editing
/// (including IME) all still come from AppKit; only the drawing is replaced.
enum SettingsPalette {
    static let window = NSColor(calibratedWhite: 0.075, alpha: 1)
    static let sidebar = NSColor(calibratedWhite: 0.052, alpha: 1)
    static let surface = NSColor(calibratedWhite: 0.115, alpha: 1)
    static let raised = NSColor(calibratedWhite: 0.17, alpha: 1)
    static let field = NSColor(calibratedWhite: 0.06, alpha: 1)
    static let border = NSColor(calibratedWhite: 0.22, alpha: 1)
    static let text = DockPalette.primaryText
    static let secondary = DockPalette.secondary
    static let muted = DockPalette.muted
    static let accent = NSColor.controlAccentColor
    static let error = NSColor(calibratedRed: 1, green: 0.45, blue: 0.42, alpha: 1)
    static let warning = NSColor(calibratedRed: 1, green: 0.68, blue: 0.30, alpha: 1)

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
}

/// Opaque flat background (window, sidebar).
final class SettingsFillView: NSView {
    private let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); dirtyRect.fill() }
}

/// Bordered charcoal group (10-12pt inner padding is applied by the caller's stack insets).
final class SettingsCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = SettingsPalette.surface.cgColor
        layer?.borderColor = SettingsPalette.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 10
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// 1pt separator.
final class SettingsDividerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = SettingsPalette.border.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Shared behavior of the custom button faces: hover, redraw on every state change and a rounded focus ring.
class SettingsHoverButton: NSButton {
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?
    var cornerRadius: CGFloat { 7 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override var isEnabled: Bool { didSet { if !isEnabled { isHovered = false }; needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { if isEnabled { isHovered = true; needsDisplay = true } }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }

    /// Centers one line of text vertically inside `rect`.
    func drawTitle(_ text: NSAttributedString, in rect: NSRect) {
        let height = ceil(text.size().height)
        text.draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height))
    }
}

/// Push button: `.primary` (light fill, the one default action), `.secondary` (bordered charcoal) or `.quiet`.
final class SettingsButton: SettingsHoverButton {
    enum Style { case primary, secondary, quiet }
    private let style: Style
    private let isCompact: Bool

    init(title: String, style: Style = .secondary, compact: Bool = false) {
        self.style = style
        self.isCompact = compact
        super.init(frame: .zero)
        setButtonType(.momentaryPushIn)
        self.title = title
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var cornerRadius: CGFloat { isCompact ? 5 : 7 }
    private var faceFont: NSFont { SettingsPalette.font(isCompact ? 11 : 12, .medium) }

    override var intrinsicContentSize: NSSize {
        let width = ceil((title as NSString).size(withAttributes: [.font: faceFont]).width)
        return NSSize(width: width + (isCompact ? 18 : 26), height: isCompact ? 22 : 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        let pressed = isHighlighted
        let fill: NSColor?
        var stroke: NSColor?
        let textColor: NSColor
        switch style {
        case .primary:
            fill = isEnabled ? NSColor(calibratedWhite: pressed ? 0.72 : (isHovered ? 1 : 0.92), alpha: 1) : NSColor(calibratedWhite: 0.26, alpha: 1)
            textColor = isEnabled ? NSColor(calibratedWhite: 0.07, alpha: 1) : SettingsPalette.muted
        case .secondary:
            fill = isEnabled ? (pressed ? SettingsPalette.field : (isHovered ? NSColor(calibratedWhite: 0.215, alpha: 1) : SettingsPalette.raised)) : SettingsPalette.surface
            stroke = isEnabled ? NSColor(calibratedWhite: 0.30, alpha: 1) : SettingsPalette.border
            textColor = isEnabled ? SettingsPalette.text : SettingsPalette.muted
        case .quiet:
            fill = isEnabled && (isHovered || pressed) ? SettingsPalette.raised : nil
            textColor = !isEnabled ? SettingsPalette.muted : (isHovered || pressed ? SettingsPalette.text : SettingsPalette.secondary)
        }
        if let fill { fill.setFill(); shape.fill() }
        if let stroke { stroke.setStroke(); shape.lineWidth = 1; shape.stroke() }
        drawTitle(DockPalette.text(title, size: faceFont.pointSize, weight: .medium, color: textColor, alignment: .center), in: bounds.insetBy(dx: 6, dy: 0))
    }
}

/// Switch (`.switch` button type: checkbox accessibility role, Space toggles) with a dark pill face.
final class SettingsToggle: SettingsHoverButton {
    private static let trackSize = NSSize(width: 32, height: 18)
    private static let gap: CGFloat = 9
    private let fontSize: CGFloat = 12

    init(title: String) {
        super.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        setAccessibilityLabel(title)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var cornerRadius: CGFloat { 9 }

    override var intrinsicContentSize: NSSize {
        let width = ceil((title as NSString).size(withAttributes: [.font: SettingsPalette.font(fontSize)]).width)
        return NSSize(width: Self.trackSize.width + Self.gap + width + 2, height: 24)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: NSRect(x: 0, y: bounds.midY - Self.trackSize.height / 2, width: Self.trackSize.width, height: Self.trackSize.height),
                     xRadius: 9, yRadius: 9).fill()
    }
    override var focusRingMaskBounds: NSRect {
        NSRect(x: 0, y: bounds.midY - Self.trackSize.height / 2, width: Self.trackSize.width, height: Self.trackSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        let track = NSRect(x: 0.5, y: bounds.midY - Self.trackSize.height / 2 + 0.5, width: Self.trackSize.width - 1, height: Self.trackSize.height - 1)
        let shape = NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2)
        let accent = SettingsPalette.accent
        if on { (isEnabled ? accent : accent.withAlphaComponent(0.40)).setFill() }
        else { (isHovered && isEnabled ? NSColor(calibratedWhite: 0.215, alpha: 1) : SettingsPalette.raised).setFill() }
        shape.fill()
        if !on { NSColor(calibratedWhite: isEnabled ? 0.32 : 0.24, alpha: 1).setStroke(); shape.lineWidth = 1; shape.stroke() }
        let diameter = track.height - 4
        let thumbX = on ? track.maxX - diameter - 2 : track.minX + 2
        let thumb = NSRect(x: thumbX, y: track.minY + 2, width: diameter, height: diameter)
        NSColor(calibratedWhite: isEnabled ? (on ? 1 : 0.78) : 0.5, alpha: 1).setFill()
        NSBezierPath(ovalIn: thumb).fill()
        let textX = Self.trackSize.width + Self.gap
        drawTitle(DockPalette.text(title, size: fontSize, color: isEnabled ? SettingsPalette.text : SettingsPalette.muted),
                  in: NSRect(x: textX, y: 0, width: max(0, bounds.width - textX), height: bounds.height))
    }
}

/// Sidebar destination: one real button per section with radio-button semantics; Up/Down move between sections.
final class SettingsNavButton: SettingsHoverButton {
    var onNavigate: ((Int) -> Void)?
    var isCurrent = false {
        didSet {
            setAccessibilityValue(isCurrent ? "selected" : nil)
            setAccessibilitySelected(isCurrent)
            needsDisplay = true
        }
    }

    init(title: String) {
        super.init(frame: .zero)
        setButtonType(.momentaryPushIn)
        self.title = title
        setAccessibilityLabel(title)
        setAccessibilityRole(.radioButton)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onNavigate?(1)
        case 126: onNavigate?(-1)
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        if isCurrent { SettingsPalette.raised.setFill(); shape.fill() }
        else if isHovered || isHighlighted { NSColor(calibratedWhite: 0.11, alpha: 1).setFill(); shape.fill() }
        if isCurrent {
            SettingsPalette.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: bounds.midY - 8, width: 3, height: 16), xRadius: 1.5, yRadius: 1.5).fill()
        }
        let color = isCurrent ? SettingsPalette.text : (isHovered ? SettingsPalette.text : SettingsPalette.secondary)
        drawTitle(DockPalette.text(title, size: 12.5, weight: isCurrent ? .semibold : .medium, color: color),
                  in: NSRect(x: 12, y: 0, width: max(0, bounds.width - 20), height: bounds.height))
    }
}

/// `NSSegmentedControl` (select-one) with a dark face. Selection, accessibility children and mouse tracking come
/// from the control itself; Left/Right/Up/Down additionally step the selection when it has keyboard focus.
final class SettingsSegmentedControl: NSSegmentedControl {
    private static let fontSize: CGFloat = 11.5

    init(labels: [String]) {
        super.init(frame: .zero)
        segmentCount = labels.count
        for (index, label) in labels.enumerated() { setLabel(label, forSegment: index) }
        trackingMode = .selectOne
        segmentStyle = .smallSquare
        segmentDistribution = .fillEqually
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let widest = (0..<segmentCount).map { ceil(((label(forSegment: $0) ?? "") as NSString).size(withAttributes: [.font: SettingsPalette.font(Self.fontSize, .medium)]).width) }.max() ?? 0
        return NSSize(width: CGFloat(segmentCount) * max(48, widest + 22), height: 24)
    }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override var selectedSegment: Int { didSet { needsDisplay = true } }

    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: step(-1)
        case 124, 125: step(1)
        default: super.keyDown(with: event)
        }
    }

    private func step(_ delta: Int) {
        guard isEnabled, segmentCount > 0 else { return }
        let next = min(max((selectedSegment < 0 ? (delta > 0 ? -1 : segmentCount) : selectedSegment) + delta, 0), segmentCount - 1)
        guard next != selectedSegment else { return }
        selectedSegment = next
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        (isEnabled ? SettingsPalette.field : SettingsPalette.surface).setFill()
        outer.fill()
        let count = segmentCount
        guard count > 0 else { return }
        let width = bounds.width / CGFloat(count)
        for index in 0..<count {
            let cell = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
            let selected = selectedSegment == index
            if selected {
                let face = NSBezierPath(roundedRect: cell.insetBy(dx: 2.5, dy: 2.5), xRadius: 5, yRadius: 5)
                (isEnabled ? SettingsPalette.accent : SettingsPalette.accent.withAlphaComponent(0.35)).setFill()
                face.fill()
            }
            let color: NSColor = !isEnabled ? SettingsPalette.muted : (selected ? .white : SettingsPalette.secondary)
            let text = DockPalette.text(label(forSegment: index) ?? "", size: Self.fontSize, weight: selected ? .semibold : .medium,
                                        color: color, alignment: .center)
            let height = ceil(text.size().height)
            text.draw(in: NSRect(x: cell.minX + 4, y: cell.midY - height / 2, width: max(0, cell.width - 8), height: height))
        }
        NSColor(calibratedWhite: isEnabled ? 0.30 : 0.22, alpha: 1).setStroke()
        outer.lineWidth = 1
        outer.stroke()
    }
}

/// Native single-line text field (field editor, IME, undo, selection all unchanged) inside a dark rounded shell.
/// `trailingInset` reserves room on the right (for example the suggestion chevron) that neither drawing nor the
/// field editor may use.
final class SettingsTextFieldCell: NSTextFieldCell {
    private static let inset: CGFloat = 8
    var trailingInset: CGFloat = 0

    private func contentRect(_ rect: NSRect) -> NSRect {
        var content = rect
        content.origin.x += Self.inset
        content.size.width = max(0, rect.width - Self.inset - max(Self.inset, trailingInset))
        let font = self.font ?? NSFont.systemFont(ofSize: 12)
        let height = min(rect.height, ceil(font.ascender - font.descender + font.leading))
        content.origin.y = rect.minY + (rect.height - height) / 2
        content.size.height = height
        return content
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { contentRect(rect) }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: contentRect(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: contentRect(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        (editor as? NSTextView)?.insertionPointColor = SettingsPalette.text
        editor.textColor = SettingsPalette.text
        return editor
    }
}

/// Rounded dark shell around the native editable field. Open for `SettingsSuggestionField`, which adds a chevron.
class SettingsTextField: NSTextField {
    override class var cellClass: AnyClass? { get { SettingsTextFieldCell.self } set {} }

    /// Red border for a field-level validation problem.
    var showsError = false { didSet { refreshBorder() } }
    private var isFocused = false { didSet { refreshBorder() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = SettingsPalette.font(12)
        textColor = SettingsPalette.text
        wantsLayer = true
        layer?.backgroundColor = SettingsPalette.field.cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        refreshBorder()
        let height = heightAnchor.constraint(equalToConstant: 28)
        height.priority = NSLayoutConstraint.Priority(999)
        height.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.55 } }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { isFocused = true }
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        isFocused = false
    }

    private func refreshBorder() {
        let color: NSColor = showsError ? SettingsPalette.error : (isFocused ? SettingsPalette.accent : NSColor(calibratedWhite: 0.27, alpha: 1))
        layer?.borderColor = color.cgColor
        layer?.borderWidth = isFocused || showsError ? 1.5 : 1
    }
}
