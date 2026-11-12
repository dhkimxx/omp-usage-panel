import AppKit

/// Anchor of a custom `DropdownPopupController` list inside Settings: a bordered field face with a chevron.
/// Dismisses its own popup when it leaves the window, is hidden (page change) or is removed, mirroring the
/// provider/account picker's lifecycle.
final class SettingsDropdownButton: SettingsHoverButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryPushIn)
        setAccessibilityRole(.popUpButton)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        let open = DropdownPopupController.shared.isPresented(for: self)
        let fill = isEnabled ? (isHighlighted || open ? SettingsPalette.field : (isHovered ? NSColor(calibratedWhite: 0.215, alpha: 1) : SettingsPalette.raised)) : SettingsPalette.surface
        fill.setFill(); shape.fill()
        (isEnabled ? NSColor(calibratedWhite: 0.30, alpha: 1) : SettingsPalette.border).setStroke()
        shape.lineWidth = 1; shape.stroke()
        let color = isEnabled ? SettingsPalette.text : SettingsPalette.muted
        let text = DockPalette.text(title, size: 12, weight: .medium, color: color, alignment: .left)
        drawTitle(text, in: NSRect(x: 10, y: 0, width: max(0, bounds.width - 32), height: bounds.height))
        let chevron = NSBezierPath()
        let x = bounds.maxX - 16, y = bounds.midY
        chevron.move(to: NSPoint(x: x - 4, y: y - 2)); chevron.line(to: NSPoint(x: x, y: y + 2)); chevron.line(to: NSPoint(x: x + 4, y: y - 2))
        chevron.lineWidth = 1.5; chevron.lineCapStyle = .round; chevron.lineJoinStyle = .round
        SettingsPalette.secondary.setStroke(); chevron.stroke()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { DropdownPopupController.shared.dismiss(for: self) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidHide() {
        DropdownPopupController.shared.dismiss(for: self)
        super.viewDidHide()
    }

    override func removeFromSuperview() {
        DropdownPopupController.shared.dismiss(for: self)
        super.removeFromSuperview()
    }
}
