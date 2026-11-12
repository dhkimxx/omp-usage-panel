import AppKit

final class UsagePanel: NSPanel {
    var draggingChanged: ((Bool) -> Void)?
    var dragTo: ((NSPoint) -> Void)?
    var dragAnchor: (() -> NSPoint?)?
    private var dragStart: (NSPoint, NSPoint)?
    override var canBecomeKey: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            dragStart = (NSEvent.mouseLocation, dragAnchor?() ?? NSPoint(x: frame.midX, y: frame.maxY)); draggingChanged?(true)
        }
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
final class PanelController: NSObject, NSWindowDelegate, NSMenuDelegate {
    private var config: PanelConfig
    private let configStore: PanelConfigStore
    private var collector: Collector
    private let panel: UsagePanel
    // Two independent content rows share the single fused root; each moves as one unit like the former single row.
    private let compactLeftContent = NSView()
    private let compactRightContent = NSView()
    private lazy var compactRows = CompactRowReconciler(left: compactLeftContent, right: compactRightContent)
    private var compactLeftItems: [NSView] { compactRows.leftItems }
    private var compactRightItems: [NSView] { compactRows.rightItems }
    private var compactNeedsLayout = true
    private let dashboard = DashboardView()
    private var compactStore: CompactPreferencesStore
    private let generalSettings = GeneralSettingsWindowController()
    // One coordinator for the whole app lifetime (owned by AppDelegate). It is independent of `generation`:
    // usage configuration changes never recreate it or reset its policy.
    private let updater: UpdaterCoordinator
    private var compactViews: [String: NSView] = [:]
    private var compactCards: [DashboardCard] = []
    private var compactIssue = ""
    private var compactCollecting = false
    private var compactRevision = 0
    private var compactPlanRevision = -1
    private var compactPlanCapacities: CompactCapacities?
    private var compactPlan = CompactSlotPlan(leftSlots: [], rightSlots: [], selectedCount: 0, hiddenProviderIDs: [])
    private var realizedLayout: DockLayout?
    private let root = DockRootView()
    private let detail = ProviderDetailView()
    private var detailScope: DetailScope = .allAccounts
    private var selectedAccount: DetailAccountKey?
    private var showingDetail = false
    private var detailBlend: CGFloat = 0
    private var detailSize: NSSize = .zero
    private var compactLayout: DockLayout?
    private var hoverGate = DockHoverGate()
    private var interaction = DockInteraction()
    private var hoverWork: DispatchWorkItem?
    private var pendingHover: Bool?
    private var keyMonitor: Any?
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var manualTopCenter: CGPoint?
    private var frameAnimation: DockFrameAnimation?
    private var animationTarget: DockLayout?
    private var animationTargetExpansion: CGFloat = 0
    private var animationTargetBlend: CGFloat = 0
    private var currentLayout: DockLayout?
    private var currentExpansion: CGFloat = 0
    private var dashboardSize: NSSize = .zero
    private var result: PanelResult?
    private var transportError: String?
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var collecting = false
    // Advances on every committed configuration change; callbacks bound to an older value are obsolete.
    private var generation = 0
    private let positionKey = "dockTopCenter"
    private let legacyPositionKey = "panelPosition"
    private var updateReevaluationQueued = false
    // True while a Settings suggestion list is open. It only gates updater cutover; it never touches DockInteraction,
    // panel geometry or hover, so the compact notch stays compact behind Settings.
    private var settingsDropdownOpen = false

    init(configStore: PanelConfigStore, updater: UpdaterCoordinator) {
        let config = configStore.config
        self.configStore = configStore; self.config = config; self.updater = updater
        self.collector = Collector(configPath: configStore.configPath, config: config)
        self.compactStore = CompactPreferencesStore(configPath: configStore.configPath, profile: config.profile)
        self.panel = UsagePanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 24), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "OMP Usage Panel"; panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.delegate = self; panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        root.appearance = NSAppearance(named: .darkAqua)
        root.hoverChanged = { [weak self] in self?.reconcilePointer() }
        root.contextMenu = { [weak self] in self?.menu() ?? NSMenu() }
        root.openOverview = { [weak self] in self?.rootPressed() }
        root.wantsLayer = true; root.layer?.masksToBounds = true
        dashboard.selectProvider = { [weak self] provider in self?.selectProvider(provider) }
        dashboard.selectScope = { [weak self] scope in self?.openDetail(scope: scope) }
        dashboard.menuTrackingChanged = { [weak self] in self?.menuTrackingChanged($0) }
        dashboard.refresh = { [weak self] in self?.refresh(force: true) }
        dashboard.optionsMenu = { [weak self] in self?.menu() ?? NSMenu() }
        generalSettings.saveRequested = { [weak self] commit in
            guard let self = self else { return }
            try self.saveSettings(commit)
        }
        generalSettings.compactSnapshotRequested = { [weak self] profile in
            self?.compactSnapshot(profile: profile) ?? CompactSettingsSnapshot(preferences: CompactPreferences(), providers: [])
        }
        generalSettings.checkRequested = { [weak self] in self?.updater.checkForUpdates() }
        generalSettings.installRequested = { [weak self] in self?.updater.installAvailableUpdate() }
        generalSettings.interactionReleased = { [weak self] in self?.updateInteractionMayHaveReleased() }
        generalSettings.configLocation = configStore.configPath
        updater.canPresentNotice = { [weak self] in self?.updateNoticeIsQuiet ?? false }
        updater.canInstallUpdate = { [weak self] explicit in self?.updateCutoverIsSafe(explicit: explicit) ?? false }
        updater.statusChanged = { [weak self] status in self?.generalSettings.updateStatus(status) }
        updater.policyChanged = { [weak self] policy in self?.generalSettings.committedPolicyChanged(policy) }
        updater.showUpdatesRequested = { [weak self] in self?.presentUpdates(check: false) }
        generalSettings.updateStatus(updater.status)
        detail.selectScope = { [weak self] scope in self?.openDetail(scope: scope) }
        detail.selectAccount = { [weak self] key in
            self?.selectedAccount = key
            self?.configureDetail()
        }
        detail.back = { [weak self] in self?.openOverview() }
        detail.close = { [weak self] in self?.dismiss() }
        detail.refresh = { [weak self] in self?.refresh(force: true) }
        detail.optionsMenu = { [weak self] in self?.menu() ?? NSMenu() }
        detail.menuTrackingChanged = { [weak self] in self?.menuTrackingChanged($0) }
        generalSettings.dropdownTrackingChanged = { [weak self] active in
            guard let self = self else { return }
            self.settingsDropdownOpen = active
            if !active { self.updateInteractionMayHaveReleased() }
        }
        root.addSubview(dashboard); root.addSubview(detail)
        root.addSubview(compactLeftContent); root.addSubview(compactRightContent); panel.contentView = root
        panel.draggingChanged = { [weak self] active in self?.draggingChanged(active) }
        panel.dragTo = { [weak self] origin in self?.dragTo(origin) }
        panel.dragAnchor = { [weak self] in self?.dragStartAnchor() }
        if let saved = UserDefaults.standard.array(forKey: positionKey) as? [Double], saved.count == 2, saved.allSatisfy({ $0.isFinite }) {
            manualTopCenter = CGPoint(x: saved[0], y: saved[1])
        }
        bindCollector()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sessionBecameActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self = self,
                  event.window === self.panel, self.interaction.presentation == .expanded,
                  !self.interaction.isMenuOpen, !self.interaction.isDragging else { return event }
            self.dismiss(); return nil
        }
        let pointerEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { [weak self] event in
            self?.observePointer(event); return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents) { [weak self] event in
            self?.observePointer(event)
        }
    }
    func start() {
        renderHeader(); panel.orderFrontRegardless(); refresh()
        scheduleRefreshTimer()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.currentExpansion > 0 {
                if self.showingDetail { self.detail.tick(now: Date()) }
                else { self.dashboard.tick(now: Date()) }
            }
        }
    }
    func stop() {
        generalSettings.close()
        cancelHover()
        cancelFrameAnimation()
        refreshTimer?.invalidate(); clockTimer?.invalidate()
        removeEventMonitors()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        root.stopTracking(); panel.orderOut(nil); collector.stop()
    }
    deinit {
        removeEventMonitors()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        refreshTimer?.invalidate(); clockTimer?.invalidate()
    }
    private func removeEventMonitors() {
        for monitor in [keyMonitor, localPointerMonitor, globalPointerMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil; localPointerMonitor = nil; globalPointerMonitor = nil
    }
    @objc private func screensChanged() { positionPanel() }
    @objc private func sessionBecameActive() { screensChanged(); renderHeader() }
    @objc private func refreshAction() { refresh(force: true) }
    private func refresh(force: Bool = false, ignoringHolds: Bool = false) {
        collecting = true
        renderHeader(ignoringHolds: ignoringHolds); collector.collect(force: force)
    }
    // Every callback is bound to the generation that created it, so an obsolete collector or timer fire
    // can never mutate current state (results, compact seed, spinner, catalogs).
    private func bindCollector() {
        let generation = self.generation
        collector.completion = { [weak self] value in
            guard let self = self, self.generation == generation else { return }
            self.received(value)
        }
    }
    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let generation = self.generation
        refreshTimer = Timer.scheduledTimer(withTimeInterval: max(1, config.refreshSeconds), repeats: true) { [weak self] _ in
            guard let self = self, self.generation == generation else { return }
            self.refresh()
        }
    }
    // One unified commit. Order is deliberate so a failure never leaves a half-applied state:
    // 1. every compact draft is validated and pre-encoded (nothing is written yet);
    // 2. the configuration file is replaced atomically (a no-op when unchanged); a throw here leaves
    //    preferences, runtime and policy untouched and the caller keeps the draft open;
    // 3. prepared compact defaults are written to their explicitly scoped stores (no throwing step remains);
    // 4. the runtime adopts the configuration once, or just re-plans after a compact-only change;
    // 5. the updater policy lives in a different store and is applied last.
    private func saveSettings(_ commit: SettingsCommit) throws {
        let path = configStore.configPath
        let currentKey = CompactPreferencesStore.storageKey(configPath: path, profile: config.profile)
        var staged: [(key: String, store: CompactPreferencesStore, prepared: PreparedCompactPreferences)] = []
        for change in commit.compactChanges {
            let key = CompactPreferencesStore.storageKey(configPath: path, profile: change.profile)
            // The running store receives its own scope so memory and defaults never diverge.
            let store = key == currentKey ? compactStore : CompactPreferencesStore(configPath: path, profile: change.profile)
            let prepared = try store.prepare(change.preferences)
            if let index = staged.firstIndex(where: { $0.key == key }) { staged[index] = (key, store, prepared) }
            else { staged.append((key, store, prepared)) }
        }
        try configStore.save(commit.config)
        for entry in staged { entry.store.savePrepared(entry.prepared) }
        let committed = configStore.config
        if committed != config {
            let nodeChanged = committed.nodePath != config.nodePath
            applyConfiguration(committed)
            if nodeChanged { updater.updateRuntime(config: committed, configPath: configStore.configPath) }
        } else if staged.contains(where: { $0.key == currentKey }) {
            // Compact-only: keep the collector, result and detail state; only plans and views are refreshed.
            compactRevision += 1
            updateSettingsCatalog()
            renderHeader()
        }
        if commit.updatePolicy != updater.policy { updater.applyPolicy(commit.updatePolicy) }
    }
    // Synchronous main-thread transition to a freshly committed configuration. Nothing from the previous one
    // (collector, queued timer fire, result, selection, disclosure, tooltip or catalog) survives it, and no
    // profile's data is kept as a fallback for another profile's failure. The long-lived clock timer and
    // event monitors are untouched; the cache is reused by one ordinary collection, never invalidated.
    private func applyConfiguration(_ next: PanelConfig) {
        let path = configStore.configPath
        let profileScopeChanged = CompactPreferencesStore.storageKey(configPath: path, profile: config.profile)
            != CompactPreferencesStore.storageKey(configPath: path, profile: next.profile)
        generation += 1
        refreshTimer?.invalidate(); refreshTimer = nil
        collector.completion = nil
        collector.stop()
        if profileScopeChanged {
            // Existing per-profile preferences stay untouched; each profile keeps its own bucket.
            compactStore = CompactPreferencesStore(configPath: path, profile: next.profile)
        }
        config = next
        collector = Collector(configPath: path, config: next)
        bindCollector()
        result = nil; transportError = nil; collecting = true
        // Account keys do not carry the profile, so selection and disclosure state must be reset explicitly,
        // including the hidden detail view.
        selectedAccount = nil; detailScope = .allAccounts
        detail.resetPresentation(); configureDetail()
        updateSettingsCatalog(); generalSettings.updateCatalog(result: nil)
        scheduleRefreshTimer()
        refresh(ignoringHolds: true)
    }
    private func received(_ value: Result<PanelResult, Error>) {
        collecting = false
        switch value {
        case .success(let newResult):
            if newResult.snapshot == nil, result?.snapshot != nil { transportError = newResult.error ?? "Usage is unavailable" }
            else {
                result = newResult; transportError = nil
                // Membership is seeded before any compact render and independent of render holds.
                compactStore.initializeSelectionIfNeeded(summaries: newResult.summaries)
            }
        case .failure(let error): transportError = error.localizedDescription
        }
        updateSettingsCatalog()
        generalSettings.updateCatalog(result: result)
        renderHeader()
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
    private func renderHeader(animated: Bool = false, ignoringHolds: Bool = false) {
        // A configuration change must never leave the previous profile's content exposed behind a menu or drag hold.
        guard ignoringHolds || (!interaction.isMenuOpen && !interaction.isDragging) else { return }
        let content = DashboardModel.make(result: result, issue: freshness, collecting: collecting, showPace: config.showPace)
        // The compact selection is separate from `content`, which stays complete for the overview/detail.
        compactCards = content.cards
        compactIssue = freshness
        compactCollecting = collecting
        compactRevision += 1
        dashboard.update(content: content, collecting: collecting,
                         providers: ProviderDetailModel.catalog(result: result, scope: detailScope, config: config).providers)
        if showingDetail { configureDetail() }
        positionPanel(animated: animated)
    }
    // Re-plans only when content, preferences or physical capacity changed (never per paint/hover).
    // Returns the actual number of compact controls on each wing (either may be zero) for the layouts.
    private func updateCompactPlan(capacities: CompactCapacities) -> (left: Int, right: Int) {
        if compactPlanRevision != compactRevision || compactPlanCapacities != capacities
            || (compactLeftItems.isEmpty && compactRightItems.isEmpty) {
            let plan = CompactSlotPlanner.plan(cards: compactCards, preferences: compactStore.preferences,
                                               physicalCapacity: capacities, aliases: config.labels,
                                               issue: compactIssue, collecting: compactCollecting)
            compactPlanRevision = compactRevision; compactPlanCapacities = capacities
            compactPlan = plan
            rebuildCompactViews()
        }
        return (compactPlan.leftSlots.count, compactPlan.rightSlots.count)
    }
    private func rebuildCompactViews() {
        func configured<T: DockButton>(_ button: T, _ action: Selector) -> T {
            button.target = self; button.action = action
            button.contextMenu = { [weak self] in self?.menu() ?? NSMenu() }
            return button
        }
        var next: [String: NSView] = [:]
        func views(for slots: [CompactSlot]) -> [NSView] {
            slots.map { slot in
                let view: NSView
                switch slot {
                case .provider(let presentation):
                    let button = (compactViews[slot.key] as? CompactRingButton)
                        ?? configured(CompactRingButton(frame: .zero), #selector(openProvider(_:)))
                    button.update(presentation); view = button
                case .more(let presentation):
                    let button = (compactViews[slot.key] as? CompactMoreButton)
                        ?? configured(CompactMoreButton(frame: .zero), #selector(openOverview))
                    button.update(presentation); view = button
                case .configure(let presentation):
                    let button = (compactViews[slot.key] as? CompactConfigureButton)
                        ?? configured(CompactConfigureButton(frame: .zero), #selector(openDisplaySettings))
                    button.update(presentation); view = button
                }
                next[slot.key] = view
                return view
            }
        }
        let left = views(for: compactPlan.leftSlots)
        let right = views(for: compactPlan.rightSlots)
        compactViews = next
        // Views keep their identity across data refreshes; the reconciler compares the ACTUAL hierarchy and detaches
        // both wings' stale children before attaching, so a direct side change cannot orphan a reparented view.
        compactRows.apply(left: left, right: right)
        compactNeedsLayout = true
    }
    // Live provider exposure choices: every current provider, then selected IDs the data lacks.
    private func liveCompactChoices(for preferences: CompactPreferences) -> [CompactProviderChoice] {
        var known = Set<String>()
        var choices: [CompactProviderChoice] = []
        for summary in result?.summaries ?? [] where known.insert(summary.provider).inserted {
            let reported = summary.accountCount > 0
            let value = reported ? summary.value : "No usage report"
            choices.append(CompactProviderChoice(
                id: summary.provider, label: summary.label,
                detail: summary.label == summary.provider ? value : "\(summary.provider) · \(value)",
                isReported: reported))
        }
        for id in preferences.selectedProviderIDs ?? [] where known.insert(id).inserted {
            let label = config.labels[id] ?? id
            choices.append(CompactProviderChoice(
                id: id, label: label,
                detail: label == id ? "Not in the current usage report" : "\(id) · Not in the current usage report",
                isReported: false))
        }
        return choices
    }
    // Read-only snapshot for the profile being edited. Only the running profile's scope may borrow live usage;
    // any other scope shows its saved preferences with neutral saved-ID rows, never another profile's data.
    private func compactSnapshot(profile: String) -> CompactSettingsSnapshot {
        let path = configStore.configPath
        if CompactPreferencesStore.storageKey(configPath: path, profile: profile)
            == CompactPreferencesStore.storageKey(configPath: path, profile: config.profile) {
            let preferences = compactStore.preferences
            return CompactSettingsSnapshot(preferences: preferences, providers: liveCompactChoices(for: preferences))
        }
        let preferences = CompactPreferencesStore(configPath: path, profile: profile).preferences
        let providers = (preferences.selectedProviderIDs ?? []).map {
            CompactProviderChoice(id: $0, label: $0, detail: "Saved selection · no usage shown for this profile", isReported: false)
        }
        return CompactSettingsSnapshot(preferences: preferences, providers: providers)
    }
    // Refreshes the open Settings window's saved baseline/catalog for the running profile. Runs on every accepted
    // result, independent of render holds; unedited drafts follow it, edited fields never move.
    private func updateSettingsCatalog() {
        generalSettings.updateCompactSnapshot(compactSnapshot(profile: config.profile), profile: config.profile)
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
        let screenMetrics = metrics(screen)
        let bottom = max(screenMetrics.frame.minY, screenMetrics.visibleFrame.minY)
        let availableHeight = max(1, screenMetrics.frame.maxY - bottom)
        let slots = updateCompactPlan(capacities: DockGeometry.compactCapacities(screen: screenMetrics,
                                                                                 manualTopCenter: manualTopCenter))
        let overviewPreferred = DashboardSizing.preferredSize(providerCount: result?.summaries.count ?? 0, cameraHeight: 0)
        let detailPreferred = ProviderDetailView.preferredSize(availableHeight: availableHeight)
        // Reserve one manual opening envelope without coupling presentation sizes.
        let anchorWidth = max(overviewPreferred.width, detailPreferred.width)
        func expandedLayout(preferred: NSSize, detail: Bool) -> DockLayout? {
            func make(_ size: NSSize) -> DockLayout? {
                DockGeometry.layout(screen: screenMetrics, presentation: .expanded,
                                    preferredExpandedSize: size, leftCompactSlots: slots.left,
                                    rightCompactSlots: slots.right,
                                    manualTopCenter: manualTopCenter, preferredAnchorWidth: anchorWidth)
            }
            guard let initial = make(preferred) else { return nil }
            let camera = dashboardCameraRect(in: initial)
            let header = detail
                ? ProviderDetailView.requiredHeaderHeight(for: initial.bodyRect.size, cameraRect: camera)
                : DashboardView.requiredHeaderHeight(for: initial.bodyRect.size, cameraRect: camera)
            let baseline = detail
                ? ProviderDetailView.requiredHeaderHeight(for: initial.bodyRect.size, cameraRect: .zero)
                : DashboardSizing.headerHeight(cameraHeight: 0)
            let extra = max(0, header - baseline)
            return extra > 0 ? make(NSSize(width: preferred.width, height: preferred.height + extra)) : initial
        }
        guard let overviewLayout = expandedLayout(preferred: overviewPreferred, detail: false),
              let detailLayout = expandedLayout(preferred: detailPreferred, detail: true),
              let compact = DockGeometry.layout(screen: screenMetrics, presentation: .compact,
                                                 preferredExpandedSize: overviewPreferred,
                                                 leftCompactSlots: slots.left, rightCompactSlots: slots.right,
                                                 manualTopCenter: manualTopCenter, preferredAnchorWidth: anchorWidth) else {
            cancelFrameAnimation(); panel.orderOut(nil); return
        }
        compactLayout = compact
        dashboardSize = overviewLayout.bodyRect.size
        detailSize = detailLayout.bodyRect.size
        let expansion: CGFloat = interaction.presentation == .expanded ? 1 : 0
        let blend: CGFloat = showingDetail ? 1 : 0
        let layout = expansion == 0 ? compact : (showingDetail ? detailLayout : overviewLayout)
        if frameAnimation != nil, animationTarget == layout,
           animationTargetExpansion == expansion, animationTargetBlend == blend { return }
        let wasAnimating = frameAnimation != nil
        let start = currentLayout
        let initialExpansion = currentExpansion
        let initialBlend = detailBlend
        cancelFrameAnimation()
        if (animated || wasAnimating), panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           let start = start, start.mode == layout.mode,
           DockGeometry.sharesAnchor(start, layout),
           start != layout || initialExpansion != expansion || initialBlend != blend {
            let distance = max(abs(expansion - initialExpansion), abs(blend - initialBlend),
                               abs(layout.frame.height - start.frame.height) / max(1, layout.frame.height),
                               abs(layout.frame.width - start.frame.width) / max(1, layout.frame.width))
            let animation = DockFrameAnimation(duration: max(0.08, 0.24 * min(1, distance))) { [weak self] progress, finished in
                guard let self = self else { return }
                self.applyLayout(DockGeometry.interpolate(from: start, to: layout, progress: progress),
                                 expansion: initialExpansion + (expansion - initialExpansion) * progress,
                                 detailBlend: initialBlend + (blend - initialBlend) * progress)
                if finished {
                    self.frameAnimation = nil; self.animationTarget = nil; self.panel.invalidateShadow()
                    if expansion == 0 { self.updateInteractionMayHaveReleased() }
                }
            }
            animationTarget = layout; animationTargetExpansion = expansion; animationTargetBlend = blend
            frameAnimation = animation
            animation.start()
        } else {
            applyLayout(layout, expansion: expansion, detailBlend: blend)
            panel.invalidateShadow()
            if expansion == 0 { updateInteractionMayHaveReleased() }
        }
        if manualTopCenter != nil {
            manualTopCenter = CGPoint(x: layout.frame.midX, y: layout.frame.maxY)
            UserDefaults.standard.set([Double(layout.frame.midX), Double(layout.frame.maxY)], forKey: positionKey)
        }
    }
    private func cancelFrameAnimation() {
        let animation = frameAnimation
        frameAnimation = nil
        animationTarget = nil
        animation?.stop()
    }
    private func dashboardCameraRect(in layout: DockLayout) -> NSRect {
        guard !layout.cameraRect.isEmpty else { return .zero }
        return NSRect(x: layout.cameraRect.minX - layout.bodyRect.minX,
                      y: layout.bodyRect.maxY - layout.cameraRect.maxY,
                      width: layout.cameraRect.width, height: layout.cameraRect.height)
    }
    private func applyLayout(_ requested: DockLayout, expansion: CGFloat, detailBlend: CGFloat) {
        // AppKit rounds fractional window dimensions. Draw in the realized content
        // bounds, not the smaller requested frame that would expose a top seam.
        panel.setFrame(requested.frame, display: false)
        let realizedFrame = panel.frame
        root.frame = NSRect(origin: .zero, size: panel.contentRect(forFrameRect: realizedFrame).size)
        let contentFrame = NSRect(origin: realizedFrame.origin, size: root.bounds.size)
        let layout = DockGeometry.reconciled(requested, to: contentFrame)
        // Interruption/reversal continues from the smooth requested trajectory;
        // only drawing and hit regions use AppKit's realized dimensions.
        currentLayout = requested; currentExpansion = expansion; self.detailBlend = detailBlend
        realizedLayout = layout
        root.mode = layout.mode; root.bodyRect = layout.bodyRect; root.cameraRect = layout.cameraRect; root.expansion = expansion
        let attached = layout.mode == .notchConnected
        var relayout = compactNeedsLayout
        // Each wing is one row at its own indicator rect inside the same fused root. An empty wing has no row.
        func place(_ container: NSView, items: [NSView], rect: NSRect, side: CompactWingSide) {
            guard !items.isEmpty else { container.frame = .zero; return }
            let rowHeight = min(CompactMetrics.rowHeight, rect.height)
            let rowSize = NSSize(width: CompactMetrics.contentWidth(slots: items.count), height: rowHeight)
            let needsLayout = relayout || container.bounds.size != rowSize
            let rowX = CompactMetrics.rowMinX(in: rect, attached: attached, side: side, slots: items.count)
            container.frame = NSRect(x: rowX, y: rect.midY - rowHeight / 2, width: rowSize.width, height: rowHeight)
            if needsLayout {
                for (index, view) in items.enumerated() {
                    view.frame = NSRect(x: CGFloat(index) * CompactMetrics.slotPitch, y: 0,
                                        width: CompactMetrics.ringDiameter, height: rowHeight)
                }
            }
        }
        place(compactLeftContent, items: compactLeftItems, rect: layout.leftIndicatorRect, side: .left)
        place(compactRightContent, items: compactRightItems, rect: layout.rightIndicatorRect, side: .right)
        relayout = false; compactNeedsLayout = false
        let compactAlpha = max(0, 1 - expansion * 4)
        // Keep the initiating indicator alive until a pressed mouse is released.
        let compactHidden = expansion >= 1 && NSEvent.pressedMouseButtons & 1 == 0
        for (container, items) in [(compactLeftContent, compactLeftItems), (compactRightContent, compactRightItems)] {
            container.alphaValue = compactAlpha
            container.isHidden = compactHidden || items.isEmpty
        }
        dashboard.frame = NSRect(x: layout.bodyRect.midX - dashboardSize.width / 2,
                                 y: layout.bodyRect.maxY - dashboardSize.height,
                                 width: dashboardSize.width, height: dashboardSize.height)
        dashboard.cameraRect = layout.cameraRect.isEmpty ? .zero : dashboard.convert(layout.cameraRect, from: root)
        let contentAlpha = max(0, (expansion - 0.2) / 0.8)
        dashboard.alphaValue = contentAlpha * (1 - detailBlend)
        dashboard.isHidden = expansion <= 0 || detailBlend >= 1
        detail.frame = NSRect(x: layout.bodyRect.midX - detailSize.width / 2,
                              y: layout.bodyRect.maxY - detailSize.height,
                              width: detailSize.width, height: detailSize.height)
        detail.cameraRect = layout.cameraRect.isEmpty ? .zero : detail.convert(layout.cameraRect, from: root)
        detail.alphaValue = contentAlpha * detailBlend
        detail.isHidden = expansion <= 0 || detailBlend <= 0
        let shadow = layout.mode == .floating && expansion > 0.1
        if panel.hasShadow != shadow { panel.hasShadow = shadow }
        root.needsDisplay = true
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        panel.displayIfNeeded()
    }
    private func cancelHover() {
        hoverWork?.cancel(); hoverWork = nil; pendingHover = nil
    }
    // The final compact frame, regardless of the current (possibly still animating) window frame.
    private var compactTarget: CGRect { compactLayout?.frame ?? .zero }
    // The single hover policy shared by tracking areas, pointer monitors, post-hold
    // reconciliation and the delayed entry callback.
    private func pointerWantsHover(_ point: NSPoint) -> Bool {
        DockPointerPolicy.wantsHover(point: point, presentation: interaction.presentation,
                                     panelFrame: panel.frame, compactTarget: compactTarget)
    }
    private func reconcilePointer() { hoverChanged(pointerWantsHover(NSEvent.mouseLocation)) }
    private func hoverChanged(_ inside: Bool) {
        guard pendingHover != inside else { return }
        cancelHover()
        guard interaction.isHovered != inside else { return }
        guard !interaction.isMenuOpen, !interaction.isDragging else { return }
        if inside, hoverGate.requiresExit { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.interaction.isMenuOpen, !self.interaction.isDragging else { return }
            self.hoverWork = nil; self.pendingHover = nil
            if inside {
                // Re-check after the debounce: leaving the compact frame before it fires cancels entry.
                guard !self.hoverGate.requiresExit, self.pointerWantsHover(NSEvent.mouseLocation) else { return }
                if self.interaction.presentation == .compact { self.showingDetail = false }
            }
            // Hover changes geometry only; usage content is rebuilt on data updates.
            self.interaction.setHover(inside); self.positionPanel(animated: true)
        }
        hoverWork = work; pendingHover = inside
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.18 : 0.25), execute: work)
    }
    private func observePointer(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        if event.type == .mouseMoved {
            hoverGate.pointerMoved(insideTarget: DockPointerPolicy.contains(compactTarget, point))
            hoverChanged(pointerWantsHover(point))
        } else if !panel.frame.contains(point) {
            dismiss()
        }
    }
    private func updatePointerAfterHold() {
        cancelHover()
        hoverChanged(pointerWantsHover(NSEvent.mouseLocation))
    }
    private func draggingChanged(_ active: Bool) {
        cancelHover(); interaction.setDragging(active)
        if !active { updatePointerAfterHold() }
        if active { positionPanel() } else { renderHeader(); updateInteractionMayHaveReleased() }
    }
    private func dragTo(_ origin: NSPoint) {
        manualTopCenter = origin
        positionPanel()
    }
    // Where an Option-drag grabs the panel. Collapsed, the manual top-center is chosen so the grabbed wing's
    // controls keep their global position when the two wings become one contiguous floating row (no camera-gap
    // jump); expanded it is the frame's top-center. Evaluated from the realized layout before the drag hold is set.
    private func dragStartAnchor() -> NSPoint? {
        guard currentExpansion == 0, interaction.presentation == .compact, let layout = realizedLayout else { return nil }
        return DockGeometry.compactDragAnchor(layout, grabPoint: NSEvent.mouseLocation,
                                              leftSlots: compactLeftItems.count, rightSlots: compactRightItems.count)
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
        openDetail(scope: .provider(provider))
    }
    private func configureDetail() {
        selectedAccount = detail.configure(result: result, scope: detailScope, selectedAccount: selectedAccount,
                                           config: config, collecting: collecting, transportError: transportError, now: Date())
    }
    private func openDetail(scope: DetailScope) {
        cancelHover()
        if detailScope != scope { selectedAccount = nil }
        detailScope = scope; showingDetail = true
        interaction.setPinned(true)
        configureDetail(); positionPanel(animated: true)
        panel.makeKey(); detail.focusSelection()
    }
    // A background click expands compact/preview boards, but must not leave an explicitly opened detail.
    private func rootPressed() {
        if showingDetail, interaction.presentation == .expanded { return }
        openOverview()
    }
    @objc private func openOverview() {
        cancelHover()
        showingDetail = false; interaction.setPinned(true)
        positionPanel(animated: true)
        panel.makeKey(); dashboard.focusSelection()
    }
    private func dismiss() {
        guard !interaction.isMenuOpen, !interaction.isDragging,
              interaction.presentation == .expanded else { return }
        cancelHover()
        hoverGate.dismiss(pointerInsideTarget: DockPointerPolicy.contains(compactTarget, NSEvent.mouseLocation))
        interaction.dismiss()
        panel.makeFirstResponder(nil)
        if panel.isKeyWindow { panel.resignKey() }
        positionPanel(animated: true)
    }
    private func menu() -> NSMenu {
        cancelHover()
        let menu = NSMenu(title: "Usage options"); menu.delegate = self
        func item(_ title: String, _ action: Selector) { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        item("Refresh", #selector(refreshAction)); item("Settings…", #selector(openGeneralSettings)); item("Check for Updates…", #selector(openUpdates)); item("Open data folder", #selector(openData)); item("Reset position", #selector(resetPosition)); menu.addItem(.separator()); item("Quit", #selector(quit))
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) {
        menuTrackingChanged(true)
    }
    func menuDidClose(_ menu: NSMenu) {
        menuTrackingChanged(false)
    }
    private func menuTrackingChanged(_ active: Bool) {
        cancelHover()
        interaction.setMenuOpen(active)
        if active { positionPanel() }
        else { updatePointerAfterHold(); renderHeader(animated: true); updateInteractionMayHaveReleased() }
    }
    // The configure/+ control opens the one Settings window directly on Display.
    @objc private func openDisplaySettings() {
        // A menu action runs before menu tracking has released its hold; present afterwards.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.generalSettings.edit(config: self.config, updatePolicy: self.updater.policy, result: self.result)
            self.dismiss()
            self.generalSettings.showWindow(nil)
            self.generalSettings.selectDisplayTab()
        }
    }
    @objc private func openGeneralSettings() {
        // Same deferral: menu tracking releases its hold before the panel is dismissed.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.generalSettings.edit(config: self.config, updatePolicy: self.updater.policy, result: self.result)
            self.dismiss()
            self.generalSettings.showWindow(nil)
        }
    }
    @objc private func openUpdates() {
        // A deliberate menu action: wait for menu tracking to release, then show the Updates tab and check.
        DispatchQueue.main.async { [weak self] in self?.presentUpdates(check: true) }
    }
    private func presentUpdates(check: Bool) {
        generalSettings.edit(config: config, updatePolicy: updater.policy, result: result)
        dismiss()
        generalSettings.showWindow(nil)
        generalSettings.selectUpdatesTab()
        if check { updater.checkForUpdates() }
    }
    // Re-evaluates a pending update notice or automatic cutover on the next main-loop turn: windows still report
    // themselves visible while their close notification is being delivered.
    private func updateInteractionMayHaveReleased() {
        guard !updateReevaluationQueued else { return }
        updateReevaluationQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.updateReevaluationQueued = false
            self?.updater.interactionBecameSafe()
        }
    }
    private var anySheetOrModal: Bool {
        NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil }
    }
    // An unsolicited update notice appears only when nothing could be interrupted: no settings window (visible or
    // minimized), sheet, modal, menu, drag, mouse button, or expanded/animating panel.
    private var updateNoticeIsQuiet: Bool {
        return !generalSettings.isInUse && !anySheetOrModal
            && !interaction.isMenuOpen && !interaction.isDragging && interaction.presentation == .compact
            && currentExpansion == 0 && frameAnimation == nil && NSEvent.pressedMouseButtons == 0
    }
    // A deliberate Update Now must not drop edits: any unsaved Settings change (configuration, update choices or
    // compact drafts), a sheet, modal, menu or drag refuses it. A clean open Settings window holds nothing to lose.
    private var updateInstallIsSafe: Bool {
        return !generalSettings.hasUnsavedChanges && !anySheetOrModal && !settingsDropdownOpen
            && !interaction.isMenuOpen && !interaction.isDragging
    }
    // An automatic cutover has no user action behind it, so it needs the full presentation guard as well: any visible
    // or minimized Settings window (even a clean one), sheet, menu, drag, held mouse or expanded panel defers it.
    private func updateCutoverIsSafe(explicit: Bool) -> Bool {
        explicit ? updateInstallIsSafe : (updateInstallIsSafe && updateNoticeIsQuiet)
    }
    @objc private func openData() { NSWorkspace.shared.open(URL(fileURLWithPath: configStore.configPath).deletingLastPathComponent()) }
    @objc private func quit() { NSApp.terminate(nil) }
}
