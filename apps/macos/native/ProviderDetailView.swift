import AppKit

private final class DetailText: NSTextField {
    private var draggingPanel = false
    convenience init(_ text: String = "", size: CGFloat = 12, color: NSColor = DockPalette.primaryText,
                     weight: NSFont.Weight = .regular) {
        self.init(frame: .zero)
        isEditable = false
        isSelectable = true
        isBezeled = false
        drawsBackground = false
        font = .systemFont(ofSize: size, weight: weight)
        textColor = color
        stringValue = text
        cell?.wraps = true
        cell?.isScrollable = false
        maximumNumberOfLines = 0
        focusRingType = .none
    }
    override func mouseDown(with event: NSEvent) {
        draggingPanel = event.modifierFlags.contains(.option)
        if draggingPanel { window?.mouseDown(with: event) }
        else { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        if draggingPanel { window?.mouseDragged(with: event) }
        else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if draggingPanel { draggingPanel = false; window?.mouseUp(with: event) }
        else { super.mouseUp(with: event) }
    }
    func height(for width: CGFloat, minimum: CGFloat = 18) -> CGFloat {
        guard width > 0 else { return 0 }
        return max(minimum, ceil(cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100000)).height ?? minimum))
    }
    // Natural single-line width from the configured font and the cell's own insets.
    var textWidth: CGFloat {
        guard let cell else { return ceil(attributedStringValue.size().width) + 6 }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 100000, height: 100000)).width) + 4
    }
    // Status/count text truncates on one line and keeps its full value in the tooltip.
    func makeSingleLine(alignment: NSTextAlignment = .natural) {
        cell?.wraps = false
        cell?.usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        self.alignment = alignment
    }
}

private class DetailSurface: NSView {
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) { window?.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
}

private final class DetailScroll: NSScrollView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        guard hasVerticalScroller, let documentView else { super.keyDown(with: event); return }
        let maximum = max(0, documentView.bounds.height - contentSize.height)
        let current = contentView.bounds.origin.y
        let page = max(40, contentSize.height - 24)
        let destination: CGFloat
        switch event.keyCode {
        case 126: destination = current - 40
        case 125: destination = current + 40
        case 116: destination = current - page
        case 121: destination = current + page
        case 115: destination = 0
        case 119: destination = maximum
        default: super.keyDown(with: event); return
        }
        contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, destination))))
        reflectScrolledClipView(contentView)
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) { window?.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
}

// Toolbar buttons and the account picker share ActionButton's drawing and measurements.
private final class DetailButton: ActionButton {
    var contextAction: ((NSEvent) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        if let contextAction { contextAction(event) } else { super.rightMouseDown(with: event) }
    }
}

private final class DetailProgress: NSView {
    var model: DetailLimit?
    var now = Date()
    override func draw(_ dirtyRect: NSRect) {
        // 10pt reservation: 6pt track centred on the 10pt pace marker.
        let track = NSRect(x: 0, y: 2, width: bounds.width, height: 6)
        DockPalette.track.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        if let model, let percent = model.percent {
            DockPalette.usage(model.severity).setFill()
            let filled = NSRect(x: 0, y: 2, width: bounds.width * min(1, max(0, percent / 100)), height: 6)
            NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
        }
        if let elapsed = model?.elapsed(now: now) {
            DockPalette.primaryText.setFill()
            NSRect(x: max(0, min(bounds.width - 2, bounds.width * elapsed)), y: 0, width: 2, height: 10).fill()
        }
    }
}

private final class DetailDisclosureButton: DockButton {
    var expanded = false {
        didSet {
            guard oldValue != expanded else { return }
            setAccessibilityValue(expanded ? "expanded" : "collapsed")
            needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }

    convenience init(subject: String) {
        self.init(frame: .zero)
        title = "Details"
        setAccessibilityLabel("Details for \(subject)")
        setAccessibilityValue("collapsed")
        toolTip = "Show or hide raw identifiers, window fields and notes"
    }
    override func draw(_ dirtyRect: NSRect) {
        if isHovered || isHighlighted {
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
        }
        if let image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
                .applying(.init(paletteColors: [DockPalette.secondary]))) {
            image.draw(in: NSRect(x: 8, y: (bounds.height - 10) / 2, width: 10, height: 10), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        DockPalette.text("Details", size: 11, weight: .medium, color: DockPalette.secondary)
            .draw(in: NSRect(x: 23, y: (bounds.height - 14) / 2, width: max(0, bounds.width - 27), height: 14))
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
    override func keyDown(with event: NSEvent) {
        // Left collapses and right expands, matching native disclosure controls.
        if event.keyCode == 123, expanded { performClick(nil) }
        else if event.keyCode == 124, !expanded { performClick(nil) }
        else { super.keyDown(with: event) }
    }
}

private func styleDetailCard(_ view: NSView) {
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
    view.layer?.cornerRadius = 13
    view.layer?.borderWidth = 1
    view.layer?.borderColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
}

private struct DetailCardPlan {
    var frames: [(NSView, NSRect)] = []
    var height: CGFloat = 0
    var timingRight = false
    var amountRight = false
    var resetRight = false
}

private final class DetailLimitCard: DetailSurface {
    let model: DetailLimit
    let disclosure: DetailDisclosureButton
    var toggled: ((Bool) -> Void)?
    var sizeChanged: (() -> Void)?
    private(set) var expanded: Bool
    private let heading: DetailText
    private let timing: DetailText
    private let value: DetailText
    private let amount: DetailText
    private let remaining: DetailText
    private let reset: DetailText
    private let details: DetailText
    private let progress = DetailProgress()
    private var cachedWidth: CGFloat = -1
    private var cachedPlan = DetailCardPlan()

    init(model: DetailLimit, now: Date, expanded: Bool) {
        self.model = model
        self.expanded = expanded
        heading = DetailText(model.limit.label, size: 13, weight: .semibold)
        timing = DetailText(model.timing, size: 10, color: DockPalette.secondary)
        value = DetailText(model.value, size: 26, weight: .semibold)
        amount = DetailText(model.amount, size: 11, color: DockPalette.secondary)
        remaining = DetailText(model.remaining, size: 11, color: DockPalette.secondary)
        reset = DetailText(model.reset(now: now), size: 11, color: DockPalette.secondary)
        // Every original note and normalized field remains reachable through the disclosure.
        let metadata = model.metadata.map { "\($0.label): \($0.value)" }
        details = DetailText((model.limit.notes + metadata).joined(separator: "\n"), size: 10, color: DockPalette.muted)
        disclosure = DetailDisclosureButton(subject: model.limit.label)
        super.init(frame: .zero)
        styleDetailCard(self)
        let views: [NSView] = [heading, timing, value, amount, progress, remaining, reset, details, disclosure]
        for view in views { addSubview(view) }
        progress.model = model
        progress.now = now
        value.textColor = model.percent == nil ? DockPalette.primaryText : DockPalette.usage(model.severity)
        details.isHidden = !expanded
        disclosure.expanded = expanded
        disclosure.target = self
        disclosure.action = #selector(toggle)
        setAccessibilityElement(false)
        setAccessibilityLabel(model.limit.label)
        progress.setAccessibilityElement(true)
        progress.setAccessibilityRole(.image)
        updateProgressAccessibility(now: now)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    @objc private func toggle() {
        expanded.toggle()
        disclosure.expanded = expanded
        details.isHidden = !expanded
        cachedWidth = -1
        needsLayout = true
        toggled?(expanded)
    }

    // Content-sized layout: heading+timing share a row, value+amount share a row, the footer carries
    // remaining, reset and the inline disclosure. Every text keeps its natural wrapped height.
    private func plan(width: CGFloat) -> DetailCardPlan {
        if cachedWidth == width { return cachedPlan }
        var plan = DetailCardPlan()
        let pad: CGFloat = 12, gutter: CGFloat = 10
        let disclosureW: CGFloat = 70, disclosureH: CGFloat = 20
        let inner = max(1, width - pad * 2)
        var y: CGFloat = 10
        func put(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            plan.frames.append((view, NSRect(x: x, y: y, width: w, height: h)))
        }
        func full(_ view: DetailText, gap: CGFloat) {
            guard !view.stringValue.isEmpty else { put(view, pad, y, inner, 0); return }
            let height = view.height(for: inner, minimum: 0)
            put(view, pad, y, inner, height)
            y += height + gap
        }
        // Heading and timing.
        let hasTiming = !timing.stringValue.isEmpty
        let timingNatural = hasTiming ? timing.textWidth : 0
        if !hasTiming || heading.textWidth + gutter + timingNatural <= inner {
            let headingWidth = hasTiming ? inner - timingNatural - gutter : inner
            let headingHeight = heading.height(for: headingWidth, minimum: 0)
            let timingHeight = hasTiming ? timing.height(for: timingNatural, minimum: 0) : 0
            let row = max(headingHeight, timingHeight)
            put(heading, pad, y, headingWidth, headingHeight)
            put(timing, pad + inner - timingNatural, y + row - timingHeight, timingNatural, timingHeight)
            plan.timingRight = hasTiming
            y += row
        } else {
            full(heading, gap: 1)
            full(timing, gap: 0)
        }
        y += 4
        // Value and amount.
        let sideBySide = inner >= 216
        let hasAmount = !amount.stringValue.isEmpty
        if sideBySide {
            let valueWidth = hasAmount ? min(inner * 0.55, value.textWidth) : inner
            let amountWidth = max(1, inner - valueWidth - gutter)
            let valueHeight = value.height(for: valueWidth, minimum: 0)
            let amountHeight = hasAmount ? amount.height(for: amountWidth, minimum: 0) : 0
            let row = max(valueHeight, amountHeight)
            put(value, pad, y, valueWidth, valueHeight)
            put(amount, pad + valueWidth + gutter, y + row - amountHeight, amountWidth, amountHeight)
            plan.amountRight = true
            y += row
        } else {
            full(value, gap: hasAmount ? 2 : 0)
            full(amount, gap: 0)
        }
        y += 6
        put(progress, pad, y, inner, 10)
        y += 16
        // Footer: remaining, reset and the disclosure share one row when they fit.
        let hasRemaining = !remaining.stringValue.isEmpty, hasReset = !reset.stringValue.isEmpty
        let remainingNatural = hasRemaining ? remaining.textWidth : 0
        let resetNatural = hasReset ? reset.textWidth : 0
        let items = CGFloat((hasRemaining ? 1 : 0) + (hasReset ? 1 : 0))
        let disclosureX = pad + inner - disclosureW
        if remainingNatural + resetNatural + disclosureW + gutter * items <= inner {
            let remainingHeight = remaining.height(for: max(1, remainingNatural), minimum: 0)
            let resetHeight = reset.height(for: max(1, resetNatural), minimum: 0)
            let resetX = pad + (hasRemaining ? remainingNatural + gutter : 0)
            let resetWidth = max(1, disclosureX - gutter - resetX)
            put(remaining, pad, y + (disclosureH - remainingHeight) / 2, max(1, remainingNatural), remainingHeight)
            put(reset, resetX, y + (disclosureH - resetHeight) / 2, resetWidth, resetHeight)
            put(disclosure, disclosureX, y, disclosureW, disclosureH)
            plan.resetRight = true
            y += disclosureH
        } else {
            let textWidth = inner - disclosureW - gutter
            if textWidth >= 90 {
                let remainingHeight = remaining.height(for: textWidth, minimum: 0)
                let resetHeight = reset.height(for: textWidth, minimum: 0)
                let block = remainingHeight + resetHeight + (hasRemaining && hasReset ? 1 : 0)
                let row = max(block, disclosureH)
                put(remaining, pad, y, textWidth, remainingHeight)
                put(reset, pad, y + remainingHeight + (hasRemaining && hasReset ? 1 : 0), textWidth, resetHeight)
                put(disclosure, disclosureX, y + (row - disclosureH) / 2, disclosureW, disclosureH)
                y += row
            } else {
                // Too narrow to share a row without squeezing the text; the disclosure takes a slim row.
                full(remaining, gap: 1)
                full(reset, gap: 2)
                put(disclosure, pad - 8, y, disclosureW, disclosureH)
                y += disclosureH
            }
        }
        if expanded {
            y += 6
            full(details, gap: 0)
        }
        plan.height = y + 10
        cachedWidth = width
        cachedPlan = plan
        return plan
    }
    func height(for width: CGFloat) -> CGFloat { plan(width: width).height }
    override func layout() {
        super.layout()
        let plan = plan(width: bounds.width)
        for (view, frame) in plan.frames { view.frame = frame }
        func align(_ text: DetailText, _ right: Bool) {
            let alignment: NSTextAlignment = right ? .right : .left
            if text.alignment != alignment { text.alignment = alignment }
        }
        align(timing, plan.timingRight)
        align(amount, plan.amountRight)
        align(reset, plan.resetRight)
    }
    func tick(now: Date) {
        let text = model.reset(now: now)
        if reset.stringValue != text {
            // The footer arrangement depends on the reset text's natural width; re-plan and tell the
            // parent only when the card's height actually changed.
            let width = bounds.width
            let oldHeight = width > 0 ? plan(width: width).height : 0
            reset.stringValue = text
            cachedWidth = -1
            needsLayout = true
            if width > 0, plan(width: width).height != oldHeight { sizeChanged?() }
        }
        progress.now = now
        progress.needsDisplay = true
        updateProgressAccessibility(now: now)
    }
    private func updateProgressAccessibility(now: Date) {
        var label = model.percent.map { "\(DetailFormatting.number($0)) percent used" }
            ?? (model.isBalanceOnly ? "Balance only; no numeric quota or usage percentage" : "Usage percentage not reported")
        if let elapsed = model.elapsed(now: now) { label += ", \(DetailFormatting.number(elapsed * 100)) percent of period elapsed" }
        progress.setAccessibilityLabel(label)
    }
}

// One always-visible card: identity, optional plan/fetch time, known cautions, then neutral provider text.
private final class DetailAccountCard: DetailSurface {
    private let title: DetailText
    private let subtitle: DetailText
    private var facts: [(DetailText, DetailText)] = []
    private var cautions: [DetailText] = []
    private var noteSections: [(DetailText, DetailText)] = []
    private let footnote = DetailText("Selection changes this display only, not the credentials used for inference.",
                                      size: 10, color: DockPalette.muted)
    private var cachedWidth: CGFloat = -1
    private var cachedPlan = DetailCardPlan()

    init(content: ProviderDetailContent) {
        let info = content.account
        title = DetailText(content.selected?.label ?? "No account selected", size: 15, weight: .semibold)
        subtitle = DetailText(content.selected?.providerLabel ?? "No usage records", size: 11, color: DockPalette.secondary)
        super.init(frame: .zero)
        styleDetailCard(self)
        func fact(_ label: String, _ value: String) -> (DetailText, DetailText) {
            (DetailText(label, size: 10, color: DockPalette.muted), DetailText(value, size: 12))
        }
        func section(_ heading: String, _ notes: [String]) -> (DetailText, DetailText) {
            (DetailText(heading, size: 9, color: DockPalette.muted, weight: .medium),
             DetailText(notes.joined(separator: "\n\n"), size: 11, color: DockPalette.secondary))
        }
        if let plan = info.plan { facts.append(fact("Plan", plan)) }
        if let fetched = info.fetched { facts.append(fact("Fetched", fetched)) }
        cautions = info.cautions.map { DetailText($0, size: 11, color: .systemOrange) }
        if !info.accountNotes.isEmpty { noteSections.append(section("ACCOUNT NOTES", info.accountNotes)) }
        if !info.providerNotes.isEmpty { noteSections.append(section("PROVIDER NOTES", info.providerNotes)) }
        footnote.isHidden = content.selected == nil
        for view in [title, subtitle, footnote] as [NSView] { addSubview(view) }
        for pair in facts + noteSections { addSubview(pair.0); addSubview(pair.1) }
        for view in cautions { addSubview(view) }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    private func plan(width: CGFloat) -> DetailCardPlan {
        if cachedWidth == width { return cachedPlan }
        var plan = DetailCardPlan()
        let inner = max(1, width - 32)
        var y: CGFloat = 16
        // The gap after a block is applied only when another block follows, so the card hugs its content.
        var gap: CGFloat = 0
        func full(_ view: DetailText, after: CGFloat) {
            let height = view.height(for: inner)
            y += gap
            plan.frames.append((view, NSRect(x: 16, y: y, width: inner, height: height)))
            y += height
            gap = after
        }
        func rows(_ pairs: [(DetailText, DetailText)]) {
            let labelWidth = min(88, inner * 0.4)
            let valueWidth = max(1, inner - labelWidth - 8)
            for (label, value) in pairs {
                let labelHeight = label.height(for: labelWidth), valueHeight = value.height(for: valueWidth)
                y += gap
                plan.frames.append((label, NSRect(x: 16, y: y + 1, width: labelWidth, height: labelHeight)))
                plan.frames.append((value, NSRect(x: 16 + labelWidth + 8, y: y, width: valueWidth, height: valueHeight)))
                y += max(labelHeight, valueHeight)
                gap = 7
            }
        }
        full(title, after: 2)
        full(subtitle, after: 12)
        rows(facts)
        for item in cautions { full(item, after: 7) }
        for (heading, body) in noteSections {
            gap = max(gap, 12)
            full(heading, after: 3)
            full(body, after: 10)
        }
        if !footnote.isHidden { gap = max(gap, 12); full(footnote, after: 0) }
        plan.height = y + 16
        cachedWidth = width
        cachedPlan = plan
        return plan
    }
    func height(for width: CGFloat) -> CGFloat { plan(width: width).height }
    override func layout() {
        super.layout()
        for (view, frame) in plan(width: bounds.width).frames { view.frame = frame }
    }
}

final class ProviderDetailView: NSView {
    var selectScope: ((DetailScope) -> Void)? {
        didSet { providerButton.choose = selectScope }
    }
    var selectAccount: ((DetailAccountKey) -> Void)?
    var back: (() -> Void)?
    var close: (() -> Void)?
    var refresh: (() -> Void)?
    var optionsMenu: (() -> NSMenu)?
    var menuTrackingChanged: ((Bool) -> Void)? {
        didSet { providerButton.menuTrackingChanged = menuTrackingChanged }
    }
    var cameraRect: NSRect = .zero {
        didSet {
            // Converted fractional animation frames can differ by floating-point noise only.
            let changed = abs(oldValue.minX - cameraRect.minX) > 0.01 || abs(oldValue.minY - cameraRect.minY) > 0.01 ||
                abs(oldValue.width - cameraRect.width) > 0.01 || abs(oldValue.height - cameraRect.height) > 0.01
            if changed { needsLayout = true }
        }
    }
    override var isFlipped: Bool { true }

    private let backButton = DetailButton(title: "Overview", symbol: "chevron.left")
    private let refreshButton = DetailButton(title: "Refresh", symbol: "arrow.clockwise")
    private let optionsButton = DetailButton(title: "Options", symbol: "ellipsis", showsTitle: false)
    private let closeButton = DetailButton(title: "Close", symbol: "xmark", showsTitle: false)
    private let providerButton = ProviderScopeButton(style: .filled)
    private let accountLabel = DetailText("Account", size: 11, color: DockPalette.secondary)
    private let accountButton: DetailButton = {
        let button = DetailButton(title: "No usage records", style: .filled)
        button.trailingChevron = true
        return button
    }()
    private let countLabel = DetailText("0 accounts", size: 10, color: DockPalette.muted)
    private let statusLabel = DetailText(size: 10, color: DockPalette.secondary)
    private let usageHeading = DetailText("Usage limits", size: 15, weight: .semibold)
    private let detailsHeading = DetailText("Account details", size: 15, weight: .semibold)
    private let legend = DetailText("Used  ·  Remaining  ·  │ Period elapsed", size: 10, color: DockPalette.muted)
    private let limitsScroll = DetailScroll()
    private let detailsScroll = DetailScroll()
    private let limitsDocument = DetailSurface()
    private let detailsDocument = DetailSurface()
    private let emptyLabel = DetailText(size: 12, color: DockPalette.secondary)
    private var cards: [DetailLimitCard] = []
    private var accountCard: DetailAccountCard?
    private var content: ProviderDetailContent?
    private var currentScope: DetailScope = .allAccounts
    private var lastSelection: DetailAccountKey?
    private var lastLayoutSize: NSSize = .zero
    // Metric disclosure state survives clock ticks and data refreshes; it resets with the selected scope/account.
    private var expandedLimits: Set<String> = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let views: [NSView] = [backButton, refreshButton, optionsButton, closeButton, providerButton,
                               accountLabel, accountButton, countLabel, statusLabel, usageHeading, detailsHeading,
                               limitsScroll, detailsScroll, legend]
        for view in views { addSubview(view) }
        providerButton.contextMenu = { [weak self] in self?.optionsMenu?() ?? NSMenu() }
        setupScroll(limitsScroll, document: limitsDocument)
        setupScroll(detailsScroll, document: detailsDocument)
        limitsScroll.setAccessibilityLabel("Usage limits, independently scrollable")
        detailsScroll.setAccessibilityLabel("Account details, independently scrollable")
        limitsDocument.addSubview(emptyLabel)
        for button in [backButton, refreshButton, optionsButton, closeButton, accountButton] {
            button.target = self
            button.contextAction = { [weak self] event in self?.rightMouseDown(with: event) }
        }
        backButton.action = #selector(backPressed)
        refreshButton.action = #selector(refreshPressed)
        optionsButton.action = #selector(optionsPressed)
        closeButton.action = #selector(closePressed)
        accountButton.action = #selector(accountPressed)
        backButton.setAccessibilityLabel("Back to overview")
        refreshButton.setAccessibilityLabel("Refresh usage")
        optionsButton.setAccessibilityLabel("Options")
        closeButton.setAccessibilityLabel("Close to compact view")
        closeButton.toolTip = "Close to compact view · Escape"
        accountButton.setAccessibilityLabel("Account selection")
        countLabel.makeSingleLine()
        statusLabel.makeSingleLine(alignment: .right)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    private func setupScroll(_ scroll: NSScrollView, document: NSView, horizontal: Bool = false) {
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = horizontal
        scroll.hasVerticalScroller = !horizontal
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = horizontal ? .automatic : .none
        scroll.verticalScrollElasticity = horizontal ? .none : .automatic
        scroll.documentView = document
    }

    @discardableResult
    func configure(result: PanelResult?, scope: DetailScope, selectedAccount: DetailAccountKey?, config: PanelConfig,
                   collecting: Bool, transportError: String?, now: Date) -> DetailAccountKey? {
        let next = ProviderDetailModel.make(result: result, scope: scope, selectedAccount: selectedAccount,
                                            config: config, collecting: collecting, transportError: transportError)
        let resetScroll = currentScope != scope || lastSelection != next.selected?.key
        if resetScroll { expandedLimits.removeAll() }
        currentScope = scope
        lastSelection = next.selected?.key
        content = next
        // Content is rebuilt only for a data/configuration update, never an animation frame or clock tick.
        providerButton.update(providers: next.providers, selected: scope)
        accountButton.title = next.selected?.label ?? "No usage records"
        accountButton.toolTip = next.selected?.menuTitle ?? "No account or unavailable report returned"
        accountButton.setAccessibilityValue(next.selected?.menuTitle ?? "No usage records")
        accountButton.isEnabled = next.choices.count > 1
        if DropdownPopupController.shared.isPresented(for: accountButton) {
            if next.choices.count > 1 { presentAccounts() } else { DropdownPopupController.shared.dismiss(for: accountButton) }
        }
        countLabel.stringValue = next.countLabel
        countLabel.toolTip = next.countLabel
        statusLabel.stringValue = next.status
        statusLabel.toolTip = next.status
        statusLabel.setAccessibilityLabel("Usage status, \(next.status)")
        statusLabel.textColor = next.hasIssue ? .systemOrange : DockPalette.secondary
        refreshButton.isEnabled = !collecting
        refreshButton.setAccessibilityLabel(collecting ? "Refreshing usage" : "Refresh usage")
        legend.stringValue = config.showPace ? "Used  ·  Remaining  ·  │ Period elapsed" : "Used  ·  Remaining"
        let focusedCard = cards.firstIndex { window?.firstResponder === $0.disclosure }
        for card in cards { card.removeFromSuperview() }
        cards = next.limits.enumerated().map { index, limit in
            let key = "\(index)\u{0}\(limit.limit.id)"
            let card = DetailLimitCard(model: limit, now: now, expanded: expandedLimits.contains(key))
            card.toggled = { [weak self] expanded in
                if expanded { self?.expandedLimits.insert(key) } else { self?.expandedLimits.remove(key) }
                self?.needsLayout = true
            }
            card.sizeChanged = { [weak self] in self?.needsLayout = true }
            return card
        }
        for card in cards { limitsDocument.addSubview(card) }
        emptyLabel.isHidden = !cards.isEmpty
        emptyLabel.stringValue = next.selected?.unavailable?.reason
            ?? (next.selected == nil ? "No account or unavailable report returned. Refresh to request usage." : "No usage limits reported for this account.")
        accountCard?.removeFromSuperview()
        let account = DetailAccountCard(content: next)
        accountCard = account
        detailsDocument.addSubview(account)
        var keyOrder: [NSView] = [backButton, refreshButton, optionsButton, closeButton, providerButton]
        if accountButton.isEnabled { keyOrder.append(accountButton) }
        keyOrder.append(limitsScroll)
        keyOrder.append(contentsOf: cards.map(\.disclosure))
        keyOrder.append(detailsScroll)
        for index in keyOrder.indices { keyOrder[index].nextKeyView = keyOrder[(index + 1) % keyOrder.count] }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if resetScroll {
            limitsScroll.contentView.scroll(to: .zero)
            limitsScroll.reflectScrolledClipView(limitsScroll.contentView)
            detailsScroll.contentView.scroll(to: .zero)
            detailsScroll.reflectScrolledClipView(detailsScroll.contentView)
        }
        if let focusedCard, cards.indices.contains(focusedCard) { window?.makeFirstResponder(cards[focusedCard].disclosure) }
        return next.selected?.key
    }

    /// Forgets everything tied to previously displayed usage: scope and account selection, metric disclosures,
    /// scroll positions, built cards and the account menu's choices. Account keys do not carry the omp profile, so
    /// identical provider/account IDs under another profile would otherwise inherit this state. Works while the view
    /// is hidden; call it, then `configure` with the new (possibly empty) data so the provider menu is rebuilt too.
    func resetPresentation() {
        expandedLimits.removeAll()
        currentScope = .allAccounts
        lastSelection = nil
        content = nil
        for card in cards { card.removeFromSuperview() }
        cards = []
        accountCard?.removeFromSuperview()
        accountCard = nil
        for scroll in [limitsScroll, detailsScroll] {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        needsLayout = true
    }

    func tick(now: Date) { for card in cards { card.tick(now: now) } }
    func focusSelection() { window?.makeFirstResponder(providerButton) }
    static func preferredSize(availableHeight: CGFloat) -> NSSize {
        let height = availableHeight.isFinite ? max(0, availableHeight) : 610
        return NSSize(width: 900, height: min(height, max(610, height * 0.7)))
    }
    private static func headerPadding(for width: CGFloat) -> CGFloat { width <= 760 ? 20 : 28 }
    // Widths come from ActionMetrics, the same numbers the buttons are laid out and drawn with.
    private static func toolbar(for width: CGFloat) -> (compact: Bool, back: CGFloat, refresh: CGFloat, group: CGFloat, backX: CGFloat, rightEdge: CGFloat) {
        let padding = headerPadding(for: width)
        let compact = max(1, width - padding * 2) < 300
        let icon = ActionMetrics.iconOnlyWidth
        let back = compact ? icon : ActionMetrics.width(title: "Overview", icon: true)
        let refresh = compact ? icon : ActionMetrics.width(title: "Refresh", icon: true)
        // Glyphs, not button edges, sit on the content edges.
        return (compact, back, refresh, refresh + icon * 2 + ActionMetrics.groupGap * 2,
                padding - (compact ? ActionMetrics.glyphBleed : ActionMetrics.inset),
                width - padding + ActionMetrics.glyphBleed)
    }
    static func requiredHeaderHeight(for size: NSSize, cameraRect: NSRect) -> CGFloat {
        // Toolbar controls move together below a camera if either side cannot fit its group.
        guard !cameraRect.isEmpty else { return 51 }
        let bar = toolbar(for: size.width)
        let fits = cameraRect.minX - 8 - bar.backX >= bar.back && bar.rightEdge - bar.group - cameraRect.maxX - 8 >= 0
        return fits ? max(51, cameraRect.maxY + 9) : max(51, cameraRect.maxY + 42)
    }

    override func layout() {
        super.layout()
        let padding = Self.headerPadding(for: bounds.width)
        let usable = max(1, bounds.width - padding * 2)
        let header = Self.requiredHeaderHeight(for: bounds.size, cameraRect: cameraRect)
        let bar = Self.toolbar(for: bounds.width)
        backButton.showsTitle = !bar.compact
        refreshButton.showsTitle = !bar.compact
        let y = header - 37
        let height = ActionMetrics.height
        backButton.frame = NSRect(x: bar.backX, y: y, width: bar.back, height: height)
        closeButton.frame = NSRect(x: bar.rightEdge - ActionMetrics.iconOnlyWidth, y: y,
                                   width: ActionMetrics.iconOnlyWidth, height: height)
        optionsButton.frame = NSRect(x: closeButton.frame.minX - ActionMetrics.groupGap - ActionMetrics.iconOnlyWidth, y: y,
                                     width: ActionMetrics.iconOnlyWidth, height: height)
        refreshButton.frame = NSRect(x: optionsButton.frame.minX - ActionMetrics.groupGap - bar.refresh, y: y,
                                     width: bar.refresh, height: height)
        let barY = header + 6
        let narrow = bounds.width < 570
        let providerWidth = providerButton.preferredWidth(maximum: max(96, usable * 0.30))
        providerButton.frame = NSRect(x: padding, y: barY + 3, width: providerWidth, height: ActionMetrics.height)
        accountLabel.frame = NSRect(x: providerButton.frame.maxX + 14, y: barY + 8, width: 52, height: 18)
        let pickerWidth = min(173, max(80, usable * 0.30))
        accountButton.frame = NSRect(x: accountLabel.frame.maxX + 3, y: barY + 3, width: pickerWidth, height: ActionMetrics.height)
        let infoX = accountButton.frame.maxX + 12
        let rightEdge = bounds.width - padding
        let countWidth = min(countLabel.textWidth, max(0, rightEdge - infoX))
        countLabel.frame = NSRect(x: infoX, y: barY + 8, width: countWidth, height: 18)
        // Status shares the picker row when it has room; narrow widths use the reserved lower line.
        let statusX = countLabel.frame.maxX + 12
        if rightEdge - statusX >= 140 {
            statusLabel.alignment = .right
            statusLabel.frame = NSRect(x: statusX, y: barY + 8, width: rightEdge - statusX, height: 18)
        } else {
            statusLabel.alignment = .left
            statusLabel.frame = NSRect(x: padding, y: barY + 36, width: usable, height: 18)
        }
        let bodyY = barY + 63
        let bodyHeight = max(0, bounds.height - bodyY - 21)
        let gap: CGFloat = bounds.width <= 760 ? 13 : 19
        let leftWidth = narrow ? usable : max(1, (usable - gap) * (bounds.width <= 760 ? 1.7 / 2.7 : 1.85 / 2.85))
        let rightX = narrow ? padding : padding + leftWidth + gap
        let rightWidth = narrow ? usable : max(1, usable - leftWidth - gap)
        let sectionHeight = narrow ? max(0, (bodyHeight - gap) / 2) : bodyHeight
        let rightY = narrow ? bodyY + sectionHeight + gap : bodyY
        usageHeading.frame = NSRect(x: padding, y: bodyY, width: leftWidth, height: 24)
        detailsHeading.frame = NSRect(x: rightX, y: rightY, width: rightWidth, height: 24)
        limitsScroll.frame = NSRect(x: padding, y: bodyY + 32, width: leftWidth, height: max(0, sectionHeight - 57))
        detailsScroll.frame = NSRect(x: rightX, y: rightY + 32, width: rightWidth, height: max(0, sectionHeight - 32))
        legend.frame = NSRect(x: padding, y: bodyY + sectionHeight - 18, width: leftWidth, height: 18)
        var cardY: CGFloat = 0
        for card in cards {
            let height = card.height(for: leftWidth)
            card.frame = NSRect(x: 0, y: cardY, width: leftWidth, height: height)
            cardY += height + 11
        }
        let emptyHeight = emptyLabel.height(for: max(1, leftWidth - 32))
        emptyLabel.frame = NSRect(x: 16, y: 20, width: max(1, leftWidth - 32), height: emptyHeight)
        limitsDocument.frame = NSRect(x: 0, y: 0, width: leftWidth,
                                      height: max(limitsScroll.contentSize.height, cards.isEmpty ? emptyHeight + 40 : cardY - 11))
        if let accountCard {
            // The card is as tall as its content; the document still fills the fixed viewport.
            let height = accountCard.height(for: rightWidth)
            accountCard.frame = NSRect(x: 0, y: 0, width: rightWidth, height: height)
            detailsDocument.frame = NSRect(x: 0, y: 0, width: rightWidth, height: max(detailsScroll.contentSize.height, height))
        }
        if lastLayoutSize != bounds.size {
            limitsScroll.reflectScrolledClipView(limitsScroll.contentView)
            detailsScroll.reflectScrolledClipView(detailsScroll.contentView)
            lastLayoutSize = bounds.size
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) { window?.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) { window?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { window?.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) {
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        showOptions(at: point)
    }
    override func cancelOperation(_ sender: Any?) { close?() }
    @objc private func backPressed() { back?() }
    @objc private func refreshPressed() { refresh?() }
    @objc private func closePressed() { close?() }
    @objc private func accountPressed() {
        let controller = DropdownPopupController.shared
        if controller.isPresented(for: accountButton) {
            controller.dismiss(for: accountButton)
            return
        }
        guard let content, content.choices.count > 1, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        presentAccounts()
    }

    private func presentAccounts() {
        guard let content else { return }
        let selected = content.selected?.key
        let items = content.choices.map { choice -> DropdownItem in
            let key = choice.key
            let providerID: String
            let id: String
            switch key {
            case .account(let provider, let accountID):
                providerID = provider
                id = "account:" + Self.framed(provider) + Self.framed(accountID)
            case .unavailable(let provider, let label, let occurrence):
                providerID = provider
                id = "unavailable:" + Self.framed(provider) + Self.framed(label) + "\(occurrence)"
            }
            let subtitle = choice.providerLabel + (choice.unavailable == nil ? "" : " · unavailable report")
            return DropdownItem(id: id, title: choice.label, subtitle: subtitle,
                                mark: CompactMark.monogram(provider: providerID, label: choice.providerLabel),
                                isSelected: key == selected) { [weak self] in self?.selectAccount?(key) }
        }
        DropdownPopupController.shared.show(anchor: accountButton, items: items,
                                            trackingChanged: { [weak self] in self?.menuTrackingChanged?($0) })
    }

    /// Length-prefixed hex of the exact UTF-8 bytes, so no component value can shift a boundary.
    private static func framed(_ value: String) -> String {
        let bytes = Array(value.utf8)
        return "\(bytes.count)#" + bytes.map { String(format: "%02x", $0) }.joined() + ";"
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { DropdownPopupController.shared.dismiss(for: accountButton) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidHide() {
        DropdownPopupController.shared.dismiss(for: accountButton)
        super.viewDidHide()
    }

    override func removeFromSuperview() {
        DropdownPopupController.shared.dismiss(for: accountButton)
        super.removeFromSuperview()
    }
    @objc private func optionsPressed() {
        let local = optionsButton.convert(NSPoint(x: 0, y: optionsButton.bounds.maxY + 4), to: nil)
        showOptions(at: window?.convertPoint(toScreen: local) ?? NSEvent.mouseLocation)
    }
    // The controller's menu delegate owns the interaction hold for the options menu.
    private func showOptions(at point: NSPoint) {
        if let menu = optionsMenu?() { menu.popUp(positioning: nil, at: point, in: nil) }
    }
}
