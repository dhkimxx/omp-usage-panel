import AppKit

/// The one custom dropdown list shared by the provider/account pickers and the editable ID suggestions.
/// A genuine scrollable list window (not NSMenu): rows are real NSButtons, so VoiceOver/AX press, labels, values and
/// identifiers come from AppKit. Accessibility identifiers: window `dropdown.popup`, list `dropdown.list`,
/// row `dropdown.row.<item id>`, empty state `dropdown.empty`.
final class DropdownPopupController {
    static let shared = DropdownPopupController()

    private enum Restore { case none, ifPopupKey }

    /// Everything that lives exactly as long as one visible popup. `holdAcquired`/`released` make the tracking hold
    /// strictly once-in, once-out regardless of which dismissal path wins.
    private final class Session {
        weak var anchor: NSView?
        weak var owner: NSWindow?
        let focusMode: DropdownFocusMode
        let trackingChanged: ((Bool) -> Void)?
        var navigationAllowed: (() -> Bool)?
        var didClose: (() -> Void)?
        var items: [DropdownItem]
        var state: DropdownListState
        var ownerWasKey = false
        weak var previousResponder: NSResponder?
        var holdAcquired = false
        var released = false
        var panel: DropdownPanel?
        var surface: DropdownSurfaceView?
        var notifications: [NSObjectProtocol] = []
        var observations: [NSKeyValueObservation] = []
        var localMonitor: Any?
        var globalMonitor: Any?
        var anchorPostedFrameChanges = false

        init(anchor: NSView, items: [DropdownItem], focusMode: DropdownFocusMode,
             trackingChanged: ((Bool) -> Void)?, navigationAllowed: (() -> Bool)?, didClose: (() -> Void)?) {
            self.anchor = anchor
            self.items = items
            self.focusMode = focusMode
            self.trackingChanged = trackingChanged
            self.navigationAllowed = navigationAllowed
            self.didClose = didClose
            state = DropdownListState(rows: Self.rows(items), highlighting: focusMode == .selection ? .automatic : .explicit)
        }

        static func rows(_ items: [DropdownItem]) -> [DropdownListState.Row] {
            items.map { .init(id: $0.id, isEnabled: $0.isEnabled, isSelected: $0.isSelected) }
        }
    }

    private var session: Session?
    // True while a selection's action and the hold release are running; a `show` issued by that action waits for the
    // release so the boolean hold can never end up released after the new popup acquired it.
    private var closing = false
    private var deferredShow: (() -> Void)?

    private init() {}

    var isVisible: Bool { session != nil && !closing }

    func isPresented(for anchor: NSView) -> Bool {
        guard !closing, let session else { return false }
        return session.anchor === anchor
    }

    func show(anchor: NSView, items: [DropdownItem], focusMode: DropdownFocusMode = .selection,
              trackingChanged: ((Bool) -> Void)? = nil,
              navigationAllowed: (() -> Bool)? = nil, didClose: (() -> Void)? = nil) {
        if closing {
            deferredShow = { [weak self, weak anchor] in
                guard let self, let anchor else { return }
                self.show(anchor: anchor, items: items, focusMode: focusMode, trackingChanged: trackingChanged,
                          navigationAllowed: navigationAllowed, didClose: didClose)
            }
            return
        }
        if let current = session, current.anchor === anchor {
            // Same anchor: refresh content and geometry. The hold stays as it is and the popup does not toggle.
            current.items = items
            current.navigationAllowed = navigationAllowed
            current.didClose = didClose
            current.state.replace(rows: Session.rows(items))
            if current.panel != nil { rebuild(current) }
            return
        }
        if session != nil {
            // The old popup's release/didClose may itself ask for another popup. That later request wins and this one
            // is dropped: installing it too would overwrite the newer session and leak its window, monitors and hold.
            close(reason: .none, drainDeferred: false)
            if let newer = deferredShow {
                deferredShow = nil
                newer()
                return
            }
        }
        guard let owner = anchor.window else { return }

        let created = Session(anchor: anchor, items: items, focusMode: focusMode, trackingChanged: trackingChanged,
                              navigationAllowed: navigationAllowed, didClose: didClose)
        created.owner = owner
        created.ownerWasKey = owner.isKeyWindow
        created.previousResponder = owner.firstResponder
        session = created

        // The hold comes first: the owner may animate or reconfigure synchronously, and every geometry and focus
        // decision below must read the final state. The callback may also dismiss us re-entrantly.
        created.holdAcquired = true
        trackingChanged?(true)
        guard session === created, !created.released, anchor.window === owner else {
            if session === created { close(reason: .none) }
            return
        }
        present(created, owner: owner, anchor: anchor)
    }

    func dismiss() {
        guard !closing, let session else { return }
        close(session, restore: .ifPopupKey)
    }

    func dismiss(for anchor: NSView) {
        guard !closing, let session, session.anchor === anchor else { return }
        close(session, restore: .ifPopupKey)
    }

    /// Applies one navigation command. Returns whether the popup consumed it; `false` means the caller keeps the key
    /// (no popup, guard refused for this editor/IME state, or nothing to act on).
    @discardableResult
    func navigate(_ command: DropdownNavigation) -> Bool {
        guard !closing, let session, session.panel != nil else { return false }
        if let allowed = session.navigationAllowed, !allowed() { return false }
        switch session.state.apply(command) {
        case .moved:
            refreshHighlight(session, reveal: true)
            return true
        case .unchanged:
            return true
        case .cancel:
            close(session, restore: .ifPopupKey)
            return true
        case .activate(let index):
            choose(session, id: session.items[index].id)
            return true
        case .ignored:
            return false
        }
    }

    // MARK: Presentation

    private func present(_ session: Session, owner: NSWindow, anchor: NSView) {
        let panel = DropdownPanel(mode: session.focusMode)
        panel.keyHandler = { [weak self] command in self?.navigate(command) ?? false }
        panel.collectionBehavior = owner.collectionBehavior.union(.ignoresCycle)
        panel.level = NSWindow.Level(rawValue: owner.level.rawValue + 1)
        panel.appearance = NSAppearance(named: .darkAqua)
        let surface = DropdownSurfaceView()
        panel.contentView = surface
        session.panel = panel
        session.surface = surface
        rebuild(session)
        guard session.panel != nil else { return }

        install(session, owner: owner, anchor: anchor)
        owner.addChildWindow(panel, ordered: .above)
        if session.focusMode == .selection { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
        // The owner may still be animating after the hold: place again from the settled anchor.
        DispatchQueue.main.async { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            self.reposition(session)
        }
    }

    /// Rebuilds rows for the current items and re-places the window from the current anchor geometry.
    private func rebuild(_ session: Session) {
        guard let surface = session.surface, let anchor = session.anchor else { return }
        surface.setItems(session.items, anchorWidth: anchor.bounds.width,
                         hover: { [weak self, weak session] id in
                             guard let self, let session, self.session === session, !self.closing,
                                   let index = session.items.firstIndex(where: { $0.id == id }) else { return }
                             if session.state.hover(index) { self.refreshHighlight(session, reveal: false) }
                         },
                         pick: { [weak self, weak session] id in
                             guard let self, let session, self.session === session else { return }
                             self.choose(session, id: id)
                         })
        refreshHighlight(session, reveal: false)
        reposition(session)
        refreshHighlight(session, reveal: true)
    }

    private func refreshHighlight(_ session: Session, reveal: Bool) {
        guard let surface = session.surface else { return }
        surface.setHighlight(session.state.highlighted)
        if reveal, let index = session.state.revealIndex { surface.reveal(index) }
    }

    private func reposition(_ session: Session) {
        guard let panel = session.panel, let surface = session.surface,
              let anchor = session.anchor, let owner = anchor.window, owner === session.owner, owner.isVisible else {
            close(session, restore: .none)
            return
        }
        let anchorRect = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = NSScreen.screens.max(by: { overlap($0.frame, anchorRect) < overlap($1.frame, anchorRect) })
            .flatMap { overlap($0.frame, anchorRect) > 0 ? $0 : nil } ?? owner.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchorRect.insetBy(dx: -400, dy: -400)
        let size = surface.preferredSize(anchorWidth: anchorRect.width)
        let frame = DropdownPlacement.frame(anchor: anchorRect, size: size, visible: visible)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        surface.layoutList()
        panel.invalidateShadow()
    }

    private func overlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height
    }

    // MARK: Observation and dismissal triggers

    private func install(_ session: Session, owner: NSWindow, anchor: NSView) {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ object: AnyObject?, _ restore: Restore? = nil) {
            session.notifications.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self, weak session] _ in
                guard let self, let session, self.session === session, !self.closing else { return }
                if let restore { self.close(session, restore: restore) } else { self.reposition(session) }
            })
        }
        observe(NSWindow.didMoveNotification, owner)
        observe(NSWindow.didResizeNotification, owner)
        observe(NSWindow.didChangeScreenNotification, owner)
        observe(NSApplication.didChangeScreenParametersNotification, nil)
        observe(NSWindow.willCloseNotification, owner, Restore.none)
        observe(NSApplication.didResignActiveNotification, NSApp, Restore.none)
        if session.focusMode == .selection {
            // Focus moving to another window of this app ends the popup without taking focus back.
            if let panel = session.panel { observe(NSWindow.didResignKeyNotification, panel, Restore.none) }
        } else {
            // The editor's window losing key status (another window or app) ends the popup.
            observe(NSWindow.didResignKeyNotification, owner, Restore.none)
        }
        session.anchorPostedFrameChanges = anchor.postsFrameChangedNotifications
        anchor.postsFrameChangedNotifications = true
        observe(NSView.frameDidChangeNotification, anchor)

        session.observations.append(owner.observe(\.isVisible, options: [.new]) { [weak self, weak session] _, change in
            guard change.newValue == false else { return }
            DispatchQueue.main.async {
                guard let self, let session, self.session === session, !self.closing else { return }
                self.close(session, restore: .none)
            }
        })
        session.observations.append(anchor.observe(\.window, options: [.new]) { [weak self, weak session] view, _ in
            DispatchQueue.main.async {
                guard let self, let session, self.session === session, !self.closing else { return }
                if view.window !== session.owner { self.close(session, restore: .none) }
            }
        })

        let mouseDowns: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        session.localMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDowns) { [weak self, weak session] event in
            guard let self, let session, self.session === session, !self.closing, let panel = session.panel else { return event }
            if event.window === panel { return event }
            // A primary click on the opener never takes the generic outside-click dismissal below.
            if event.type == .leftMouseDown, let anchor = session.anchor, event.window != nil,
               event.window === anchor.window,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                // Selection opener button: this press IS the toggle. Close now and consume the down, so the button never
                // sees a closed popup and reopens it (and AppKit never makes the owner key mid-click, which would
                // resign the popup). Text-editor anchors (preserveEditor) keep receiving their caret/chevron clicks
                // and toggle through isPresented/dismiss.
                if session.focusMode == .selection, anchor is NSButton {
                    self.close(session, restore: .ifPopupKey)
                    return nil
                }
                return event
            }
            self.close(session, restore: .none)
            return event
        }
        session.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDowns) { [weak self, weak session] _ in
            guard let self, let session, self.session === session, !self.closing else { return }
            self.close(session, restore: .none)
        }
    }

    // MARK: Selection and teardown

    /// Resolves the CURRENT enabled item by its stable id at activation time. A row that outlived a same-anchor
    /// refresh (e.g. mouse tracking across a list update) can therefore never run a different or removed choice.
    private func choose(_ session: Session, id: String) {
        guard self.session === session, !closing,
              let index = session.state.enabledIndex(forID: id), session.items.indices.contains(index) else { return }
        let action = session.items[index].action
        close(session, restore: .ifPopupKey, action: action)
    }

    private func close(reason: Restore, drainDeferred: Bool = true) {
        guard let session else { return }
        close(session, restore: reason, drainDeferred: drainDeferred)
    }

    /// Tears the popup down, restores focus only when appropriate, runs the selected action, then releases the hold
    /// exactly once (action before release, as the former NSMenu flow did).
    private func close(_ target: Session, restore: Restore, action: (() -> Void)? = nil, drainDeferred: Bool = true) {
        guard session === target, !closing else { return }
        closing = true
        session = nil

        let center = NotificationCenter.default
        for token in target.notifications { center.removeObserver(token) }
        target.notifications.removeAll()
        target.observations.forEach { $0.invalidate() }
        target.observations.removeAll()
        if let monitor = target.localMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = target.globalMonitor { NSEvent.removeMonitor(monitor) }
        target.localMonitor = nil
        target.globalMonitor = nil
        if let anchor = target.anchor { anchor.postsFrameChangedNotifications = target.anchorPostedFrameChanges }

        let popupWasKey = target.panel?.isKeyWindow == true
        // A row's own action may be what dismisses us; keep the window and rows alive until its event handling unwinds.
        let retainedPanel = target.panel, retainedSurface = target.surface
        DispatchQueue.main.async { _ = (retainedPanel, retainedSurface) }
        if let panel = target.panel {
            panel.keyHandler = nil
            target.owner?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.close()
        }
        target.panel = nil
        target.surface = nil

        // Restored before the action so an action that focuses its destination keeps that focus.
        if restore == .ifPopupKey, popupWasKey, target.ownerWasKey, let owner = target.owner, owner.isVisible {
            owner.makeKey()
            if let responder = target.previousResponder as? NSView, responder.window === owner {
                owner.makeFirstResponder(responder)
            }
        }

        action?()
        if target.holdAcquired, !target.released {
            target.released = true
            target.trackingChanged?(false)
        }
        let didClose = target.didClose
        target.didClose = nil
        didClose?()

        closing = false
        if drainDeferred, let next = deferredShow {
            deferredShow = nil
            next()
        }
    }
}

// MARK: - Window

private final class DropdownPanel: NSPanel {
    var keyHandler: ((DropdownNavigation) -> Bool)?
    private let mode: DropdownFocusMode

    init(mode: DropdownFocusMode) {
        self.mode = mode
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Dropdown list"
        setAccessibilityIdentifier("dropdown.popup")
        setAccessibilityLabel("Dropdown list")
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = false
    }

    // `preserveEditor` popups never take key status, so the owner's field editor and marked text are untouched.
    override var canBecomeKey: Bool { mode == .selection }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        let blocked: NSEvent.ModifierFlags = [.command, .control, .option]
        if event.modifierFlags.intersection(blocked).isEmpty {
            let command: DropdownNavigation?
            switch event.keyCode {
            case 125: command = .down
            case 126: command = .up
            case 115: command = .first
            case 119: command = .last
            case 36, 76, 49: command = .activate
            case 53: command = .cancel
            default: command = nil
            }
            if let command, keyHandler?(command) == true { return }
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { _ = keyHandler?(.cancel) }
}

// MARK: - Content

/// Dark rounded surface hosting the scrolling list (or the empty-state label).
final class DropdownSurfaceView: NSView {
    private let scroll = NSScrollView()
    private let list = DropdownListView()
    private let empty = NSTextField(labelWithString: "No choices")
    private var rowHeight: CGFloat = DropdownMetrics.rowHeight(hasSubtitle: false)
    private var contentWidth: CGFloat = DropdownMetrics.minimumWidth
    private var itemCount = 0
    private var rows: [DropdownRowButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1).cgColor
        layer?.borderColor = NSColor(calibratedWhite: 0.26, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        scroll.documentView = list
        addSubview(scroll)

        empty.font = .systemFont(ofSize: 12)
        empty.textColor = DockPalette.muted
        empty.alignment = .center
        empty.setAccessibilityIdentifier("dropdown.empty")
        empty.isHidden = true
        addSubview(empty)

        list.setAccessibilityIdentifier("dropdown.list")
        list.setAccessibilityRole(.list)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override var isFlipped: Bool { true }

    func setItems(_ items: [DropdownItem], anchorWidth: CGFloat,
                  hover: @escaping (String) -> Void, pick: @escaping (String) -> Void) {
        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        itemCount = items.count
        let hasSubtitle = items.contains { $0.subtitle?.isEmpty == false }
        let reservesMark = items.contains { $0.mark?.isEmpty == false }
        rowHeight = DropdownMetrics.rowHeight(hasSubtitle: hasSubtitle)
        var widest: CGFloat = 0
        for item in items {
            let row = DropdownRowButton(item: item, reservesMark: reservesMark)
            row.hovered = hover
            row.picked = pick
            widest = max(widest, row.preferredWidth)
            list.addSubview(row)
            rows.append(row)
        }
        contentWidth = DropdownMetrics.width(content: widest + DropdownMetrics.listInset * 2, anchorWidth: anchorWidth)
        empty.isHidden = !items.isEmpty
        scroll.isHidden = items.isEmpty
        list.setAccessibilityLabel(items.isEmpty ? "No choices" : "Choices")
    }

    func preferredSize(anchorWidth: CGFloat) -> CGSize {
        let width = DropdownMetrics.width(content: contentWidth, anchorWidth: anchorWidth)
        return CGSize(width: width, height: DropdownMetrics.cappedHeight(rowCount: itemCount, rowHeight: rowHeight))
    }

    /// Lays out rows for the current window size; the row column is the scroll view's document.
    func layoutList() {
        scroll.frame = bounds
        empty.frame = NSRect(x: 0, y: (bounds.height - 18) / 2, width: bounds.width, height: 18)
        let inset = DropdownMetrics.listInset
        let width = bounds.width
        list.frame = NSRect(x: 0, y: 0, width: width,
                            height: DropdownMetrics.contentHeight(rowCount: itemCount, rowHeight: rowHeight))
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: inset, y: inset + CGFloat(index) * rowHeight,
                               width: width - inset * 2, height: rowHeight)
        }
    }

    func setHighlight(_ index: Int?) {
        for (offset, row) in rows.enumerated() { row.isActive = offset == index }
    }

    func reveal(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        list.scrollToVisible(rows[index].frame.insetBy(dx: 0, dy: -DropdownMetrics.listInset))
    }
}

private final class DropdownListView: NSView {
    override var isFlipped: Bool { true }
}

/// One real NSButton row. Pointer motion highlights, click or AX press activates; keyboard focus stays with the
/// popup (or the owner's editor), never with the row.
private final class DropdownRowButton: NSButton {
    var hovered: ((String) -> Void)?
    var picked: ((String) -> Void)?
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    private let itemID: String
    private let subtitle: String?
    private let mark: String?
    private let selectedMark: Bool
    private let reservesMark: Bool
    private let titleAttributed: NSAttributedString
    private let subtitleAttributed: NSAttributedString?
    private var tracking: NSTrackingArea?

    private static let markSize: CGFloat = 22
    private static let leading: CGFloat = 8
    private static let trailing: CGFloat = 28

    init(item: DropdownItem, reservesMark: Bool) {
        itemID = item.id
        subtitle = item.subtitle?.isEmpty == false ? item.subtitle : nil
        mark = item.mark?.isEmpty == false ? item.mark : nil
        selectedMark = item.isSelected
        self.reservesMark = reservesMark
        let color = item.isEnabled ? DockPalette.primaryText : DockPalette.muted
        titleAttributed = DockPalette.text(item.title, size: 12.5, weight: item.isSelected ? .semibold : .regular, color: color)
        subtitleAttributed = subtitle.map { DockPalette.text($0, size: 10, color: item.isEnabled ? DockPalette.secondary : DockPalette.muted) }
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        title = item.title
        isEnabled = item.isEnabled
        target = self
        action = #selector(pressed)
        setAccessibilityIdentifier("dropdown.row.\(item.id)")
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
        setAccessibilityHelp(subtitle)
        setAccessibilityValue(item.isSelected ? "selected" : "")
        setAccessibilitySelected(item.isSelected)
        setAccessibilityEnabled(item.isEnabled)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }

    private var textX: CGFloat { Self.leading + (reservesMark ? Self.markSize + 9 : 0) }

    var preferredWidth: CGFloat {
        let text = max(titleAttributed.size().width, subtitleAttributed?.size().width ?? 0)
        return ceil(textX + text + Self.trailing)
    }

    @objc private func pressed() { picked?(itemID) }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        // Only real pointer motion highlights: rows scrolling under a still pointer must not steal the keyboard highlight.
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        if isEnabled { hovered?(itemID) }
    }

    override func layout() {
        super.layout()
        let available = bounds.width - textX - Self.trailing
        let truncated = titleAttributed.size().width > available || (subtitleAttributed?.size().width ?? 0) > available
        let full = subtitle.map { "\(title) — \($0)" } ?? title
        toolTip = truncated ? full : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        if isActive && isEnabled {
            (isHighlighted ? NSColor(calibratedWhite: 0.24, alpha: 1) : NSColor(calibratedWhite: 0.19, alpha: 1)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let midY = bounds.midY
        if reservesMark {
            let badge = NSRect(x: Self.leading, y: midY - Self.markSize / 2, width: Self.markSize, height: Self.markSize)
            if let mark {
                (isEnabled ? NSColor(calibratedWhite: 0.22, alpha: 1) : NSColor(calibratedWhite: 0.14, alpha: 1)).setFill()
                NSBezierPath(ovalIn: badge).fill()
                let text = DockPalette.text(mark, size: mark.count > 2 ? 8 : 9, weight: .semibold,
                                            color: isEnabled ? DockPalette.primaryText : DockPalette.muted, alignment: .center)
                let height = text.size().height
                text.draw(in: NSRect(x: badge.minX, y: badge.midY - height / 2, width: badge.width, height: height))
            }
        }
        let available = max(0, bounds.width - textX - Self.trailing)
        let titleHeight = titleAttributed.size().height
        if let subtitleAttributed {
            let subtitleHeight = subtitleAttributed.size().height
            let top = midY - (titleHeight + subtitleHeight + 1) / 2
            titleAttributed.draw(in: NSRect(x: textX, y: top, width: available, height: titleHeight))
            subtitleAttributed.draw(in: NSRect(x: textX, y: top + titleHeight + 1, width: available, height: subtitleHeight))
        } else {
            titleAttributed.draw(in: NSRect(x: textX, y: midY - titleHeight / 2, width: available, height: titleHeight))
        }
        if selectedMark {
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(.init(paletteColors: [isEnabled ? DockPalette.primaryText : DockPalette.muted]))
            if let image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = image.size
                image.draw(in: NSRect(x: bounds.width - 12 - size.width, y: midY - size.height / 2,
                                      width: size.width, height: size.height))
            }
        }
    }
}
