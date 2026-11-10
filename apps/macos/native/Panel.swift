import AppKit

final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}


final class UsagePanel: NSPanel {
    var draggingChanged: ((Bool) -> Void)?
    var dragTo: ((NSPoint) -> Void)?
    private var dragStart: (NSPoint, NSPoint)?
    override var canBecomeKey: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) { dragStart = (NSEvent.mouseLocation, NSPoint(x: frame.midX, y: frame.maxY)); draggingChanged?(true) }
        else { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let (start, origin) = dragStart else { super.mouseDragged(with: event); return }
        let point = NSEvent.mouseLocation
        dragTo?(NSPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y))
    }
    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { dragStart = nil; draggingChanged?(false) } else { super.mouseUp(with: event) }
    }
}
final class PaceBar: NSView {
    let fraction: Double?
    var elapsed: Double?
    init(fraction: Double?, elapsed: Double?) { self.fraction = fraction; self.elapsed = elapsed; super.init(frame: .zero); setAccessibilityElement(true); setAccessibilityRole(.progressIndicator); setAccessibilityLabel("Usage \(fraction.map { DisplayModel.number($0 * 100) + " percent" } ?? "unknown"), elapsed \(elapsed.map { DisplayModel.number($0 * 100) + " percent" } ?? "unknown")") }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 4)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let track = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor(calibratedWhite: dark ? 0.32 : 0.78, alpha: 1).setFill(); track.fill()
        if let fraction = fraction, fraction.isFinite {
            NSGraphicsContext.saveGraphicsState(); track.addClip()
            NSColor.systemBlue.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width * min(1, max(0, fraction)), height: rect.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor(calibratedWhite: dark ? 0.55 : 0.56, alpha: 0.85).setStroke(); track.lineWidth = 0.7; track.stroke()
        if let elapsed = elapsed {
            let x = min(rect.maxX - 1.5, max(rect.minX + 1.5, rect.minX + rect.width * elapsed))
            NSColor.black.withAlphaComponent(0.8).setFill(); NSRect(x: x - 1.5, y: rect.minY - 2, width: 3, height: rect.height + 4).fill()
            NSColor.white.setFill(); NSRect(x: x - 0.5, y: rect.minY - 2, width: 1, height: rect.height + 4).fill()
        }
    }
}

private final class DockFrameAnimation: NSAnimation {
    private let updateFrame: (CGFloat, Bool) -> Void

    init(duration: TimeInterval, updateFrame: @escaping (CGFloat, Bool) -> Void) {
        self.updateFrame = updateFrame
        super.init(duration: duration, animationCurve: .easeInOut)
        animationBlockingMode = .nonblocking
        frameRate = 60
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override var currentProgress: NSAnimation.Progress {
        didSet { updateFrame(CGFloat(currentValue), currentProgress >= 1) }
    }
}
final class PanelController: NSObject, NSWindowDelegate, NSPopoverDelegate, NSMenuDelegate {
    private let config: PanelConfig
    private let configPath: String
    private let collector: Collector
    private let panel: UsagePanel
    private let compactContent = NSView()
    private var compactItems: [NSView] = []
    private var compactNeedsLayout = true
    private let dashboard = DashboardView()
    private let compactOverview = CompactStatusButton(frame: .zero)
    private var compactButtons: [String: CompactProviderButton] = [:]
    private let root = DockRootView()
    private let anchor = NSView()
    private var interaction = DockInteraction()
    private var hoverWork: DispatchWorkItem?
    private var keyMonitor: Any?
    private var manualTopCenter: CGPoint?
    private var frameAnimation: DockFrameAnimation?
    private var currentLayout: DockLayout?
    private var currentExpansion: CGFloat = 0
    private var dashboardSize: NSSize = .zero
    private let popover = NSPopover()
    private var result: PanelResult?
    private var transportError: String?
    private var selectedProvider: String?
    private var overview = false
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var collecting = false
    private var clockUpdates: [() -> Void] = []
    private let positionKey = "dockTopCenter"
    private let legacyPositionKey = "panelPosition"

    init(config: PanelConfig, configPath: String) {
        self.config = config; self.configPath = configPath; self.collector = Collector(configPath: configPath, config: config)
        self.panel = UsagePanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 24), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "OMP Usage Panel"; panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.delegate = self; panel.hidesOnDeactivate = false
        root.appearance = NSAppearance(named: .darkAqua)
        root.hoverChanged = { [weak self] in self?.hoverChanged($0) }
        root.contextMenu = { [weak self] in self?.menu() ?? NSMenu() }
        root.openOverview = { [weak self] in self?.openOverview() }
        root.wantsLayer = true; root.layer?.masksToBounds = true
        dashboard.selectProvider = { [weak self] provider in self?.selectProvider(provider) }
        dashboard.openAccounts = { [weak self] in self?.openOverview() }
        dashboard.refresh = { [weak self] in self?.refresh(force: true) }
        dashboard.optionsMenu = { [weak self] in self?.menu() ?? NSMenu() }
        compactOverview.target = self; compactOverview.action = #selector(openOverview)
        compactOverview.contextMenu = { [weak self] in self?.menu() ?? NSMenu() }
        root.addSubview(dashboard); root.addSubview(compactContent); root.addSubview(anchor); panel.contentView = root
        panel.draggingChanged = { [weak self] active in self?.draggingChanged(active) }
        panel.dragTo = { [weak self] origin in self?.dragTo(origin) }
        if let saved = UserDefaults.standard.array(forKey: positionKey) as? [Double], saved.count == 2, saved.allSatisfy({ $0.isFinite }) {
            manualTopCenter = CGPoint(x: saved[0], y: saved[1])
        }
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        collector.completion = { [weak self] result in self?.received(result) }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sessionBecameActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self = self, self.popover.isShown else { return event }
            self.popover.close(); return nil
        }
    }
    func start() {
        renderHeader(); panel.orderFrontRegardless(); refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: max(1, config.refreshSeconds), repeats: true) { [weak self] _ in self?.refresh() }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.currentExpansion > 0 { self.dashboard.tick(now: Date()) }
            self.clockUpdates.forEach { $0() }
        }
    }
    func stop() {
        hoverWork?.cancel(); hoverWork = nil
        cancelFrameAnimation()
        refreshTimer?.invalidate(); clockTimer?.invalidate()
        if let keyMonitor = keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        root.stopTracking(); popover.delegate = nil; popover.close(); panel.orderOut(nil); collector.stop()
        clockUpdates.removeAll()
    }
    @objc private func screensChanged() { if popover.isShown { popover.close() }; positionPanel() }
    @objc private func sessionBecameActive() { screensChanged(); renderHeader() }
    @objc private func refreshAction() { refresh(force: true) }
    private func refresh(force: Bool = false) {
        collecting = true
        if popover.isShown { renderDetail() }
        renderHeader(); collector.collect(force: force)
    }
    private func received(_ value: Result<PanelResult, Error>) {
        collecting = false
        switch value {
        case .success(let newResult):
            if newResult.snapshot == nil, result?.snapshot != nil { transportError = newResult.error ?? "Usage is unavailable" }
            else { result = newResult; transportError = nil }
        case .failure(let error): transportError = error.localizedDescription
        }
        if popover.isShown { renderDetail() }
        renderHeader()
    }
    func popoverDidClose(_ notification: Notification) {
        clockUpdates.removeAll(); interaction.setDetailOpen(false)
        updatePointerAfterHold(); renderHeader(animated: true)
    }
    private func selectedScreen() -> NSScreen? {
        if let point = manualTopCenter, let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) { return screen }
        if manualTopCenter == nil,
           let old = UserDefaults.standard.array(forKey: legacyPositionKey) as? [Double],
           old.count == 2, old.allSatisfy({ $0.isFinite }),
           let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: old[0], y: old[1])) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
    private func metrics(_ screen: NSScreen) -> DockScreenMetrics {
        DockScreenMetrics(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top,
                          menuBarHeight: NSStatusBar.system.thickness, auxiliaryTopLeft: screen.auxiliaryTopLeftArea ?? .zero,
                          auxiliaryTopRight: screen.auxiliaryTopRightArea ?? .zero)
    }
    private var freshness: String {
        if let error = transportError { return "Stale: \(error)" }
        if result?.source == "stale" { return "Stale: \(result?.error ?? "refresh failed")" }
        if result?.source == "unavailable" { return "Unavailable: \(result?.error ?? "no usage data")" }
        return ""
    }
    private func renderHeader(animated: Bool = false) {
        guard !interaction.isMenuOpen, !interaction.isDragging else { return }
        let content = DashboardModel.make(result: result, issue: freshness, collecting: collecting, showPace: config.showPace)
        var occurrences: [String: Int] = [:]
        var next: [String: CompactProviderButton] = [:]
        var ordered: [NSView] = []
        for card in content.cards {
            let occurrence = occurrences[card.provider, default: 0]
            occurrences[card.provider] = occurrence + 1
            let key = "\(card.provider)\u{0}\(occurrence)"
            let button: CompactProviderButton
            if let existing = compactButtons[key] { button = existing }
            else {
                button = CompactProviderButton(frame: .zero)
                button.target = self; button.action = #selector(openProvider(_:))
                button.identifier = NSUserInterfaceItemIdentifier(card.provider)
                button.contextMenu = { [weak self] in self?.menu() ?? NSMenu() }
            }
            button.update(card: card)
            next[key] = button; ordered.append(button)
        }
        compactButtons = next
        compactOverview.update(issue: freshness, collecting: collecting)
        if content.cards.isEmpty { ordered.append(compactOverview) }
        if compactItems.count != ordered.count || !zip(compactItems, ordered).allSatisfy({ $0.0 === $0.1 }) {
            compactItems.forEach { $0.removeFromSuperview() }
            ordered.forEach { compactContent.addSubview($0) }
            compactNeedsLayout = true
        }
        compactItems = ordered
        dashboard.update(content: content, collecting: collecting)
        positionPanel(animated: animated)
    }
    private func positionPanel(animated: Bool = false) {
        guard let screen = selectedScreen() else { return }
        if manualTopCenter == nil, result != nil,
           let old = UserDefaults.standard.array(forKey: legacyPositionKey) as? [Double], old.count == 2, old.allSatisfy({ $0.isFinite }) {
            let summaries = result?.summaries ?? []
            let nameFont = NSFont.systemFont(ofSize: 11, weight: .medium)
            let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            let width = summaries.reduce(CGFloat(0)) { $0 + ($1.label as NSString).size(withAttributes: [.font: nameFont]).width + ($1.value as NSString).size(withAttributes: [.font: valueFont]).width + 12 }
            manualTopCenter = CGPoint(x: CGFloat(old[0]) + min(385, max(40, width + 25)) / 2, y: CGFloat(old[1]) + 24)
            UserDefaults.standard.removeObject(forKey: legacyPositionKey)
        }
        var preferred = DashboardSizing.preferredSize(providerCount: result?.summaries.count ?? 0, cameraHeight: 0)
        let screenMetrics = metrics(screen)
        guard var expanded = DockGeometry.layout(screen: screenMetrics, presentation: .expanded,
                                                preferredExpandedSize: preferred, providerCount: result?.summaries.count ?? 0,
                                                manualTopCenter: manualTopCenter) else {
            cancelFrameAnimation(); panel.orderOut(nil); return
        }
        let requiredHeader = DashboardView.requiredHeaderHeight(for: expanded.bodyRect.size, cameraRect: dashboardCameraRect(in: expanded))
        let extraHeader = max(0, requiredHeader - DashboardSizing.headerHeight(cameraHeight: 0))
        if extraHeader > 0 {
            preferred.height += extraHeader
            guard let adjusted = DockGeometry.layout(screen: screenMetrics, presentation: .expanded,
                                                      preferredExpandedSize: preferred, providerCount: result?.summaries.count ?? 0,
                                                      manualTopCenter: manualTopCenter) else {
                cancelFrameAnimation(); panel.orderOut(nil); return
            }
            expanded = adjusted
        }
        guard let layout = interaction.presentation == .expanded ? expanded :
                DockGeometry.layout(screen: screenMetrics, presentation: .compact,
                                    preferredExpandedSize: preferred, providerCount: result?.summaries.count ?? 0,
                                    manualTopCenter: manualTopCenter) else {
            cancelFrameAnimation(); panel.orderOut(nil); return
        }
        dashboardSize = expanded.bodyRect.size
        let expansion: CGFloat = interaction.presentation == .expanded ? 1 : 0
        let start = currentLayout
        let initialExpansion = currentExpansion
        cancelFrameAnimation()
        if animated, panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           let start = start, start.mode == layout.mode,
           start.frame.maxY == layout.frame.maxY, start.frame.midX == layout.frame.midX,
           initialExpansion != expansion {
            let animation = DockFrameAnimation(duration: max(0.08, 0.24 * abs(expansion - initialExpansion))) { [weak self] progress, finished in
                guard let self = self else { return }
                self.applyLayout(DockGeometry.interpolate(from: start, to: layout, progress: progress),
                                 expansion: initialExpansion + (expansion - initialExpansion) * progress)
                if finished { self.frameAnimation = nil; self.panel.invalidateShadow() }
            }
            frameAnimation = animation
            animation.start()
        } else {
            applyLayout(layout, expansion: expansion)
            panel.invalidateShadow()
        }
        if manualTopCenter != nil {
            manualTopCenter = CGPoint(x: layout.frame.midX, y: layout.frame.maxY)
            UserDefaults.standard.set([Double(layout.frame.midX), Double(layout.frame.maxY)], forKey: positionKey)
        }
    }
    private func cancelFrameAnimation() {
        let animation = frameAnimation
        frameAnimation = nil
        animation?.stop()
    }
    private func dashboardCameraRect(in layout: DockLayout) -> NSRect {
        guard !layout.cameraRect.isEmpty else { return .zero }
        return NSRect(x: layout.cameraRect.minX - layout.bodyRect.minX,
                      y: layout.bodyRect.maxY - layout.cameraRect.maxY,
                      width: layout.cameraRect.width, height: layout.cameraRect.height)
    }
    private func applyLayout(_ layout: DockLayout, expansion: CGFloat) {
        currentLayout = layout; currentExpansion = expansion
        panel.setFrame(layout.frame, display: false)
        root.frame = NSRect(origin: .zero, size: layout.frame.size)
        root.mode = layout.mode; root.bodyRect = layout.bodyRect; root.cameraRect = layout.cameraRect; root.expansion = expansion
        let indicators = DashboardSizing.compactIndicators(count: compactItems.count,
                                                           stripWidth: layout.indicatorRect.width)
        let rowHeight = min(10, layout.indicatorRect.height)
        let rowSize = NSSize(width: indicators.contentWidth, height: rowHeight)
        let needsLayout = compactNeedsLayout || compactContent.bounds.size != rowSize
        compactContent.frame = NSRect(x: layout.indicatorRect.midX - rowSize.width / 2,
                                      y: layout.indicatorRect.midY - rowHeight / 2,
                                      width: rowSize.width, height: rowHeight)
        if needsLayout {
            for (index, view) in compactItems.enumerated() {
                view.frame = NSRect(x: CGFloat(index) * (indicators.itemWidth + indicators.spacing), y: 0,
                                    width: indicators.itemWidth, height: rowHeight)
            }
            compactNeedsLayout = false
        }
        compactContent.alphaValue = max(0, 1 - expansion * 4)
        // Keep the initiating indicator alive until a pressed mouse is released.
        compactContent.isHidden = expansion >= 1 && NSEvent.pressedMouseButtons & 1 == 0
        dashboard.frame = NSRect(x: layout.bodyRect.midX - dashboardSize.width / 2,
                                 y: layout.bodyRect.maxY - dashboardSize.height,
                                 width: dashboardSize.width, height: dashboardSize.height)
        dashboard.cameraRect = layout.cameraRect.isEmpty ? .zero : dashboard.convert(layout.cameraRect, from: root)
        dashboard.alphaValue = max(0, (expansion - 0.2) / 0.8)
        dashboard.isHidden = expansion <= 0
        anchor.frame = NSRect(x: layout.bodyRect.midX - 1, y: layout.bodyRect.minY, width: 2, height: 1)
        let shadow = layout.mode == .floating && expansion > 0.1
        if panel.hasShadow != shadow { panel.hasShadow = shadow }
        root.needsDisplay = true
        panel.displayIfNeeded()
    }
    private func hoverChanged(_ inside: Bool) {
        hoverWork?.cancel()
        if inside, frameAnimation != nil, !interaction.isHovered {
            interaction.setHover(true); renderHeader(animated: true)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.interaction.setHover(inside); self.renderHeader(animated: true)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.18 : 0.25), execute: work)
    }
    private func updatePointerAfterHold() {
        hoverWork?.cancel()
        let inside = panel.frame.contains(NSEvent.mouseLocation)
        interaction.setHover(inside)
        if !inside { hoverChanged(false) }
    }
    private func draggingChanged(_ active: Bool) {
        hoverWork?.cancel(); interaction.setDragging(active)
        if !active { updatePointerAfterHold() }
        if active { positionPanel() } else { renderHeader() }
    }
    private func dragTo(_ origin: NSPoint) {
        manualTopCenter = origin
        positionPanel()
    }
    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: positionKey); UserDefaults.standard.removeObject(forKey: legacyPositionKey)
        manualTopCenter = nil; positionPanel()
    }
    @objc private func openProvider(_ sender: NSButton) {
        guard let provider = sender.identifier?.rawValue else { return }
        selectProvider(provider)
    }
    private func selectProvider(_ provider: String) {
        selectedProvider = provider; overview = false; showPopover()
    }
    @objc private func openOverview() { selectedProvider = nil; overview = true; showPopover() }
    private func showPopover() {
        hoverWork?.cancel(); interaction.setDetailOpen(true); renderHeader()
        if popover.isShown { renderDetail(resetScroll: true); return }
        renderDetail(resetScroll: true); popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        if let scroll = popover.contentViewController?.view as? NSScrollView {
            scroll.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        }
        popover.contentViewController?.view.window?.title = overview ? "OMP Usage — All Accounts" : "OMP Usage — Provider Details"
    }
    private func menu() -> NSMenu {
        hoverWork?.cancel(); interaction.setHover(true); renderHeader(); interaction.setMenuOpen(true)
        let menu = NSMenu(title: "Usage options"); menu.delegate = self
        func item(_ title: String, _ action: Selector) { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        item("Refresh", #selector(refreshAction)); item("All accounts", #selector(openOverview)); item("Open config", #selector(openConfig)); item("Open data folder", #selector(openData)); item("Reset position", #selector(resetPosition)); menu.addItem(.separator()); item("Quit", #selector(quit))
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) {
        hoverWork?.cancel(); interaction.setMenuOpen(true); positionPanel()
    }
    func menuDidClose(_ menu: NSMenu) {
        interaction.setMenuOpen(false); updatePointerAfterHold(); renderHeader(animated: true)
    }
    @objc private func openConfig() { NSWorkspace.shared.open(URL(fileURLWithPath: configPath)) }
    @objc private func openData() { NSWorkspace.shared.open(URL(fileURLWithPath: configPath).deletingLastPathComponent()) }
    @objc private func quit() { NSApp.terminate(nil) }
    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let font = bold ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 11)
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font; field.isSelectable = true
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: ceil(font.ascender - font.descender + font.leading) + 2).isActive = true
        return field
    }
    private func renderDetail(resetScroll: Bool = false) {
        let existingScroll = popover.contentViewController?.view as? NSScrollView
        let previousOrigin = resetScroll ? NSPoint.zero : (existingScroll?.contentView.bounds.origin ?? .zero)
        clockUpdates.removeAll()
        let content = FlippedStackView(); content.orientation = .vertical; content.alignment = .leading; content.spacing = 5; content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        func add(_ text: String, _ bold: Bool = false) { let field = label(text, bold: bold); content.addArrangedSubview(field); field.widthAnchor.constraint(equalToConstant: 366).isActive = true }
        let providerLabel = result?.summaries.first(where: { $0.provider == selectedProvider })?.label ?? selectedProvider ?? "All accounts"
        add(overview ? "All accounts" : providerLabel, true)
        if overview { add("Option-drag the panel to move it. Use Options to reset its position.") }
        if !overview, let summary = result?.summaries.first(where: { $0.provider == selectedProvider }) { for note in summary.notes { add(note) } }
        if collecting { add("Refreshing…") }
        if let error = transportError { add("Stale — \(error)") }
        if let result = result {
            if result.source == "stale" { add("Stale data — \(result.error ?? "refresh failed")") }
            else if result.source == "unavailable" { add("Unavailable — \(result.error ?? "no usage data")") }
            else { add("Source: \(result.source)") }
            if let snapshot = result.snapshot {
                let accounts = snapshot.accounts.filter { overview || $0.provider == selectedProvider }
                if accounts.isEmpty { add("No accounts available") }
                for account in accounts {
                    add("\(account.provider) · \(account.label)\(account.plan.map { " · " + $0 } ?? "")", true)
                    add("Account ID: \(account.id) · Fetched: \(Date(timeIntervalSince1970: account.fetchedAt / 1000).formatted(date: .abbreviated, time: .shortened))")
                    for note in account.notes { add(note) }
                    for limit in account.limits {
                        add("\(limit.label)\(limit.status.map { " · " + $0 } ?? "")", true)
                        add(DisplayModel.amount(limit.amount))
                        if let fraction = limit.usedFraction { add("Usage: \(DisplayModel.number(fraction * 100))%") }
                        else { add("Usage: unknown") }
                        if let window = limit.window {
                            let field = label(""); content.addArrangedSubview(field); field.widthAnchor.constraint(equalToConstant: 366).isActive = true
                            let update = {
                                var text = (window.estimated == true ? "Estimated " : "") + window.label
                                if let reset = window.resetsAt { text += " · Resets \(Date(timeIntervalSince1970: reset / 1000).formatted(date: .abbreviated, time: .shortened)) (\(DisplayModel.countdown(reset)))" }
                                if let resetLabel = window.resetLabel { text += " · " + resetLabel }
                                field.stringValue = text
                            }
                            update(); clockUpdates.append(update)
                        }
                        let bar = PaceBar(fraction: limit.usedFraction, elapsed: config.showPace ? DisplayModel.elapsed(limit.window) : nil)
                        if config.showPace { clockUpdates.append { bar.elapsed = DisplayModel.elapsed(limit.window); bar.needsDisplay = true } }
                        if config.showPace && DisplayModel.elapsed(limit.window) != nil {
                            let field = label(""); content.addArrangedSubview(field); field.widthAnchor.constraint(equalToConstant: 366).isActive = true
                            let update = {
                                guard let elapsed = DisplayModel.elapsed(limit.window) else { return }
                                field.stringValue = "\(limit.window?.estimated == true ? "Estimated elapsed" : "Elapsed"): \(DisplayModel.number(elapsed * 100))%"
                            }
                            update(); clockUpdates.append(update)
                        }
                        content.addArrangedSubview(bar); bar.widthAnchor.constraint(equalToConstant: 366).isActive = true; bar.heightAnchor.constraint(equalToConstant: 16).isActive = true
                        for note in limit.notes { add(note) }
                    }
                }
                for unavailable in snapshot.unavailable where overview || unavailable.provider == selectedProvider { add("\(unavailable.label) (\(unavailable.provider)): unavailable — \(unavailable.reason)") }
            }
        } else { add(transportError == nil ? "Waiting for usage data" : "Usage unavailable") }
        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 8
        for (title, selector) in [("Refresh", #selector(refreshAction)), ("All accounts", #selector(openOverview)), ("Options", #selector(showOptions(_:)))] {
            let button = NSButton(title: title, target: self, action: selector); button.setAccessibilityLabel(title); actions.addArrangedSubview(button)
        }
        content.addArrangedSubview(actions)
        let scroll = existingScroll ?? NSScrollView(frame: NSRect(x: 0, y: 0, width: 390, height: 420))
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        content.setFrameSize(NSSize(width: 390, height: 420))
        content.layoutSubtreeIfNeeded()
        content.setFrameSize(NSSize(width: 390, height: max(420, content.fittingSize.height)))
        scroll.documentView = content
        scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: previousOrigin); scroll.reflectScrolledClipView(scroll.contentView)
        if existingScroll == nil {
            let controller = NSViewController(); controller.view = scroll
            scroll.appearance = NSApp.effectiveAppearance
            popover.contentSize = NSSize(width: 390, height: 420); popover.contentViewController = controller
        }
    }
    @objc private func showOptions(_ sender: NSButton) { menu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender) }
}
