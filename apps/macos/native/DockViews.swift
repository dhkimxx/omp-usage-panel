import AppKit

private enum DockPalette {
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
    var hoverChanged: ((Bool) -> Void)?
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

    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }

    override func draw(_ dirtyRect: NSRect) {
        let body = bodyRect.intersection(bounds)
        guard !body.isEmpty else { return }
        let amount = min(1, max(0, expansion))
        let path: NSBezierPath
        if mode == .notchConnected {
            let footerHeight = cameraRect.isEmpty ? body.height : max(0, cameraRect.minY - body.minY)
            let radius = min(9 + 13 * amount, min(body.width / 2, max(footerHeight, 22 * amount)))
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
            let radius = min(9 + 13 * amount, min(body.width, body.height) / 2)
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
    fileprivate private(set) var isHovered = false
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

    fileprivate func drawKeyboardFocus(radius: CGFloat) {
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

final class CompactProviderButton: DockButton {
    private var percent: Double?
    private var color = DockPalette.muted
    private var hasIssue = false

    func update(card: DashboardCard) {
        title = card.label
        percent = card.percent
        color = DockPalette.usage(card.severity)
        hasIssue = card.hasIssue
        toolTip = card.tooltip
        setAccessibilityLabel("\(card.label), \(card.value)\(card.hasIssue ? ", attention required" : "")")
        setAccessibilityHelp(card.tooltip)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: (bounds.height - 2.5) / 2, width: max(0, bounds.width), height: 2.5)
        let emphasis: CGFloat = isHighlighted ? 0.28 : (isHovered ? 0.16 : 0)
        let trackColor = emphasis > 0
            ? DockPalette.track.blended(withFraction: emphasis, of: .white) ?? DockPalette.track
            : DockPalette.track
        trackColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.25, yRadius: 1.25).fill()
        if let percent, percent.isFinite {
            let fill = NSRect(x: track.minX, y: track.minY,
                              width: track.width * min(1, max(0, percent / 100)), height: track.height)
            let fillColor = emphasis > 0 ? color.blended(withFraction: emphasis, of: .white) ?? color : color
            fillColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.25, yRadius: 1.25).fill()
        } else {
            DockPalette.secondary.setFill()
            NSRect(x: track.midX - min(0.75, track.width / 2), y: track.minY,
                   width: min(1.5, track.width), height: track.height).fill()
        }
        if hasIssue {
            NSColor.systemOrange.setFill()
            let diameter = min(2, bounds.width)
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - diameter, y: bounds.maxY - 3,
                                      width: diameter, height: 2)).fill()
        }
        drawKeyboardFocus(radius: 3)
    }
}

final class CompactStatusButton: DockButton {
    private var hasIssue = false
    private var collecting = false

    func update(issue: String, collecting: Bool) {
        let issue = issue.trimmingCharacters(in: .whitespacesAndNewlines)
        hasIssue = !issue.isEmpty
        self.collecting = collecting
        let status = collecting ? "Collecting usage…" : "No usage data available"
        let description = issue.isEmpty ? status : "\(status) · \(issue)"
        title = "Usage overview"
        toolTip = description
        setAccessibilityLabel("Usage overview, \(description)")
        setAccessibilityHelp(description)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = min(3, min(bounds.width, bounds.height))
        let color = hasIssue ? NSColor.systemOrange : (collecting ? DockPalette.secondary : DockPalette.muted)
        (isHovered || isHighlighted ? color.blended(withFraction: 0.2, of: .white) ?? color : color).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                                  width: diameter, height: diameter)).fill()
        drawKeyboardFocus(radius: 3)
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

private final class DashboardHeaderButton: DockButton {
    private let text: NSAttributedString
    private let symbol: NSImage?
    var symbolOnly: Bool { didSet { if symbolOnly != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    init(title: String, symbol: String, symbolOnly: Bool = false) {
        self.text = DockPalette.text(title, size: 11, weight: .medium, color: DockPalette.secondary)
        self.symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [DockPalette.secondary]))
        self.symbolOnly = symbolOnly
        super.init(frame: .zero)
        self.title = title
        setAccessibilityLabel(title)
        toolTip = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor(calibratedWhite: isHighlighted ? 0.18 : (isHovered ? 0.13 : 0.075), alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.45) }
        let iconRect = NSRect(x: symbolOnly ? (bounds.width - 13) / 2 : 9,
                              y: (bounds.height - 13) / 2, width: 13, height: 13)
        if let symbol, symbol.size.width > 0, symbol.size.height > 0 {
            let scale = min(iconRect.width / symbol.size.width, iconRect.height / symbol.size.height)
            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            let fitted = NSRect(x: iconRect.midX - size.width / 2, y: iconRect.midY - size.height / 2,
                                width: size.width, height: size.height)
            symbol.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 0.8,
                        respectFlipped: true, hints: nil)
        }
        if !symbolOnly {
            text.draw(in: NSRect(x: 28, y: (bounds.height - 14) / 2, width: max(0, bounds.width - 33), height: 14))
        }
        NSGraphicsContext.restoreGraphicsState()
        drawKeyboardFocus(radius: 7)
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

    func update(card: DashboardCard, now: Date) {
        self.card = card
        title = card.label
        toolTip = card.tooltip
        setAccessibilityLabel("\(card.label), \(card.value), \(card.metric), \(card.context)\(card.hasIssue ? ", attention required" : "")")
        setAccessibilityHelp(card.tooltip)
        color = DockPalette.usage(card.severity)
        providerText = DockPalette.text(card.label, size: 12.5, weight: .semibold)
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
        providerText.draw(in: NSRect(x: padding, y: padding, width: max(0, width - (card.hasIssue ? 9 : 0)), height: 18))
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
    var openAccounts: (() -> Void)?
    var refresh: (() -> Void)?
    var optionsMenu: (() -> NSMenu)?
    // This reservation is already converted from the root into flipped dashboard coordinates.
    var cameraRect: NSRect = .zero { didSet { needsLayout = true } }

    private let heading = DashboardLabel()
    private let status = DashboardLabel()
    private let footer = DashboardLabel()
    private let legend = DashboardLabel()
    private let accountsButton = DashboardHeaderButton(title: "Accounts", symbol: "person.crop.circle")
    private let refreshButton = DashboardHeaderButton(title: "Refresh", symbol: "arrow.clockwise")
    private let optionsButton = DashboardHeaderButton(title: "Options", symbol: "ellipsis", symbolOnly: true)
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
        let views: [NSView] = [heading, status, footer, legend, accountsButton, refreshButton, optionsButton, scrollView]
        for view in views {
            addSubview(view)
        }
        accountsButton.target = self
        accountsButton.action = #selector(accountsPressed)
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)
        optionsButton.target = self
        optionsButton.action = #selector(optionsPressed)
        for button in [accountsButton, refreshButton, optionsButton] {
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

    func update(content: DashboardContent, collecting: Bool) {
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
        var keyOrder: [NSView] = [accountsButton, refreshButton, optionsButton]
        keyOrder.append(contentsOf: ordered)
        for index in keyOrder.indices { keyOrder[index].nextKeyView = keyOrder[(index + 1) % keyOrder.count] }
        needsLayout = true
    }

    func tick(now: Date) {
        for button in orderedButtons { button.tick(now: now) }
    }

    private static func needsHeaderReflow(for size: NSSize, cameraRect: NSRect) -> Bool {
        if cameraRect.isEmpty {
            // Switch both action groups together before their full-width frames can collide.
            return size.width - DashboardSizing.padding * 2 < 281
        }
        let leftSpace = cameraRect.minX - 8 - (DashboardSizing.padding - 2)
        let rightSpace = size.width - DashboardSizing.padding - cameraRect.maxX - 8
        return leftSpace < 67 || rightSpace < 64
    }

    static func requiredHeaderHeight(for size: NSSize, cameraRect: NSRect) -> CGFloat {
        let cameraHeight = cameraRect.isEmpty ? 0 : max(0, cameraRect.maxY)
        let base = DashboardSizing.headerHeight(cameraHeight: cameraHeight)
        guard !cameraRect.isEmpty, needsHeaderReflow(for: size, cameraRect: cameraRect) else { return base }
        return max(base, cameraHeight + 8 + 27)
    }

    override func layout() {
        super.layout()
        let padding = DashboardSizing.padding
        let usable = max(0, bounds.width - padding * 2)
        let headerHeight = Self.requiredHeaderHeight(for: bounds.size, cameraRect: cameraRect)
        let buttonY = headerHeight - 27
        let leftSpace = cameraRect.isEmpty ? usable - 122 : cameraRect.minX - 8 - (padding - 2)
        let rightSpace = cameraRect.isEmpty ? usable : bounds.width - padding - cameraRect.maxX - 8
        let reflow = Self.needsHeaderReflow(for: bounds.size, cameraRect: cameraRect)
        let narrowAccounts = reflow || leftSpace < 159
        let narrowRefresh = reflow || rightSpace < 116
        accountsButton.symbolOnly = narrowAccounts
        refreshButton.symbolOnly = narrowRefresh
        let actionWidth: CGFloat = reflow ? min(29, max(0, (usable - 18) / 3)) : 29
        let accountsWidth: CGFloat = narrowAccounts ? actionWidth : 88
        let refreshWidth: CGFloat = narrowRefresh ? actionWidth : 81
        let headingWidth: CGFloat
        if reflow {
            headingWidth = min(64, max(0, usable - actionWidth * 3 - 18))
        } else {
            headingWidth = narrowAccounts ? min(64, max(32, leftSpace - 35)) : 64
        }
        let fontSize: CGFloat = headingWidth >= 48 ? 16 : 11
        if headingSize != fontSize {
            headingSize = fontSize
            heading.attributedStringValue = DockPalette.text("Usage", size: fontSize, weight: .semibold)
        }
        heading.frame = NSRect(x: padding - 2, y: headerHeight - (fontSize == 16 ? 25 : 22),
                               width: headingWidth, height: fontSize == 16 ? 23 : 17)
        accountsButton.frame = NSRect(x: heading.frame.maxX + (narrowAccounts ? 6 : 7),
                                      y: buttonY, width: accountsWidth, height: 27)
        optionsButton.frame = NSRect(x: bounds.width - padding - actionWidth, y: buttonY,
                                     width: actionWidth, height: 27)
        refreshButton.frame = NSRect(x: optionsButton.frame.minX - 6 - refreshWidth, y: buttonY,
                                     width: refreshWidth, height: 27)
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

    @objc private func accountsPressed() { openAccounts?() }
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
