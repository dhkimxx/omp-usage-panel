import AppKit

enum DockPalette {
    static let primaryText = NSColor(calibratedWhite: 0.94, alpha: 1)
    static let secondary = NSColor(calibratedWhite: 0.64, alpha: 1)
    static let muted = NSColor(calibratedWhite: 0.48, alpha: 1)
    static let track = NSColor(calibratedWhite: 0.24, alpha: 1)

    static func usage(_ severity: String) -> NSColor {
        switch severity {
        case "critical": return .systemRed
        case "warning": return .systemOrange
        case "normal": return .systemGreen
        default: return NSColor(calibratedWhite: 0.56, alpha: 1)
        }
    }

    static func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular,
                     color: NSColor = primaryText, monospaced: Bool = false,
                     alignment: NSTextAlignment = .left) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        let font = monospaced ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color,
                                                               .paragraphStyle: paragraph])
    }
}

final class DockRootView: NSView {
    // Pointer entry/exit only asks the controller to reconcile with the shared hover policy.
    var hoverChanged: (() -> Void)?
    var contextMenu: (() -> NSMenu)?
    var openOverview: (() -> Void)?
    var mode: DockPlacementMode = .floating { didSet { needsDisplay = true } }
    var bodyRect: NSRect = .zero { didSet { needsDisplay = true } }
    var cameraRect: NSRect = .zero { didSet { needsDisplay = true } }
    var expansion: CGFloat = 0 { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    private var draggingPanel = false

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    func stopTracking() {
        if let tracking { removeTrackingArea(tracking); self.tracking = nil }
        draggingPanel = false
    }

    override func mouseEntered(with event: NSEvent) { hoverChanged?() }
    override func mouseExited(with event: NSEvent) { hoverChanged?() }

    override func draw(_ dirtyRect: NSRect) {
        let body = bodyRect.intersection(bounds)
        guard !body.isEmpty else { return }
        let amount = min(1, max(0, expansion))
        let path: NSBezierPath
        if mode == .notchConnected {
            let footerHeight = cameraRect.isEmpty ? body.height : max(0, cameraRect.minY - body.minY)
            // Both exposed lower corners share one radius: 14pt on the 28pt compact wing, relaxing
            // to the 22pt board contour as it expands. The top edge stays flush with the screen.
            let compactCap = body.height / 2 * (1 - amount)
            let radius = min(14 + 8 * amount, body.width / 2, max(footerHeight, 22 * amount, compactCap))
            let leftShoulder = min(max(0, body.minX - bounds.minX), max(0, body.height - radius))
            let rightShoulder = min(max(0, bounds.maxX - body.maxX), max(0, body.height - radius))
            let top = bounds.maxY
            path = NSBezierPath()
            // The entire screen edge is black; the concave wings turn directly into the body.
            path.move(to: NSPoint(x: bounds.minX, y: top))
            path.line(to: NSPoint(x: bounds.maxX, y: top))
            path.curve(to: NSPoint(x: body.maxX, y: top - rightShoulder),
                       controlPoint1: NSPoint(x: body.maxX, y: top),
                       controlPoint2: NSPoint(x: body.maxX, y: top - rightShoulder * 0.55))
            path.line(to: NSPoint(x: body.maxX, y: body.minY + radius))
            path.curve(to: NSPoint(x: body.maxX - radius, y: body.minY),
                       controlPoint1: NSPoint(x: body.maxX, y: body.minY + radius * 0.448),
                       controlPoint2: NSPoint(x: body.maxX - radius * 0.448, y: body.minY))
            path.line(to: NSPoint(x: body.minX + radius, y: body.minY))
            path.curve(to: NSPoint(x: body.minX, y: body.minY + radius),
                       controlPoint1: NSPoint(x: body.minX + radius * 0.448, y: body.minY),
                       controlPoint2: NSPoint(x: body.minX, y: body.minY + radius * 0.448))
            path.line(to: NSPoint(x: body.minX, y: top - leftShoulder))
            path.curve(to: NSPoint(x: bounds.minX, y: top),
                       controlPoint1: NSPoint(x: body.minX, y: top - leftShoulder * 0.55),
                       controlPoint2: NSPoint(x: body.minX, y: top))
            path.close()
        } else {
            // The compact capsule is 28pt high; expansion relaxes it into the board radius.
            let radius = min(14 + 8 * amount, min(body.width, body.height) / 2)
            path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        }
        NSColor.black.setFill()
        path.fill()
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        if let menu = contextMenu?() { menu.popUp(positioning: nil, at: point, in: nil) }
    }

    override func mouseDown(with event: NSEvent) {
        draggingPanel = event.modifierFlags.contains(.option)
        if draggingPanel { window?.mouseDown(with: event) } else { openOverview?() }
    }

    override func mouseDragged(with event: NSEvent) {
        if draggingPanel { window?.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if draggingPanel { draggingPanel = false; window?.mouseUp(with: event) }
    }
}

class DockButton: NSButton {
    var contextMenu: (() -> NSMenu)?
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?
    private var draggingPanel = false
    private var windowObservers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func updateTrackingAreas() {
        // inVisibleRect follows layout and clipping itself. Replacing it mid-drag can lose an exit.
        if tracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }
        super.updateTrackingAreas()
        reconcileHover()
    }

    override func viewDidMoveToWindow() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        super.viewDidMoveToWindow()
        if let window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.reconcileHover()
                })
            }
        }
        reconcileHover()
    }

    deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        reconcileHover()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reconcileHover()
    }

    private func reconcileHover() {
        let hovered: Bool
        if let window, window.isVisible, !isHiddenOrHasHiddenAncestor {
            let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            hovered = visibleRect.contains(point)
        } else {
            hovered = false
        }
        if hovered != isHovered { isHovered = hovered; needsDisplay = true }
    }

    override func mouseEntered(with event: NSEvent) { reconcileHover() }
    override func mouseExited(with event: NSEvent) { reconcileHover() }

    override func rightMouseDown(with event: NSEvent) {
        // Factories can synchronously expand/move the window. Retain the original global anchor.
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        if let menu = contextMenu?() { menu.popUp(positioning: nil, at: point, in: nil) }
    }

    override func mouseDown(with event: NSEvent) {
        draggingPanel = event.modifierFlags.contains(.option)
        if draggingPanel { window?.mouseDown(with: event) } else { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if draggingPanel { window?.mouseDragged(with: event) } else { super.mouseDragged(with: event) }
        reconcileHover()
    }

    override func mouseUp(with event: NSEvent) {
        if draggingPanel { draggingPanel = false; window?.mouseUp(with: event) } else { super.mouseUp(with: event) }
        reconcileHover()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { scrollToVisible(bounds); needsDisplay = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }

    func drawKeyboardFocus(radius: CGFloat) {
        guard window?.firstResponder === self else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                                xRadius: radius, yRadius: radius)
        ring.lineWidth = 1.5
        ring.stroke()
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
    }
}

// Shared mark-only 22pt circle chrome: hover/press wash, keyboard focus and badges. Hit
// frames are taller than the circle (28pt row); hover only washes the circle, it never
// moves or resizes the control.
class CompactCircleButton: DockButton {
    private static let overLimitMark = DockPalette.text("!", size: 6.5, weight: .heavy,
                                                        color: .white, alignment: .center)

    var circle: NSRect {
        let diameter = CompactMetrics.ringDiameter
        return NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                      width: diameter, height: diameter)
    }

    var emphasis: CGFloat { isHighlighted ? 0.28 : (isHovered ? 0.16 : 0) }

    func drawWash() {
        guard emphasis > 0 else { return }
        NSColor.white.withAlphaComponent(emphasis * 0.6).setFill()
        NSBezierPath(ovalIn: circle).fill()
    }

    func drawWarningDot() {
        let rect = NSRect(x: bounds.midX + CompactMetrics.ringDiameter / 2 - 6, y: circle.minY, width: 6, height: 6)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1)).fill()
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    // A real over-limit cue, distinct from the warning dot: stale/transport/provider warnings
    // are never presented as quota overage.
    func drawOverLimitBadge() {
        let rect = NSRect(x: bounds.midX + CompactMetrics.ringDiameter / 2 - 8, y: circle.maxY - 8, width: 8, height: 8)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1)).fill()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let mark = Self.overLimitMark
        let size = mark.size()
        mark.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    func drawCenteredText(_ text: NSAttributedString) {
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    func drawFocusOutline() {
        guard window?.firstResponder === self else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        ring.stroke()
    }

    func dashedCircle(in rect: NSRect, width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = width
        let dash = CGFloat.pi * rect.width / 28
        path.setLineDash([dash, dash], count: 2, phase: 0)
        return path
    }

    override var focusRingMaskBounds: NSRect { circle }
    override func drawFocusRingMask() { NSBezierPath(ovalIn: circle).fill() }
}

final class CompactRingButton: CompactCircleButton {
    private(set) var presentation: CompactRingPresentation?
    private var markText = NSAttributedString(string: "")

    // Presentation, tooltip, accessibility and the mark are cached when the content
    // changes; painting (including hover/animation repaint) only reads the cache.
    func update(_ presentation: CompactRingPresentation) {
        guard presentation != self.presentation else { return }
        self.presentation = presentation
        identifier = NSUserInterfaceItemIdentifier(presentation.provider)
        title = presentation.label
        toolTip = presentation.tooltip
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityHelp(presentation.tooltip)
        markText = DockPalette.text(presentation.mark, size: CompactMetrics.markFontSize, weight: .semibold,
                                    color: presentation.arc == .unknown ? DockPalette.secondary : DockPalette.primaryText,
                                    alignment: .center)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let presentation else { return }
        drawWash()
        let stroke = CompactMetrics.ringStroke
        let rect = circle.insetBy(dx: stroke / 2, dy: stroke / 2)
        switch presentation.arc {
        case .unknown:
            // Unknown is a static dashed ring, never an empty (0%) gauge.
            (presentation.isReported ? DockPalette.secondary : DockPalette.muted).setStroke()
            dashedCircle(in: rect, width: stroke).stroke()
        case .fraction(let fraction):
            let track = NSBezierPath(ovalIn: rect)
            track.lineWidth = stroke
            (emphasis > 0 ? DockPalette.track.blended(withFraction: emphasis, of: .white) ?? DockPalette.track
                          : DockPalette.track).setStroke()
            track.stroke()
            let base = DockPalette.usage(presentation.severity)
            (emphasis > 0 ? base.blended(withFraction: emphasis, of: .white) ?? base : base).setStroke()
            if fraction >= 1 {
                let full = NSBezierPath(ovalIn: rect)
                full.lineWidth = stroke
                full.stroke()
            } else if fraction > 0 {
                // Known zero draws only the track: no round-cap dot.
                // Start at 12 o'clock and sweep clockwise as the eye sees it. AppKit measures angles in
                // view coordinates, so a flipped view mirrors both the start angle and the direction.
                let start: CGFloat = isFlipped ? -90 : 90
                let sweep = 360 * CGFloat(fraction) * (isFlipped ? 1 : -1)
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                              startAngle: start, endAngle: start + sweep, clockwise: !isFlipped)
                arc.lineWidth = stroke
                arc.lineCapStyle = .round
                arc.stroke()
            }
        }
        drawCenteredText(markText)
        if presentation.isOverLimit { drawOverLimitBadge() }
        if presentation.hasWarning { drawWarningDot() }
        drawFocusOutline()
    }
}

// Circular +N count of providers that do not fit. It is a count, not a usage gauge.
final class CompactMoreButton: CompactCircleButton {
    private var presentation: CompactMorePresentation?
    private var countText = NSAttributedString(string: "")

    func update(_ presentation: CompactMorePresentation) {
        guard presentation != self.presentation else { return }
        self.presentation = presentation
        title = "More providers"
        toolTip = presentation.tooltip
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityHelp(presentation.tooltip)
        countText = DockPalette.text(presentation.text, size: CompactMetrics.markFontSize, weight: .semibold,
                                     color: DockPalette.primaryText, monospaced: true, alignment: .center)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let presentation else { return }
        drawWash()
        NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let outline = NSBezierPath(ovalIn: circle.insetBy(dx: CompactMetrics.ringStroke / 2, dy: CompactMetrics.ringStroke / 2))
        outline.lineWidth = CompactMetrics.ringStroke
        DockPalette.secondary.setStroke()
        outline.stroke()
        drawCenteredText(countText)
        if presentation.hasWarning { drawWarningDot() }
        drawFocusOutline()
    }
}

// The "+" shown when nothing is selected or there is no data to select from. It opens the real settings.
final class CompactConfigureButton: CompactCircleButton {
    private var presentation: CompactConfigurePresentation?

    func update(_ presentation: CompactConfigurePresentation) {
        guard presentation != self.presentation else { return }
        self.presentation = presentation
        title = "Compact display settings"
        toolTip = presentation.tooltip
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityHelp(presentation.tooltip)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let presentation else { return }
        drawWash()
        let stroke = CompactMetrics.ringStroke
        DockPalette.muted.setStroke()
        dashedCircle(in: circle.insetBy(dx: stroke / 2, dy: stroke / 2), width: stroke).stroke()
        let plus = NSBezierPath()
        plus.lineWidth = 1.5
        plus.lineCapStyle = .round
        plus.move(to: NSPoint(x: bounds.midX - 4, y: bounds.midY)); plus.line(to: NSPoint(x: bounds.midX + 4, y: bounds.midY))
        plus.move(to: NSPoint(x: bounds.midX, y: bounds.midY - 4)); plus.line(to: NSPoint(x: bounds.midX, y: bounds.midY + 4))
        DockPalette.secondary.setStroke()
        plus.stroke()
        if presentation.hasIssue { drawWarningDot() }
        drawFocusOutline()
    }
}

private final class DashboardLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        maximumNumberOfLines = 1
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// One measurement policy for every action control (overview/detail toolbars, scope tabs, account picker).
// Frames and camera-clearance budgets use these numbers, so drawing can never disagree with layout.
enum ActionMetrics {
    static let height: CGFloat = 28
    static let iconOnlyWidth: CGFloat = 28
    static let inset: CGFloat = 9
    static let iconSize: CGFloat = 13
    static let iconGap: CGFloat = 6
    static let chevronSize: CGFloat = 9
    static let chevronGap: CGFloat = 6
    static let groupGap: CGFloat = 6
    static let fontSize: CGFloat = 12
    static let radius: CGFloat = 8
    // Distance between an icon-only control's edge and its glyph.
    static var glyphBleed: CGFloat { (iconOnlyWidth - iconSize) / 2 }

    private static var widths: [String: CGFloat] = [:]
    // Measured with the heaviest weight so selection never changes a control's width. Cached per title.
    static func textWidth(_ title: String) -> CGFloat {
        if let cached = widths[title] { return cached }
        let width = ceil(DockPalette.text(title, size: fontSize, weight: .semibold).size().width)
        widths[title] = width
        return width
    }
    static func width(title: String, icon: Bool, chevron: Bool = false, centered: Bool = false) -> CGFloat {
        let reserve = chevronGap + chevronSize
        return inset + (centered && chevron ? reserve : 0) + (icon ? iconSize + iconGap : 0) + textWidth(title)
            + (chevron ? reserve : 0) + inset
    }
}

class ActionButton: DockButton {
    enum Style {
        // Persistent rounded fill (overview toolbar, account picker).
        case filled
        // Fill only for hover, press and selection (detail toolbar, scope tabs).
        case quiet
    }

    var style: Style = .quiet { didSet { if style != oldValue { needsDisplay = true } } }
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var showsTitle = true { didSet { if showsTitle != oldValue { needsDisplay = true } } }
    // Picker affordance. A disabled chevron button reads as a plain label instead of a dead control.
    var trailingChevron = false { didSet { if trailingChevron != oldValue { needsDisplay = true } } }
    // Opt-in: center the icon and title group instead of left-aligning it (provider dropdown only).
    var centersContent = false { didSet { if centersContent != oldValue { needsDisplay = true } } }
    private let symbolName: String?
    // Content (title, symbol, tone) changes rarely; draw only reads these caches.
    private enum Tone: Int { case normal, selected, disabled, label }
    private var icons = [NSImage?](repeating: nil, count: 4)
    private var chevrons = [NSImage?](repeating: nil, count: 4)
    private var labels = [(text: NSAttributedString, width: CGFloat, height: CGFloat)?](repeating: nil, count: 4)
    private static let fillBase = NSColor(calibratedWhite: 0.075, alpha: 1)
    private static let fillQuietHover = NSColor(calibratedWhite: 0.10, alpha: 1)
    private static let fillFilledHover = NSColor(calibratedWhite: 0.13, alpha: 1)
    private static let fillSelected = NSColor(calibratedWhite: 0.16, alpha: 1)
    private static let fillPressed = NSColor(calibratedWhite: 0.18, alpha: 1)
    private static let fillSelectedHover = NSColor(calibratedWhite: 0.19, alpha: 1)
    override var title: String { didSet { labels = [(text: NSAttributedString, width: CGFloat, height: CGFloat)?](repeating: nil, count: 4) } }
    override var isFlipped: Bool { true }

    init(title: String, symbol: String? = nil, style: Style = .quiet, showsTitle: Bool = true) {
        symbolName = symbol
        self.style = style
        self.showsTitle = showsTitle
        super.init(frame: .zero)
        self.title = title
        setAccessibilityLabel(title)
        toolTip = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    private func color(for tone: Tone) -> NSColor {
        switch tone {
        case .normal: return DockPalette.secondary
        case .selected, .label: return DockPalette.primaryText
        case .disabled: return DockPalette.muted
        }
    }

    private func symbol(_ name: String, point: CGFloat, weight: NSFont.Weight, tone: Tone,
                        cache: inout [NSImage?]) -> NSImage? {
        if let cached = cache[tone.rawValue] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: point, weight: weight)
            .applying(.init(paletteColors: [color(for: tone)]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        cache[tone.rawValue] = image
        return image
    }

    // Aspect-fits a symbol inside a square box centered on `center`, so glyph centers never depend on advance widths.
    private func drawSymbol(_ image: NSImage?, box: CGFloat, center: NSPoint) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(box / image.size.width, box / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                              width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let label = !isEnabled && trailingChevron
        let fill: NSColor?
        if isHighlighted && isEnabled { fill = Self.fillPressed }
        else if selected { fill = isHovered ? Self.fillSelectedHover : Self.fillSelected }
        else if isHovered && isEnabled { fill = style == .filled ? Self.fillFilledHover : Self.fillQuietHover }
        else if style == .filled && !label { fill = Self.fillBase }
        else { fill = nil }
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: ActionMetrics.radius,
                         yRadius: ActionMetrics.radius).fill()
        }
        let tone: Tone = label ? .label : !isEnabled ? .disabled : (selected ? .selected : .normal)
        let titleVisible = showsTitle && !title.isEmpty
        let midY = (bounds.height / 2).rounded(.toNearestOrAwayFromZero)
        var x = ActionMetrics.inset
        let reserve = trailingChevron ? ActionMetrics.chevronGap + ActionMetrics.chevronSize : 0
        var entry: (text: NSAttributedString, width: CGFloat, height: CGFloat)?
        if titleVisible {
            if let cached = labels[tone.rawValue] { entry = cached } else {
                let text = DockPalette.text(title, size: ActionMetrics.fontSize,
                                            weight: tone == .selected ? .semibold : .medium, color: color(for: tone))
                let size = text.size()
                let built = (text: text, width: ceil(size.width), height: ceil(size.height))
                labels[tone.rawValue] = built
                entry = built
            }
        }
        // Centered mode centers the icon+gap+title group in the space left after reserving the chevron's width on
        // both sides, so the group sits on the button's center while the chevron stays anchored at the edge.
        let iconSpan = symbolName == nil ? 0 : ActionMetrics.iconSize + ActionMetrics.iconGap
        var titleWidth = max(0, bounds.width - x - iconSpan - ActionMetrics.inset - reserve)
        if centersContent, titleVisible, let entry {
            let usable = max(0, bounds.width - (ActionMetrics.inset + reserve) * 2)
            titleWidth = min(entry.width, max(0, usable - iconSpan))
            x = ActionMetrics.inset + reserve + (usable - iconSpan - titleWidth) / 2
        }
        if let symbolName {
            if !titleVisible { x = (bounds.width - ActionMetrics.iconSize) / 2 }
            drawSymbol(symbol(symbolName, point: ActionMetrics.fontSize, weight: .medium, tone: tone, cache: &icons),
                       box: ActionMetrics.iconSize,
                       center: NSPoint(x: x + ActionMetrics.iconSize / 2, y: midY))
            x += ActionMetrics.iconSize + ActionMetrics.iconGap
        }
        if let entry {
            entry.text.draw(in: NSRect(x: x, y: midY - entry.height / 2, width: titleWidth, height: entry.height))
        }
        if trailingChevron && !label {
            drawSymbol(symbol("chevron.down", point: 9, weight: .semibold, tone: tone, cache: &chevrons),
                       box: ActionMetrics.chevronSize,
                       center: NSPoint(x: bounds.width - ActionMetrics.inset - ActionMetrics.chevronSize / 2, y: midY))
        }
        drawKeyboardFocus(radius: ActionMetrics.radius)
    }
}

// The one provider dropdown shared by the overview and detail headers: typed All plus the complete catalog.
// Titles are centered between symmetric chevron reservations; the chevron stays at the trailing edge.
final class ProviderScopeButton: ActionButton {
    var choose: ((DetailScope) -> Void)?
    var menuTrackingChanged: ((Bool) -> Void)?
    private var providers: [DetailProvider] = []
    private var selectedScope: DetailScope?

    init(style: Style) {
        super.init(title: "Providers", style: style)
        trailingChevron = true
        centersContent = true
        target = self
        action = #selector(pressed)
        setAccessibilityLabel("Provider filter")
        setAccessibilityHelp("Choose All or one provider")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    /// `selected == nil` is the overview: no scope is chosen and the control reads "Providers".
    func update(providers: [DetailProvider], selected: DetailScope?) {
        self.providers = providers
        selectedScope = selected
        let current = selected.flatMap { scope in providers.first(where: { $0.scope == scope })?.label } ?? "Providers"
        if title != current { title = current }
        toolTip = current
        setAccessibilityValue(current)
    }

    /// Width for the full title plus symmetric chevron reservations, clamped to `maximum`.
    func preferredWidth(maximum: CGFloat) -> CGFloat {
        min(maximum, ActionMetrics.width(title: title, icon: false, chevron: true, centered: true))
    }

    @objc private func pressed() {
        let menu = NSMenu(title: "Provider filter")
        for provider in providers {
            let item = NSMenuItem(title: provider.label, action: #selector(chosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = provider.scope
            item.state = provider.scope == selectedScope ? .on : .off
            menu.addItem(item)
        }
        menuTrackingChanged?(true)
        defer { menuTrackingChanged?(false) }
        // Buttons are flipped: the menu's top-left corner sits just below the control.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
    }

    @objc private func chosen(_ item: NSMenuItem) {
        guard let scope = item.representedObject as? DetailScope else { return }
        choose?(scope)
    }
}

private final class DashboardCardButton: DockButton {
    private(set) var card: DashboardCard?
    private var providerText = NSAttributedString(string: "")
    private var valueText = NSAttributedString(string: "")
    private var metricText = NSAttributedString(string: "")
    private var contextText = NSAttributedString(string: "")
    private var resetText = NSAttributedString(string: "")
    private var resetValue: String?
    private let resetRect = NSRect(x: DashboardSizing.cardPadding, y: 99,
                                   width: DashboardSizing.cardWidth - DashboardSizing.cardPadding * 2, height: 22)
    private var elapsed: Double?
    private var color = DockPalette.muted
    override var isFlipped: Bool { true }
    private static let warningReserve: CGFloat = 9

    func update(card: DashboardCard, now: Date) {
        self.card = card
        title = card.label
        toolTip = card.tooltip
        setAccessibilityLabel("\(card.label), \(card.value), \(card.metric), \(card.context)\(card.hasIssue ? ", attention required" : "")")
        setAccessibilityHelp(card.tooltip)
        color = DockPalette.usage(card.severity)
        providerText = DockPalette.text(card.label, size: 12.5, weight: .semibold, alignment: .center)
        var valueSize: CGFloat = 30
        let available = DashboardSizing.cardWidth - DashboardSizing.cardPadding * 2
        while valueSize > 15,
              (card.value as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: valueSize, weight: .medium)]).width > available {
            valueSize -= 1
        }
        valueText = DockPalette.text(card.value, size: valueSize, weight: .medium,
                                    color: card.percent == nil ? DockPalette.secondary : DockPalette.primaryText, monospaced: true)
        metricText = DockPalette.text(card.metric, size: 10, color: DockPalette.secondary)
        contextText = DockPalette.text(card.context, size: 9, color: DockPalette.muted)
        resetValue = nil
        tick(now: now)
        needsDisplay = true
    }

    func tick(now: Date) {
        guard let card else { return }
        let next = card.resetText(now: now)
        if next != resetValue {
            resetValue = next
            let available = DashboardSizing.cardWidth - DashboardSizing.cardPadding * 2
            var fontSize: CGFloat = 10
            while fontSize > 9,
                  (next as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)]).width > available {
                fontSize -= 0.5
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            resetText = NSAttributedString(string: next, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: DockPalette.secondary,
                .paragraphStyle: paragraph
            ])
            setAccessibilityValue(next)
            needsDisplay = true
        }
        let nextElapsed = card.showPace ? card.elapsed(now: now) : nil
        if nextElapsed != elapsed { elapsed = nextElapsed; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let card else { return }
        let surface = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: surface, xRadius: 12, yRadius: 12)
        NSColor(calibratedWhite: isHighlighted ? 0.13 : (isHovered ? 0.105 : 0.07), alpha: 1).setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(isHovered ? 0.075 : 0.035).setStroke()
        shape.lineWidth = 0.7
        shape.stroke()
        let padding = DashboardSizing.cardPadding
        let width = max(0, bounds.width - padding * 2)
        // The warning dot's slot is reserved on both sides in every state, so the centered title never shifts.
        providerText.draw(in: NSRect(x: padding + Self.warningReserve, y: padding,
                                     width: max(0, width - Self.warningReserve * 2), height: 18))
        if card.hasIssue {
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - padding - 4, y: padding + 5, width: 4, height: 4)).fill()
        }
        valueText.draw(in: NSRect(x: padding, y: 30, width: width, height: 37))
        metricText.draw(in: NSRect(x: padding, y: 68, width: width, height: 13))
        let trackRect = NSRect(x: padding, y: 85, width: width, height: 5)
        let track = NSBezierPath(roundedRect: trackRect, xRadius: 2.5, yRadius: 2.5)
        DockPalette.track.setFill()
        track.fill()
        if let percent = card.percent, percent.isFinite {
            NSGraphicsContext.saveGraphicsState()
            track.addClip()
            color.setFill()
            NSRect(x: trackRect.minX, y: trackRect.minY,
                   width: width * min(1, max(0, percent / 100)), height: trackRect.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            DockPalette.secondary.setFill()
            NSRect(x: trackRect.midX - 1, y: trackRect.minY + 1, width: 2, height: 3).fill()
        }
        if let elapsed, elapsed.isFinite {
            let x = min(trackRect.maxX - 1, max(trackRect.minX + 1, trackRect.minX + width * CGFloat(elapsed)))
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 1.5, y: trackRect.minY - 2, width: 3, height: 9), xRadius: 1.5, yRadius: 1.5).fill()
            NSColor.white.withAlphaComponent(0.95).setFill()
            NSRect(x: x - 0.5, y: trackRect.minY - 1, width: 1, height: 7).fill()
        }
        resetText.draw(in: resetRect)
        contextText.draw(in: NSRect(x: padding, y: bounds.maxY - padding - 11, width: width, height: 11))
        drawKeyboardFocus(radius: 11)
    }
}

private final class DashboardDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class DashboardScrollView: NSScrollView {
    private var root: DockRootView? {
        var ancestor = superview
        while let current = ancestor {
            if let root = current as? DockRootView { return root }
            ancestor = current.superview
        }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === contentView || hit === documentView { return self }
        return hit
    }

    override func mouseDown(with event: NSEvent) { root?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { root?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { root?.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { root?.rightMouseDown(with: event) }
}

final class DashboardView: NSView {
    var selectProvider: ((String) -> Void)?
    var selectScope: ((DetailScope) -> Void)? {
        didSet { providerButton.choose = selectScope }
    }
    var menuTrackingChanged: ((Bool) -> Void)? {
        didSet { providerButton.menuTrackingChanged = menuTrackingChanged }
    }
    var refresh: (() -> Void)?
    var optionsMenu: (() -> NSMenu)?
    // This reservation is already converted from the root into flipped dashboard coordinates.
    var cameraRect: NSRect = .zero { didSet { needsLayout = true } }

    private let heading = DashboardLabel()
    private let status = DashboardLabel()
    private let footer = DashboardLabel()
    private let legend = DashboardLabel()
    private let providerButton = ProviderScopeButton(style: .filled)
    private let refreshButton = ActionButton(title: "Refresh", symbol: "arrow.clockwise", style: .filled)
    private let optionsButton = ActionButton(title: "Options", symbol: "ellipsis", style: .filled, showsTitle: false)
    private let scrollView = DashboardScrollView()
    private let document = DashboardDocumentView()
    private var buttons: [String: DashboardCardButton] = [:]
    private var orderedButtons: [DashboardCardButton] = []
    private var showsLegend = false
    private var headingSize: CGFloat = 16
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heading.attributedStringValue = DockPalette.text("Usage", size: 16, weight: .semibold)
        heading.setAccessibilityLabel("Usage")
        legend.attributedStringValue = DockPalette.text("│ Elapsed", size: 10, color: DockPalette.secondary, alignment: .right)
        legend.toolTip = "The white marker shows how much of the selected usage window has elapsed."
        legend.setAccessibilityLabel("White marker: elapsed usage window")
        let views: [NSView] = [heading, status, footer, legend, providerButton, refreshButton, optionsButton, scrollView]
        for view in views {
            addSubview(view)
        }
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)
        optionsButton.target = self
        optionsButton.action = #selector(optionsPressed)
        for button in [providerButton, refreshButton, optionsButton] {
            button.contextMenu = { [weak self] in self?.optionsMenu?() ?? NSMenu() }
        }
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = document
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func update(content: DashboardContent, collecting: Bool, providers: [DetailProvider]) {
        providerButton.update(providers: providers, selected: nil)
        let issue = content.issue.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = issue.isEmpty || content.status.contains(issue) ? content.status : "\(content.status) · \(issue)"
        status.attributedStringValue = DockPalette.text(source, size: 10,
                                                        color: issue.isEmpty ? DockPalette.secondary : NSColor.systemOrange.withAlphaComponent(0.9))
        status.toolTip = source
        status.setAccessibilityLabel(source)
        footer.attributedStringValue = DockPalette.text(content.footer, size: 10, color: DockPalette.muted)
        footer.toolTip = content.footer
        footer.setAccessibilityLabel(content.footer)
        refreshButton.isEnabled = !collecting
        refreshButton.toolTip = collecting ? "Refreshing usage…" : "Refresh usage now"
        refreshButton.setAccessibilityLabel(collecting ? "Refreshing usage" : "Refresh usage")
        let now = Date()
        var occurrences: [String: Int] = [:]
        var next: [String: DashboardCardButton] = [:]
        var ordered: [DashboardCardButton] = []
        for card in content.cards {
            let occurrence = occurrences[card.provider, default: 0]
            occurrences[card.provider] = occurrence + 1
            let key = "\(card.provider)\u{0}\(occurrence)"
            let button: DashboardCardButton
            if let existing = buttons[key] {
                button = existing
            } else {
                button = DashboardCardButton(frame: .zero)
                button.target = self
                button.action = #selector(providerPressed(_:))
                button.contextMenu = { [weak self] in self?.optionsMenu?() ?? NSMenu() }
                document.addSubview(button)
            }
            button.update(card: card, now: now)
            next[key] = button
            ordered.append(button)
        }
        for (key, button) in buttons where next[key] == nil { button.removeFromSuperview() }
        buttons = next
        orderedButtons = ordered
        showsLegend = content.cards.contains { $0.showPace && $0.elapsed(now: now) != nil }
        legend.isHidden = !showsLegend
        // Explicit key order follows the upstream provider order, including after reordering a snapshot.
        var keyOrder: [NSView] = [providerButton, refreshButton, optionsButton]
        keyOrder.append(contentsOf: ordered)
        for index in keyOrder.indices { keyOrder[index].nextKeyView = keyOrder[(index + 1) % keyOrder.count] }
        needsLayout = true
    }

    func tick(now: Date) {
        for button in orderedButtons { button.tick(now: now) }
    }

    func focusSelection() {
        let target: NSView = orderedButtons.first.map { $0 as NSView } ?? providerButton
        window?.makeFirstResponder(target)
    }

    private static let headingWidth: CGFloat = 64
    private static let narrowHeadingWidth: CGFloat = 32
    // The dropdown keeps its full width (title + chevron); only the heading yields space.
    private static let providersWidth = ActionMetrics.width(title: "Providers", icon: false, chevron: true, centered: true)
    private static let refreshFullWidth = ActionMetrics.width(title: "Refresh", icon: true)
    // Heading + providers, and Refresh + Options, at full width. Header reflow and layout share these budgets.
    private static var fullLeftGroup: CGFloat { headingWidth + 7 + providersWidth }
    private static var fullRightGroup: CGFloat {
        refreshFullWidth + ActionMetrics.groupGap + ActionMetrics.iconOnlyWidth
    }

    private static func needsHeaderReflow(for size: NSSize, cameraRect: NSRect) -> Bool {
        if cameraRect.isEmpty {
            // Switch both action groups together before their full-width frames can collide.
            return size.width - DashboardSizing.padding * 2 < fullLeftGroup + ActionMetrics.groupGap + fullRightGroup
        }
        let leftSpace = cameraRect.minX - 8 - (DashboardSizing.padding - 2)
        let rightSpace = size.width - DashboardSizing.padding - cameraRect.maxX - 8
        return leftSpace < narrowHeadingWidth + ActionMetrics.groupGap + providersWidth
            || rightSpace < ActionMetrics.iconOnlyWidth * 2 + ActionMetrics.groupGap
    }

    static func requiredHeaderHeight(for size: NSSize, cameraRect: NSRect) -> CGFloat {
        let cameraHeight = cameraRect.isEmpty ? 0 : max(0, cameraRect.maxY)
        let base = DashboardSizing.headerHeight(cameraHeight: cameraHeight)
        guard !cameraRect.isEmpty, needsHeaderReflow(for: size, cameraRect: cameraRect) else { return base }
        return max(base, cameraHeight + 8 + ActionMetrics.height)
    }

    override func layout() {
        super.layout()
        let padding = DashboardSizing.padding
        let usable = max(0, bounds.width - padding * 2)
        let headerHeight = Self.requiredHeaderHeight(for: bounds.size, cameraRect: cameraRect)
        let buttonY = headerHeight - ActionMetrics.height
        let leftSpace = cameraRect.isEmpty ? usable - Self.fullRightGroup - ActionMetrics.groupGap
            : cameraRect.minX - 8 - (padding - 2)
        let rightSpace = cameraRect.isEmpty ? usable : bounds.width - padding - cameraRect.maxX - 8
        let reflow = Self.needsHeaderReflow(for: bounds.size, cameraRect: cameraRect)
        let narrowProviders = reflow || leftSpace < Self.fullLeftGroup
        let narrowRefresh = reflow || rightSpace < Self.fullRightGroup
        refreshButton.showsTitle = !narrowRefresh
        let iconWidth = ActionMetrics.iconOnlyWidth
        let actionWidth: CGFloat = reflow ? min(iconWidth, max(0, (usable - 18) / 3)) : iconWidth
        let providersWidth = Self.providersWidth
        let refreshWidth: CGFloat = narrowRefresh ? actionWidth : Self.refreshFullWidth
        let headingWidth: CGFloat
        if reflow {
            headingWidth = min(64, max(0, usable - providersWidth - actionWidth * 2 - 18))
        } else {
            headingWidth = narrowProviders ? min(Self.headingWidth, max(Self.narrowHeadingWidth, leftSpace - providersWidth - 6)) : Self.headingWidth
        }
        let fontSize: CGFloat = headingWidth >= 48 ? 16 : 11
        if headingSize != fontSize {
            headingSize = fontSize
            heading.attributedStringValue = DockPalette.text("Usage", size: fontSize, weight: .semibold)
        }
        heading.frame = NSRect(x: padding - 2, y: headerHeight - (fontSize == 16 ? 25 : 22),
                               width: headingWidth, height: fontSize == 16 ? 23 : 17)
        providerButton.frame = NSRect(x: heading.frame.maxX + (narrowProviders ? 6 : 7),
                                      y: buttonY, width: providersWidth, height: ActionMetrics.height)
        optionsButton.frame = NSRect(x: bounds.width - padding - actionWidth, y: buttonY,
                                     width: actionWidth, height: ActionMetrics.height)
        refreshButton.frame = NSRect(x: optionsButton.frame.minX - ActionMetrics.groupGap - refreshWidth, y: buttonY,
                                     width: refreshWidth, height: ActionMetrics.height)
        status.frame = NSRect(x: padding - 2, y: headerHeight + 3, width: usable + 4, height: 15)
        let rowY = headerHeight + 25
        scrollView.frame = NSRect(x: padding, y: rowY, width: usable, height: DashboardSizing.cardHeight + 3)
        let count = orderedButtons.count
        let rowWidth = CGFloat(count) * DashboardSizing.cardWidth + CGFloat(max(0, count - 1)) * DashboardSizing.cardGap
        document.frame = NSRect(x: 0, y: 0, width: max(usable, rowWidth), height: DashboardSizing.cardHeight + 3)
        for (index, button) in orderedButtons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * (DashboardSizing.cardWidth + DashboardSizing.cardGap), y: 0,
                                  width: DashboardSizing.cardWidth, height: DashboardSizing.cardHeight)
        }
        let legendWidth: CGFloat = showsLegend ? 65 : 0
        let footerY = headerHeight + DashboardSizing.cardHeight + 32
        footer.frame = NSRect(x: padding - 2, y: footerY,
                              width: max(0, usable - legendWidth), height: 16)
        legend.frame = NSRect(x: bounds.width - padding - 65, y: footerY, width: 67, height: 16)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    @objc private func refreshPressed() { refresh?() }
    @objc private func providerPressed(_ sender: DashboardCardButton) {
        if let provider = sender.card?.provider { selectProvider?(provider) }
    }

    @objc private func optionsPressed() {
        // Resolve screen space before a menu factory changes panel geometry.
        let local = optionsButton.convert(NSPoint(x: 0, y: optionsButton.bounds.maxY + 4), to: nil)
        let point = window?.convertPoint(toScreen: local) ?? NSEvent.mouseLocation
        if let menu = optionsMenu?() { menu.popUp(positioning: nil, at: point, in: nil) }
    }
}
