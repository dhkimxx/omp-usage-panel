import AppKit

private typealias Draft = GeneralSettingsDraft

private final class GeneralFlippedView: NSView { override var isFlipped: Bool { true } }

/// Closure-backed target so row buttons need no tag/identifier bookkeeping.
private final class GeneralActionTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler; super.init() }
    @objc func fire() { handler() }
}

private final class GeneralRowControls {
    let container = NSStackView()
    let key: SettingsSuggestionField
    let value: NSTextField?
    let up: NSButton?
    let down: NSButton?
    let remove: NSButton
    let error: NSTextField
    var targets: [GeneralActionTarget] = []

    init(key: SettingsSuggestionField, value: NSTextField?, up: NSButton?, down: NSButton?, remove: NSButton, error: NSTextField) {
        self.key = key; self.value = value; self.up = up; self.down = down; self.remove = remove; self.error = error
    }
}

private final class CompactRowControls {
    let container = NSStackView()
    let toggle: SettingsToggle
    let side: SettingsSegmentedControl
    var targets: [GeneralActionTarget] = []

    init(toggle: SettingsToggle, side: SettingsSegmentedControl) { self.toggle = toggle; self.side = side }
}

private enum SettingsSection: Int, CaseIterable {
    case collection, display, providers, labels, metrics, runtime, updates

    var title: String {
        switch self {
        case .collection: return "Collection"
        case .display: return "Display"
        case .providers: return "Providers"
        case .labels: return "Labels"
        case .metrics: return "Metrics"
        case .runtime: return "Runtime"
        case .updates: return "Updates"
        }
    }
}

/// The one native Settings window: collector configuration, usage appearance, the compact (notch) view and the
/// app-wide updater choices. Everything edits a transactional `GeneralSettingsDraft` (including one staged
/// compact draft per visited profile scope); nothing reaches disk or the running panel until Save & Apply
/// succeeds through `saveRequested`. Cancel or closing the window discards every draft. Check Now and Update
/// Now are explicit immediate actions, not part of the draft; status refreshes, catalog and compact-baseline
/// refreshes never touch edited values, the selected section or the focus.
final class GeneralSettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// Synchronous commit hook. Must persist and apply the whole commit or throw; a throw keeps the draft open.
    var saveRequested: ((SettingsCommit) throws -> Void)?
    /// Synchronous, read-only compact snapshot of one profile (the edited profile text), used on open and when the
    /// profile text moves to another scope. Never persists anything.
    var compactSnapshotRequested: ((String) -> CompactSettingsSnapshot)?
    /// Immediate manual update actions. They never read or commit the draft.
    var checkRequested: (() -> Void)?
    var installRequested: (() -> Void)?
    /// Called when a window state that blocked an unsolicited update prompt or restart may have ended
    /// (window closed, sheet dismissed). The window is still on screen during the call; defer the re-evaluation.
    var interactionReleased: (() -> Void)?
    /// Tracking hold of the Settings ID suggestion lists: true when one opens, false exactly once when it closes
    /// (selection, Escape, outside click, editing end, window close...). The panel uses it to keep an update cutover
    /// from interrupting an open list.
    var dropdownTrackingChanged: ((Bool) -> Void)?
    /// Read-only provider of the currently connected monitors, read when a draft starts or `edit` is called.
    /// Never persists anything; hotplug later arrives through `updateDisplays(_:)`.
    var displayChoicesRequested: (() -> [PanelDisplayChoice])?
    /// Optional read-only location of the configuration file shown on the Runtime section.
    var configLocation: String? { didSet { locationValue.stringValue = configLocation ?? "Not available" } }

    private struct Binding {
        weak var control: NSTextField?
        let apply: (String) -> Void
    }

    private var draft: Draft?
    private var baseline: PanelConfig?
    private var baselinePolicy = UpdatePolicy.defaults
    private var baselinePlacement = PanelPlacementPreferences.defaults
    private var displayChoices: [PanelDisplayChoice] = []
    private var updateStatusValue: UpdateStatus?
    private var catalog = Draft.Catalog()
    private var isApplyingProgrammaticUpdate = false
    private var pendingSuggestionRefresh = false
    private var shownCompactScope: String?

    private var pages: [SettingsSection: NSScrollView] = [:]
    private var navButtons: [SettingsSection: SettingsNavButton] = [:]
    private let pageContainer = NSView()
    private var fieldControls: [Draft.Field: NSTextField] = [:]
    private var fieldErrors: [Draft.Field: NSTextField] = [:]
    private var listErrors: [Draft.RowList: NSTextField] = [:]
    private var errorFor: [ObjectIdentifier: NSTextField] = [:]
    private var rowStacks: [Draft.RowList: NSStackView] = [:]
    private var rowControls: [Draft.RowList: [Int: GeneralRowControls]] = [:]
    private var addButtons: [Draft.RowList: SettingsButton] = [:]
    private var bindings: [ObjectIdentifier: Binding] = [:]

    private let paceToggle = SettingsToggle(title: "Show elapsed-period pace markers")
    private let monitorButton = SettingsDropdownButton()
    private let monitorHintLabel = NSTextField(wrappingLabelWithString: "")
    private let modeControl = SettingsSegmentedControl(labels: ["Automatic", "Custom"])
    private let modeHint = NSTextField(wrappingLabelWithString: "")
    private let observedLabel = NSTextField(wrappingLabelWithString: "")
    private let versionValue = NSTextField(labelWithString: "")
    private let locationValue = NSTextField(wrappingLabelWithString: "Not available")
    private let bannerLabel = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = SettingsButton(title: "Cancel", style: .secondary)
    private let saveButton = SettingsButton(title: "Save & Apply", style: .primary)

    private let compactProfileLabel = NSTextField(wrappingLabelWithString: "")
    private let compactSummary = NSTextField(wrappingLabelWithString: "")
    private let compactEmptyLabel = NSTextField(wrappingLabelWithString: "No providers reported yet. Selected providers appear here once known.")
    private let compactRowsStack = NSStackView()
    private let compactDecrease = SettingsButton(title: "\u{2212}", style: .secondary, compact: true)
    private let compactIncrease = SettingsButton(title: "+", style: .secondary, compact: true)
    private let compactSelectAll = SettingsButton(title: "Select All", style: .quiet, compact: true)
    private let compactClear = SettingsButton(title: "Clear", style: .quiet, compact: true)
    private var compactRows: [ExactString: CompactRowControls] = [:]
    private var compactRowOrder: [ExactString] = []

    private let updatesVersionValue = NSTextField(labelWithString: "")
    private let automaticChecksToggle = SettingsToggle(title: "Check for updates automatically")
    private let notificationsToggle = SettingsToggle(title: "Show a notice when an update is available")
    private let automaticInstallToggle = SettingsToggle(title: "Download and install updates automatically")
    private let updateStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let updateAvailableLabel = NSTextField(labelWithString: "")
    private let updateCheckedLabel = NSTextField(labelWithString: "")
    private let updateSkippedLabel = NSTextField(wrappingLabelWithString: "")
    private let updateProgress = NSProgressIndicator()
    private let checkNowButton = SettingsButton(title: "Check Now")
    private let updateNowButton = SettingsButton(title: "Update Now")
    private static let lastCheckedFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init() {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 480)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = SettingsPalette.window
        window.titlebarAppearsTransparent = true
        window.setFrameAutosaveName("OMPUsageSettings")
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Public API

    /// Starts a fresh draft from the committed config when the window is closed. While it is open the draft is
    /// kept as is (only observed suggestions refresh). Never presents or activates the window.
    func edit(config: PanelConfig, updatePolicy: UpdatePolicy, placement: PanelPlacementPreferences, result: PanelResult?) {
        catalog = Draft.Catalog(result: result)
        if draft != nil, let window, window.isVisible || window.isMiniaturized {
            refreshSuggestions()
            if let choices = displayChoicesRequested?() { updateDisplays(choices) }
            return
        }
        baseline = config
        baselinePolicy = updatePolicy
        baselinePlacement = placement
        displayChoices = displayChoicesRequested?() ?? displayChoices
        draft = Draft(config: config, updatePolicy: updatePolicy, placement: placement, compactSnapshot: compactSnapshotRequested?(config.profile))
        loadControlsFromDraft()
        refreshSuggestions()
    }

    /// True while unsaved edits (collector configuration, compact preferences of any visited profile, staged
    /// update choices or the panel monitor) exist.
    var hasUnsavedChanges: Bool {
        guard let draft, let baseline else { return false }
        return draft.hasChanges(from: baseline, updatePolicy: baselinePolicy, placement: baselinePlacement)
    }

    /// Visible or minimized: an unsolicited update prompt must stay quiet.
    var isInUse: Bool {
        guard let window else { return false }
        return window.isVisible || window.isMiniaturized || window.attachedSheet != nil
    }

    /// Shows the latest updater status. Changes labels and button states only; never the draft, section or focus.
    func updateStatus(_ status: UpdateStatus) {
        updateStatusValue = status
        renderUpdateStatus()
    }

    /// A committed policy changed outside this window (for example in the update notice). Untouched staged
    /// choices follow it; edited ones are kept, so nothing the user typed is overwritten.
    func committedPolicyChanged(_ policy: UpdatePolicy) {
        let previous = baselinePolicy
        baselinePolicy = policy
        guard draft != nil else { return }
        draft?.rebaseUpdatePolicy(from: previous, to: policy)
        loadUpdatePolicyControls()
    }

    func selectUpdatesTab() { select(.updates) }
    func selectDisplayTab() { select(.display) }

    /// Replaces only the connected-monitor list; the staged selection and dirty state are never touched, and a
    /// selected monitor that is gone stays visible as unavailable.
    func updateDisplays(_ choices: [PanelDisplayChoice]) {
        displayChoices = choices
        renderMonitor()
    }

    /// Changes only the observed ID suggestions; never the draft, the committed config, focus or the save hook.
    func updateCatalog(result: PanelResult?) {
        catalog = Draft.Catalog(result: result)
        refreshSuggestions()
    }

    /// Refreshes one profile's saved compact baseline and provider choices. Only fields the user has NOT edited
    /// adopt it (including the delayed first selection seed); staged edits, focus and section are untouched. A
    /// profile that was never visited in this session is ignored (it is read when first shown).
    func updateCompactSnapshot(_ snapshot: CompactSettingsSnapshot, profile: String) {
        guard let current = draft else { return }
        let scope = Draft.compactScope(for: profile)
        guard current.compactDrafts[scope] != nil || scope == current.compactScope else { return }
        let before = current.compact?.maximumText
        draft?.installCompactSnapshot(snapshot, scope: scope)
        guard scope == draft?.compactScope else { return }
        // A rebased (never edited) maximum replaces the shown text even while the field is focused.
        let rebasedText = draft?.compact?.maximumText
        renderCompact(forceMaximumText: rebasedText != before)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        dismissSuggestionLists()
        draft = nil
        baseline = nil
        shownCompactScope = nil
        pendingSuggestionRefresh = false
        hideAllIssues()
        interactionReleased?()
    }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        let root = SettingsFillView(color: SettingsPalette.window)

        let sidebar = SettingsFillView(color: SettingsPalette.sidebar)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 2
        nav.edgeInsets = NSEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        nav.translatesAutoresizingMaskIntoConstraints = false
        nav.setAccessibilityIdentifier("general.tabs")
        nav.setAccessibilityLabel("Settings sections")
        nav.setAccessibilityRole(.radioGroup)
        pages[.collection] = collectionPage()
        pages[.display] = displayPage()
        pages[.providers] = providersPage()
        pages[.labels] = labelsPage()
        pages[.metrics] = metricsPage()
        pages[.runtime] = runtimePage()
        pages[.updates] = updatesPage()
        for section in SettingsSection.allCases {
            let button = SettingsNavButton(title: section.title)
            button.setAccessibilityIdentifier("general.tab.\(section.title)")
            button.target = self
            button.action = #selector(navClicked(_:))
            button.tag = section.rawValue
            button.onNavigate = { [weak self] delta in self?.navigate(by: delta, from: section) }
            navButtons[section] = button
            nav.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: nav.widthAnchor, constant: -20).isActive = true
        }
        sidebar.addSubview(nav)

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = SettingsPalette.border.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        pageContainer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        for section in SettingsSection.allCases {
            guard let page = pages[section] else { continue }
            page.translatesAutoresizingMaskIntoConstraints = false
            page.setAccessibilityIdentifier("general.page.\(section.title)")
            pageContainer.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: pageContainer.topAnchor),
                page.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
                page.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            ])
        }

        bannerLabel.font = SettingsPalette.font(12)
        bannerLabel.textColor = SettingsPalette.error
        bannerLabel.isHidden = true
        bannerLabel.isSelectable = true
        bannerLabel.setAccessibilityIdentifier("general.error")

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("general.cancel")
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityIdentifier("general.save")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonViews: [NSView] = [spacer, cancelButton, saveButton]
        let buttons = NSStackView(views: buttonViews)
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let footer = NSStackView()
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        fill(bannerLabel, in: footer, inset: 32)
        fill(buttons, in: footer, inset: 32)

        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 0
        main.translatesAutoresizingMaskIntoConstraints = false
        fill(pageContainer, in: main, inset: 0)
        fill(SettingsDividerView(frame: .zero), in: main, inset: 0)
        fill(footer, in: main, inset: 0)

        root.addSubview(sidebar)
        root.addSubview(separator)
        root.addSubview(main)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 168),
            nav.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 10),
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            main.topAnchor.constraint(equalTo: root.topAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            main.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        window.contentView = root
        window.defaultButtonCell = saveButton.cell as? NSButtonCell

        paceToggle.target = self
        paceToggle.action = #selector(paceChanged)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0
        select(.collection)
        updateModeState()
        updateObservedLabel()
        renderUpdateStatus()
        renderCompact()
    }

    private func select(_ section: SettingsSection) {
        DropdownPopupController.shared.dismiss(for: monitorButton)
        for (candidate, page) in pages { page.isHidden = candidate != section }
        for (candidate, button) in navButtons { button.isCurrent = candidate == section }
    }

    @objc private func navClicked(_ sender: NSButton) {
        guard let section = SettingsSection(rawValue: sender.tag) else { return }
        select(section)
    }

    private func navigate(by delta: Int, from section: SettingsSection) {
        let all = SettingsSection.allCases
        guard let index = all.firstIndex(of: section) else { return }
        let next = all[min(max(index + delta, 0), all.count - 1)]
        select(next)
        if let button = navButtons[next] { window?.makeFirstResponder(button) }
    }

    private func section(for field: Draft.Field) -> SettingsSection {
        switch field {
        case .refreshSeconds, .cacheMinutes, .timeoutSeconds: return .collection
        case .warnPercent, .criticalPercent, .compactMaximum: return .display
        case .providers: return .providers
        case .labels: return .labels
        case .metrics: return .metrics
        case .ompPath, .profile: return .runtime
        }
    }

    private func fill(_ view: NSView, in stack: NSStackView, inset: CGFloat) {
        stack.addArrangedSubview(view)
        // Switches keep their natural width so only the switch and its label are clickable.
        if view is SettingsToggle { return }
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset).isActive = true
    }

    private func makePage(_ views: [NSView]) -> NSScrollView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views { fill(view, in: stack, inset: 40) }
        let document = GeneralFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        return scroll
    }

    /// Bordered charcoal group with 12pt inner padding and 10pt gaps.
    private func card(_ views: [NSView], spacing: CGFloat = 10) -> SettingsCardView {
        let card = SettingsCardView(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views { fill(view, in: stack, inset: 24) }
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        return card
    }

    private func group(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        for view in views { fill(view, in: stack, inset: 0) }
        return stack
    }

    private func makeLabel(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = SettingsPalette.text) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = SettingsPalette.font(size, weight)
        label.textColor = color
        return label
    }

    private func heading(_ text: String) -> NSTextField { makeLabel(text, size: 17, weight: .semibold) }
    private func sectionTitle(_ text: String) -> NSTextField { makeLabel(text, size: 13, weight: .semibold) }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = SettingsPalette.font(11)
        label.textColor = SettingsPalette.secondary
        return label
    }

    private func style(secondary label: NSTextField, size: CGFloat = 11) {
        label.font = SettingsPalette.font(size)
        label.textColor = SettingsPalette.secondary
    }

    private func makeErrorLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = SettingsPalette.font(11)
        label.textColor = SettingsPalette.error
        label.isHidden = true
        return label
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = spacing
        row.alignment = alignment
        return row
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return spacer
    }

    private func bind(_ control: NSTextField, apply: @escaping (String) -> Void) {
        bindings[ObjectIdentifier(control)] = Binding(control: control, apply: apply)
    }

    private func makeTextField(field: Draft.Field, identifier: String, accessibility: String, width: CGFloat? = nil,
                               rightAligned: Bool = false, placeholder: String? = nil) -> SettingsTextField {
        let input = SettingsTextField(frame: .zero)
        input.delegate = self
        input.setAccessibilityLabel(accessibility)
        input.setAccessibilityIdentifier(identifier)
        input.placeholderString = placeholder
        if rightAligned { input.alignment = .right }
        if let width { input.widthAnchor.constraint(equalToConstant: width).isActive = true }
        fieldControls[field] = input
        bind(input) { [weak self] text in self?.draft?.setText(text, for: field) }
        return input
    }

    private func numberGroup(_ title: String, field: Draft.Field, identifier: String, unit: String, help: String) -> NSStackView {
        let titleLabel = makeLabel(title)
        titleLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let input = makeTextField(field: field, identifier: identifier, accessibility: title, width: 110, rightAligned: true)
        let unitLabel = makeLabel(unit, color: SettingsPalette.secondary)
        let error = makeErrorLabel()
        fieldErrors[field] = error
        errorFor[ObjectIdentifier(input)] = error
        return group([horizontal([titleLabel, input, unitLabel]), error, hint(help)])
    }

    private func pathGroup(_ title: String, field: Draft.Field, identifier: String, placeholder: String,
                           help: String, choose: Selector) -> NSStackView {
        let titleLabel = makeLabel(title)
        titleLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let input = makeTextField(field: field, identifier: identifier, accessibility: title, placeholder: placeholder)
        input.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let chooseButton = SettingsButton(title: "Choose\u{2026}", compact: true)
        chooseButton.target = self
        chooseButton.action = choose
        chooseButton.setAccessibilityIdentifier(identifier + ".choose")
        chooseButton.setAccessibilityLabel("Choose \(title)")
        chooseButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let error = makeErrorLabel()
        fieldErrors[field] = error
        errorFor[ObjectIdentifier(input)] = error
        return group([horizontal([titleLabel, input, chooseButton]), error, hint(help)])
    }

    // MARK: Pages

    private func collectionPage() -> NSScrollView {
        makePage([
            heading("Collection"),
            card([
                numberGroup("Refresh every", field: .refreshSeconds, identifier: "general.refreshSeconds", unit: "seconds",
                            help: "How often the panel collects usage. Values below 1 second run at 1 second. Fractions are allowed."),
                numberGroup("Reuse results for", field: .cacheMinutes, identifier: "general.cacheMinutes", unit: "minutes",
                            help: "How long a collected result may be reused before omp is asked again. 0 never reuses by age. Fractions are allowed."),
                numberGroup("Collection timeout", field: .timeoutSeconds, identifier: "general.timeoutSeconds", unit: "seconds",
                            help: "The longest one collection may run before it is stopped."),
            ], spacing: 14),
        ])
    }

    private func displayPage() -> NSScrollView {
        paceToggle.setAccessibilityIdentifier("general.showPace")
        paceToggle.setAccessibilityLabel("Show elapsed-period pace markers")
        return makePage([
            heading("Display"),
            card([
                sectionTitle("Usage appearance"),
                numberGroup("Warning at", field: .warnPercent, identifier: "general.warnPercent", unit: "%",
                            help: "Usage at or above this percentage is shown as a warning. 0 or more; values above 100 are allowed."),
                numberGroup("Critical at", field: .criticalPercent, identifier: "general.criticalPercent", unit: "%",
                            help: "Usage at or above this percentage is shown as critical. Must be at least the warning value; values above 100 are allowed."),
                group([paceToggle, hint("Pace markers show how much of each limit's period has elapsed, next to the usage.")]),
            ], spacing: 14),
            panelPlacementSection(),
            compactSection(),
        ])
    }

    /// `Panel placement`: which physical monitor hosts the usage panel (app-wide, not per profile).
    private func panelPlacementSection() -> NSView {
        monitorButton.target = self
        monitorButton.action = #selector(monitorPressed)
        monitorButton.setAccessibilityIdentifier("placement.monitor")
        monitorButton.setAccessibilityLabel("Monitor")
        monitorButton.title = PlacementMonitorOption.systemPrimaryTitle
        style(secondary: monitorHintLabel)
        monitorHintLabel.setAccessibilityIdentifier("placement.monitor.hint")
        let titleLabel = makeLabel("Monitor")
        titleLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        monitorButton.widthAnchor.constraint(equalToConstant: 280).isActive = true
        return card([
            sectionTitle("Panel placement"),
            horizontal([titleLabel, monitorButton, flexibleSpacer()], spacing: 6),
            monitorHintLabel,
            hint("Option-drag overrides placement. Reset position returns to the selected monitor."),
        ], spacing: 10)
    }

    /// `Compact view`: one shared maximum for the whole notch row and a selection plus Left/Right choice per provider.
    private func compactSection() -> NSView {
        style(secondary: compactProfileLabel)
        compactProfileLabel.setAccessibilityIdentifier("compact.profile")
        compactSummary.font = SettingsPalette.font(12)
        compactSummary.textColor = SettingsPalette.text
        compactSummary.setAccessibilityIdentifier("compact.summary")
        style(secondary: compactEmptyLabel)

        let titleLabel = makeLabel("Maximum slots")
        titleLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let input = makeTextField(field: .compactMaximum, identifier: "compact.maximumVisibleSlots", accessibility: "Maximum compact slots", width: 70, rightAligned: true)
        input.toolTip = "Total compact controls across both sides, including the More button."
        let error = makeErrorLabel()
        fieldErrors[.compactMaximum] = error
        errorFor[ObjectIdentifier(input)] = error
        compactDecrease.target = self
        compactDecrease.action = #selector(compactDecreaseClicked)
        compactDecrease.setAccessibilityLabel("Decrease maximum compact slots")
        compactDecrease.setAccessibilityIdentifier("compact.maximum.decrease")
        compactIncrease.target = self
        compactIncrease.action = #selector(compactIncreaseClicked)
        compactIncrease.setAccessibilityLabel("Increase maximum compact slots")
        compactIncrease.setAccessibilityIdentifier("compact.maximum.increase")
        let maximumRow = horizontal([titleLabel, input, compactDecrease, compactIncrease, flexibleSpacer()], spacing: 6)

        compactSelectAll.target = self
        compactSelectAll.action = #selector(compactSelectAllClicked)
        compactSelectAll.setAccessibilityIdentifier("compact.selectAll")
        compactSelectAll.setAccessibilityLabel("Select all compact providers")
        compactClear.target = self
        compactClear.action = #selector(compactClearClicked)
        compactClear.setAccessibilityIdentifier("compact.clear")
        compactClear.setAccessibilityLabel("Clear compact provider selection")
        let header = horizontal([makeLabel("Providers and side", size: 12, weight: .semibold), flexibleSpacer(), compactSelectAll, compactClear], spacing: 4)

        compactRowsStack.orientation = .vertical
        compactRowsStack.alignment = .leading
        compactRowsStack.spacing = 8
        let rowsCard = card([compactRowsStack])
        rowsCard.setAccessibilityIdentifier("compact.providers")

        return card([
            sectionTitle("Compact view"),
            hint("The compact row sits beside the notch. The maximum counts every compact control on both sides, including the More button; each provider chooses its own side."),
            compactProfileLabel,
            maximumRow,
            error,
            compactSummary,
            header,
            rowsCard,
            hint("These settings only affect the compact row; the expanded dashboard still shows everything. Existing app or status menus are not detected, so reduce the count or move providers to the other side if they overlap. Without a notch the compact row is one capsule: Left providers first, then Right."),
        ], spacing: 10)
    }

    private func providersPage() -> NSScrollView {
        style(secondary: modeHint)
        modeControl.setAccessibilityLabel("Provider list mode")
        modeControl.setAccessibilityIdentifier("general.providers.mode")
        var views: [NSView] = [modeControl, modeHint]
        views += listSection(.providers, addTitle: "Add provider ID", addIdentifier: "general.providers.add", add: #selector(addProviderRow))
        views.append(hint("Providers only choose and order the summary list. Collection still reads every account, and All in the provider filter still shows them. IDs are matched exactly; unreported IDs are allowed. Credentials stay managed by omp."))
        return makePage([heading("Summary providers"), card(views, spacing: 10)])
    }

    private func labelsPage() -> NSScrollView {
        var views: [NSView] = []
        views += listSection(.labels, addTitle: "Add label", addIdentifier: "general.labels.add", add: #selector(addLabelRow))
        views.append(hint("Each row renames one provider ID in summaries. Rows are independent of the provider list, so entries for unreported or unselected providers are kept."))
        return makePage([heading("Display labels"), card(views, spacing: 10)])
    }

    private func metricsPage() -> NSScrollView {
        style(secondary: observedLabel)
        observedLabel.isSelectable = true
        observedLabel.setAccessibilityIdentifier("general.metrics.observed")
        var views: [NSView] = []
        views += listSection(.metrics, addTitle: "Add metric override", addIdentifier: "general.metrics.add", add: #selector(addMetricRow))
        views.append(hint("The limit ID must match a limit ID exactly (not its window or label); a missing ID shows an unknown metric. Remove a row to return that provider to automatic selection."))
        views.append(observedLabel)
        return makePage([heading("Representative metrics"), card(views, spacing: 10)])
    }

    private func runtimePage() -> NSScrollView {
        style(secondary: versionValue)
        versionValue.setAccessibilityIdentifier("general.version")
        locationValue.isSelectable = true
        style(secondary: locationValue)
        locationValue.setAccessibilityIdentifier("general.location")
        let profileTitle = makeLabel("Profile")
        profileTitle.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let profileInput = makeTextField(field: .profile, identifier: "general.profile", accessibility: "Profile", placeholder: "default")
        profileInput.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let profileError = makeErrorLabel()
        fieldErrors[.profile] = profileError
        errorFor[ObjectIdentifier(profileInput)] = profileError
        return makePage([
            heading("Runtime"),
            card([
                pathGroup("omp executable", field: .ompPath, identifier: "general.ompPath", placeholder: "/path/to/omp",
                          help: "Absolute path of the omp executable the collector calls.", choose: #selector(chooseOmp)),
                group([horizontal([profileTitle, profileInput]), profileError,
                       hint("Selects an existing omp profile. Sign-in and credentials stay managed by omp; this panel never reads or edits them. Compact view settings are kept per profile.")]),
            ], spacing: 14),
            card([makeLabel("Configuration file", size: 12, weight: .semibold), locationValue, versionValue], spacing: 6),
        ])
    }

    private func updatesPage() -> NSScrollView {
        let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (installed, build) {
        case let (version?, build?) where build != version: updatesVersionValue.stringValue = "Installed version \(version) (build \(build))"
        case let (version?, _): updatesVersionValue.stringValue = "Installed version \(version)"
        default: updatesVersionValue.stringValue = "Installed version unknown"
        }
        updatesVersionValue.font = SettingsPalette.font(12)
        updatesVersionValue.textColor = SettingsPalette.text
        updatesVersionValue.isSelectable = true
        updatesVersionValue.setAccessibilityIdentifier("general.updates.version")

        automaticChecksToggle.target = self
        automaticChecksToggle.action = #selector(automaticChecksChanged)
        automaticChecksToggle.setAccessibilityIdentifier("general.updates.automaticChecks")
        automaticChecksToggle.setAccessibilityLabel("Check for updates automatically")
        notificationsToggle.target = self
        notificationsToggle.action = #selector(notificationsChanged)
        notificationsToggle.setAccessibilityIdentifier("general.updates.notifications")
        notificationsToggle.setAccessibilityLabel("Show a notice when an update is available")
        automaticInstallToggle.target = self
        automaticInstallToggle.action = #selector(automaticInstallChanged)
        automaticInstallToggle.setAccessibilityIdentifier("general.updates.automaticInstall")
        automaticInstallToggle.setAccessibilityLabel("Download and install updates automatically")

        updateStatusLabel.font = SettingsPalette.font(12)
        updateStatusLabel.isSelectable = true
        updateStatusLabel.setAccessibilityIdentifier("general.updates.status")
        updateAvailableLabel.font = SettingsPalette.font(12)
        updateAvailableLabel.textColor = SettingsPalette.text
        updateAvailableLabel.setAccessibilityIdentifier("general.updates.available")
        style(secondary: updateCheckedLabel)
        updateCheckedLabel.setAccessibilityIdentifier("general.updates.lastChecked")
        style(secondary: updateSkippedLabel)
        updateSkippedLabel.setAccessibilityIdentifier("general.updates.skipped")

        updateProgress.style = .spinning
        updateProgress.controlSize = .small
        updateProgress.isIndeterminate = true
        updateProgress.isDisplayedWhenStopped = false
        updateProgress.setAccessibilityIdentifier("general.updates.progress")
        updateProgress.setAccessibilityLabel("Update in progress")
        checkNowButton.target = self
        checkNowButton.action = #selector(checkNowClicked)
        checkNowButton.setAccessibilityIdentifier("general.updates.check")
        updateNowButton.target = self
        updateNowButton.action = #selector(updateNowClicked)
        updateNowButton.setAccessibilityIdentifier("general.updates.install")
        let actions = horizontal([checkNowButton, updateNowButton, updateProgress, flexibleSpacer()])

        return makePage([
            heading("Updates"),
            card([
                updatesVersionValue,
                group([automaticChecksToggle, hint("Looks for a new version about once a day. Manual checks always work, even when this is off.")]),
                group([notificationsToggle, hint("Shows a small notice that never takes keyboard focus. Turning this off never changes how updates are installed.")]),
                group([automaticInstallToggle, hint("Off by default. When on, updates found by automatic checks are downloaded and installed, then the panel restarts once nothing is being edited. Requires automatic checks.")]),
                hint("These three choices apply when you press Save & Apply."),
            ], spacing: 12),
            card([
                sectionTitle("Status"),
                updateStatusLabel,
                updateAvailableLabel,
                updateCheckedLabel,
                updateSkippedLabel,
                actions,
                hint("Check Now and Update Now act immediately and are not part of Save & Apply. Update Now installs only this update and restarts the panel. Checking contacts the update feed; no usage, account or configuration data is sent."),
            ], spacing: 8),
        ])
    }

    /// Rows container, list-level error and the Add button for one list.
    private func listSection(_ list: Draft.RowList, addTitle: String, addIdentifier: String, add: Selector) -> [NSView] {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rowStacks[list] = rows
        let error = makeErrorLabel()
        listErrors[list] = error
        let button = SettingsButton(title: addTitle, compact: true)
        button.target = self
        button.action = add
        button.setAccessibilityIdentifier(addIdentifier)
        addButtons[list] = button
        return [rows, error, horizontal([button, flexibleSpacer()])]
    }

    // MARK: Rows

    private func listName(_ list: Draft.RowList) -> String {
        switch list {
        case .providers: return "providers"
        case .labels: return "labels"
        case .metrics: return "metrics"
        }
    }

    /// One suggestion field with its sibling chevron; put the returned control (not `.field`) into layouts.
    private func makeSuggestionControl(identifier: String, accessibility: String, text: String, placeholder: String, fixedWidth: CGFloat?) -> SettingsSuggestionControl {
        let control = SettingsSuggestionControl(fixedWidth: fixedWidth)
        let field = control.field
        field.delegate = self
        field.stringValue = text
        field.placeholderString = placeholder
        field.configureAccessibility(identifier: identifier, label: accessibility)
        field.trackingChanged = { [weak self] held in self?.dropdownTrackingChanged?(held) }
        return control
    }

    private func makeSmallButton(_ title: String, identifier: String, accessibility: String, handler: @escaping () -> Void) -> (SettingsButton, GeneralActionTarget) {
        let target = GeneralActionTarget(handler)
        let button = SettingsButton(title: title, compact: true)
        button.target = target
        button.action = #selector(GeneralActionTarget.fire)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(accessibility)
        return (button, target)
    }

    private func makeRowControls(_ list: Draft.RowList, row: Draft.Row) -> GeneralRowControls {
        let id = row.id
        let prefix = "general.\(listName(list)).row.\(id)"
        let keyControl = makeSuggestionControl(identifier: prefix + ".providerID", accessibility: "Provider ID", text: row.key,
                                               placeholder: "provider-id", fixedWidth: list == .providers ? nil : 200)
        let keyBox = keyControl.field
        bind(keyBox) { [weak self] text in
            self?.draft?.setRow(list, id: id, key: text)
            if list == .metrics { self?.refreshLimitSuggestions(rowID: id) }
        }

        var value: NSTextField?
        var valueView: NSView?
        switch list {
        case .providers: break
        case .labels:
            let field = SettingsTextField(frame: .zero)
            field.delegate = self
            field.stringValue = row.value
            field.placeholderString = "Display label"
            field.setAccessibilityLabel("Display label")
            field.setAccessibilityIdentifier(prefix + ".label")
            field.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            bind(field) { [weak self] text in self?.draft?.setRow(list, id: id, value: text) }
            value = field
            valueView = field
        case .metrics:
            let control = makeSuggestionControl(identifier: prefix + ".limitID", accessibility: "Limit ID", text: row.value,
                                                placeholder: "limit-id", fixedWidth: nil)
            let box = control.field
            bind(box) { [weak self] text in self?.draft?.setRow(list, id: id, value: text) }
            value = box
            valueView = control
        }

        var targets: [GeneralActionTarget] = []
        var up: NSButton?
        var down: NSButton?
        if list == .providers {
            let (upButton, upTarget) = makeSmallButton("\u{2191}", identifier: prefix + ".up", accessibility: "Move provider up") { [weak self] in
                self?.moveRow(list, id: id, by: -1)
            }
            let (downButton, downTarget) = makeSmallButton("\u{2193}", identifier: prefix + ".down", accessibility: "Move provider down") { [weak self] in
                self?.moveRow(list, id: id, by: 1)
            }
            up = upButton; down = downButton; targets += [upTarget, downTarget]
        }
        let (remove, removeTarget) = makeSmallButton("Remove", identifier: prefix + ".remove", accessibility: "Remove row") { [weak self] in
            self?.removeRow(list, id: id)
        }
        targets.append(removeTarget)

        let error = makeErrorLabel()
        errorFor[ObjectIdentifier(keyBox)] = error
        if let value { errorFor[ObjectIdentifier(value)] = error }
        let controls = GeneralRowControls(key: keyBox, value: value, up: up, down: down, remove: remove, error: error)
        controls.targets = targets

        var lineViews: [NSView] = [keyControl]
        if let valueView { lineViews.append(valueView) }
        if let up { lineViews.append(up) }
        if let down { lineViews.append(down) }
        lineViews.append(remove)
        let line = horizontal(lineViews, spacing: 6)
        let container = controls.container
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 2
        fill(line, in: container, inset: 0)
        fill(error, in: container, inset: 0)
        return controls
    }

    private func unbind(_ controls: GeneralRowControls) {
        let controlList: [NSTextField?] = [controls.key, controls.value]
        for control in controlList.compactMap({ $0 }) {
            bindings[ObjectIdentifier(control)] = nil
            errorFor[ObjectIdentifier(control)] = nil
        }
    }

    private func clearRows(_ list: Draft.RowList) {
        for controls in (rowControls[list] ?? [:]).values {
            unbind(controls)
            controls.container.removeFromSuperview()
        }
        rowControls[list] = [:]
    }

    /// Reconciles cached row views with the draft: stable controls per row ID, created/removed/reordered only.
    private func syncRows(_ list: Draft.RowList) {
        guard let draft, let stack = rowStacks[list] else { return }
        let rows = draft.rows(list)
        let wanted = Set(rows.map(\.id))
        var byID = rowControls[list] ?? [:]
        for (id, controls) in byID where !wanted.contains(id) {
            unbind(controls)
            controls.container.removeFromSuperview()
            byID[id] = nil
        }
        for row in rows where byID[row.id] == nil { byID[row.id] = makeRowControls(list, row: row) }
        rowControls[list] = byID
        let ordered: [NSView] = rows.compactMap { byID[$0.id]?.container }
        if stack.arrangedSubviews != ordered {
            for view in stack.arrangedSubviews {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for view in ordered { fill(view, in: stack, inset: 0) }
        }
        if list == .providers { updateModeState() }
        refreshSuggestions()
    }

    private func addRow(_ list: Draft.RowList) {
        guard draft != nil else { return }
        let id = draft?.addRow(list)
        syncRows(list)
        if let id, let key = rowControls[list]?[id]?.key { window?.makeFirstResponder(key) }
    }

    private func removeRow(_ list: Draft.RowList, id: Int) {
        guard draft != nil else { return }
        draft?.removeRow(list, id: id)
        syncRows(list)
    }

    private func moveRow(_ list: Draft.RowList, id: Int, by offset: Int) {
        guard draft != nil else { return }
        draft?.moveRow(list, id: id, by: offset)
        syncRows(list)
    }

    @objc private func addProviderRow() { addRow(.providers) }
    @objc private func addLabelRow() { addRow(.labels) }
    @objc private func addMetricRow() { addRow(.metrics) }

    @objc private func automaticChecksChanged() {
        draft?.updatePolicy.automaticChecks = automaticChecksToggle.state == .on
        updateAutomaticInstallEnablement()
    }
    @objc private func notificationsChanged() { draft?.updatePolicy.notificationsEnabled = notificationsToggle.state == .on }
    @objc private func automaticInstallChanged() { draft?.updatePolicy.automaticInstallation = automaticInstallToggle.state == .on }

    // MARK: Compact view

    private func compactTitle(_ choice: CompactProviderChoice) -> String {
        var title = choice.label
        if let detail = choice.detail, !detail.isEmpty { title += " \u{2014} \(detail)" }
        if !choice.isReported { title += " (not reported)" }
        return title
    }

    private func makeCompactRow(_ choice: CompactProviderChoice) -> CompactRowControls {
        let id = choice.id
        let toggle = SettingsToggle(title: compactTitle(choice))
        toggle.setAccessibilityIdentifier("compact.provider.\(id)")
        toggle.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
        let side = SettingsSegmentedControl(labels: ["Left", "Right"])
        side.setAccessibilityIdentifier("compact.side.\(id)")
        side.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        side.setContentCompressionResistancePriority(.required, for: .horizontal)
        let controls = CompactRowControls(toggle: toggle, side: side)
        let toggleTarget = GeneralActionTarget { [weak self, weak toggle] in
            guard let toggle else { return }
            self?.draft?.editCompact { $0.setSelected(toggle.state == .on, id: id) }
            self?.renderCompactSummary()
        }
        let sideTarget = GeneralActionTarget { [weak self, weak side] in
            guard let side, side.selectedSegment >= 0 else { return }
            self?.draft?.editCompact { $0.setSide(side.selectedSegment == 0 ? .left : .right, for: id) }
        }
        controls.targets = [toggleTarget, sideTarget]
        toggle.target = toggleTarget
        toggle.action = #selector(GeneralActionTarget.fire)
        side.target = sideTarget
        side.action = #selector(GeneralActionTarget.fire)
        let row = controls.container
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.addArrangedSubview(toggle)
        row.addArrangedSubview(flexibleSpacer())
        row.addArrangedSubview(side)
        return controls
    }

    private func updateCompactRow(_ controls: CompactRowControls, choice: CompactProviderChoice, compact: CompactSettingsDraft) {
        let title = compactTitle(choice)
        if controls.toggle.title != title { controls.toggle.title = title }
        controls.toggle.setAccessibilityLabel(title)
        controls.toggle.toolTip = choice.id
        let selected = compact.isSelected(choice.id)
        if (controls.toggle.state == .on) != selected { controls.toggle.state = selected ? .on : .off }
        let index = compact.side(for: choice.id) == .left ? 0 : 1
        if controls.side.selectedSegment != index { controls.side.selectedSegment = index }
        controls.side.setAccessibilityLabel("Compact side for \(title)")
        controls.side.toolTip = "Side of the camera for \(choice.label)"
    }

    private func renderCompactSummary() {
        guard let compact = draft?.compact else { compactSummary.stringValue = ""; return }
        compactSummary.stringValue = compact.summary
        refreshCompactMaximumError()
    }

    private func refreshCompactMaximumError() {
        let invalid = draft?.compact.map { $0.parsedMaximum == nil } ?? false
        guard let label = fieldErrors[.compactMaximum] else { return }
        label.stringValue = invalid ? CompactSettingsDraft.invalidMaximumMessage : ""
        label.isHidden = !invalid
        (fieldControls[.compactMaximum] as? SettingsTextField)?.showsError = invalid
    }

    /// Syncs the compact section to the current scope's draft. The maximum field is left alone while it is being
    /// edited (unless an unedited baseline replaced its text); rows are reused per exact provider ID.
    private func renderCompact(forceMaximumText: Bool = false) {
        let compact = draft?.compact
        let available = compact != nil
        let scope = draft?.compactScope ?? "default"
        compactProfileLabel.stringValue = available
            ? "Editing the compact view of profile \u{201C}\(scope)\u{201D}. Changes apply when you press Save & Apply."
            : "Compact settings are not available for this profile yet."
        for button in [compactDecrease, compactIncrease, compactSelectAll, compactClear] where button.isEnabled != available { button.isEnabled = available }
        if let field = fieldControls[.compactMaximum] {
            if field.isEnabled != available { field.isEnabled = available }
            let text = compact?.maximumText ?? ""
            if field.currentEditor() == nil || forceMaximumText, field.stringValue != text {
                let wasApplying = isApplyingProgrammaticUpdate
                isApplyingProgrammaticUpdate = true
                if let editor = field.currentEditor() { editor.string = text } else { field.stringValue = text }
                isApplyingProgrammaticUpdate = wasApplying
            }
        }
        renderCompactSummary()

        let choices = compact?.choices ?? []
        let wanted = Set(choices.map { $0.id.exactKey })
        for key in compactRows.keys where !wanted.contains(key) {
            compactRows[key]?.container.removeFromSuperview()
            compactRows[key] = nil
        }
        for choice in choices {
            let key = choice.id.exactKey
            let controls = compactRows[key] ?? makeCompactRow(choice)
            compactRows[key] = controls
            if let compact { updateCompactRow(controls, choice: choice, compact: compact) }
        }
        let order = choices.map { $0.id.exactKey }
        if order != compactRowOrder || (choices.isEmpty && compactRowsStack.arrangedSubviews != [compactEmptyLabel]) {
            compactRowOrder = order
            for view in compactRowsStack.arrangedSubviews {
                compactRowsStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            if choices.isEmpty { fill(compactEmptyLabel, in: compactRowsStack, inset: 0) }
            for key in order { if let row = compactRows[key]?.container { fill(row, in: compactRowsStack, inset: 0) } }
        }
    }

    /// The profile text moved to another scope: read that scope's saved preferences (read-only) and show its draft.
    private func profileTextChanged() {
        guard let current = draft else { return }
        let scope = current.compactScope
        guard scope != shownCompactScope else { return }
        shownCompactScope = scope
        if let snapshot = compactSnapshotRequested?(current.profile) { draft?.installCompactSnapshot(snapshot, scope: scope) }
        renderCompact()
    }

    private func applyCompactMaximum(delta: Int) {
        guard draft?.compact != nil else { return }
        window?.makeFirstResponder(nil)
        draft?.editCompact { $0.adjustMaximum(by: delta) }
        renderCompact(forceMaximumText: true)
    }

    @objc private func compactDecreaseClicked() { applyCompactMaximum(delta: -1) }
    @objc private func compactIncreaseClicked() { applyCompactMaximum(delta: 1) }

    @objc private func compactSelectAllClicked() {
        draft?.editCompact { $0.selectAll() }
        renderCompact()
    }

    @objc private func compactClearClicked() {
        draft?.editCompact { $0.clearSelection() }
        renderCompact()
    }

    // MARK: Updates

    private func loadUpdatePolicyControls() {
        guard let policy = draft?.updatePolicy else { return }
        automaticChecksToggle.state = policy.automaticChecks ? .on : .off
        notificationsToggle.state = policy.notificationsEnabled ? .on : .off
        automaticInstallToggle.state = policy.automaticInstallation ? .on : .off
        updateAutomaticInstallEnablement()
    }

    private func updateAutomaticInstallEnablement() {
        let enabled = automaticChecksToggle.state == .on
        if automaticInstallToggle.isEnabled != enabled { automaticInstallToggle.isEnabled = enabled }
    }

    private func setEnabled(_ button: NSButton, _ enabled: Bool) {
        if button.isEnabled != enabled { button.isEnabled = enabled }
    }

    private func renderUpdateStatus() {
        guard let status = updateStatusValue else {
            updateStatusLabel.stringValue = "Update status is not available yet."
            updateStatusLabel.textColor = SettingsPalette.secondary
            updateAvailableLabel.isHidden = true
            updateCheckedLabel.stringValue = "Not checked yet."
            updateSkippedLabel.isHidden = true
            updateProgress.stopAnimation(nil)
            setEnabled(checkNowButton, false)
            setEnabled(updateNowButton, false)
            return
        }
        updateStatusLabel.stringValue = status.message
        updateStatusLabel.textColor = status.phase == .failed ? SettingsPalette.error : (status.installBlocked ? SettingsPalette.warning : SettingsPalette.text)
        if let version = status.availableVersion {
            updateAvailableLabel.stringValue = "Available version: \(version)"
            updateAvailableLabel.isHidden = false
        } else {
            updateAvailableLabel.stringValue = ""
            updateAvailableLabel.isHidden = true
        }
        updateCheckedLabel.stringValue = status.lastCheckedAt.map { "Last checked: " + Self.lastCheckedFormat.string(from: $0) } ?? "Not checked yet."
        if let skipped = status.lastSkippedVersion {
            updateSkippedLabel.stringValue = "You skipped version \(skipped). Automatic notices and installs skip it; Check Now still offers it."
            updateSkippedLabel.isHidden = false
        } else {
            updateSkippedLabel.stringValue = ""
            updateSkippedLabel.isHidden = true
        }
        if status.phase.isBusy { updateProgress.startAnimation(nil) } else { updateProgress.stopAnimation(nil) }
        setEnabled(checkNowButton, !status.phase.isBusy)
        setEnabled(updateNowButton, status.canInstall && !status.phase.isBusy)
    }

    // MARK: Rendering

    private func loadControlsFromDraft() {
        guard let draft else { return }
        isApplyingProgrammaticUpdate = true
        defer { isApplyingProgrammaticUpdate = false }
        for (field, control) in fieldControls { control.stringValue = draft.text(for: field) }
        paceToggle.state = draft.showPace ? .on : .off
        loadUpdatePolicyControls()
        modeControl.selectedSegment = draft.providerMode == .custom ? 1 : 0
        versionValue.stringValue = "Schema version \(draft.version) (read-only)"
        hideAllIssues()
        for list in Draft.RowList.allCases {
            clearRows(list)
            syncRows(list)
        }
        updateModeState()
        shownCompactScope = draft.compactScope
        renderMonitor()
        renderCompact(forceMaximumText: true)
    }

    private func updateModeState() {
        let custom = draft?.providerMode == .custom
        modeHint.stringValue = draft == nil || !custom
            ? "Automatic: every provider omp reports is shown, in the default order. Switch to Custom to choose and order providers; your rows are kept."
            : "Custom: only these IDs are shown, in this order. IDs without data are still listed, and an empty list shows no summary providers."
        addButtons[.providers]?.isEnabled = custom
        let rows = draft?.rows(.providers) ?? []
        for (index, row) in rows.enumerated() {
            guard let controls = rowControls[.providers]?[row.id] else { continue }
            controls.key.isEnabled = custom
            controls.remove.isEnabled = custom
            controls.up?.isEnabled = custom && index > 0
            controls.down?.isEnabled = custom && index < rows.count - 1
        }
    }

    private func updateObservedLabel() {
        var lines: [String] = []
        for provider in catalog.providers {
            let limits = catalog.limits(for: provider)
            guard !limits.isEmpty else { continue }
            let described = limits.map { $0.id.isExactlyEqual(to: $0.label) ? $0.id : "\($0.id) (\($0.label))" }
            lines.append("\(provider): " + described.joined(separator: ", "))
        }
        observedLabel.stringValue = lines.isEmpty
            ? "No limit IDs have been observed yet. Type the exact limit ID."
            : "Observed limit IDs\n" + lines.joined(separator: "\n")
    }

    /// Every suggestion field of every list (provider/label keys and metric limit IDs).
    private var suggestionFields: [SettingsSuggestionField] {
        var fields: [SettingsSuggestionField] = []
        for rows in rowControls.values {
            for controls in rows.values {
                fields.append(controls.key)
                if let limit = controls.value as? SettingsSuggestionField { fields.append(limit) }
            }
        }
        return fields
    }

    private func dismissSuggestionLists() {
        DropdownPopupController.shared.dismiss(for: monitorButton)
        for field in suggestionFields { field.dismissSuggestions() }
    }

    /// Offers new values without touching any text. A field being edited is skipped (its open list keeps what it
    /// shows) and refreshed after editing ends.
    private func setItems(_ field: SettingsSuggestionField, _ items: [String]) {
        if field.suggestionsMatch(items) { return }
        if field.isEditingText {
            pendingSuggestionRefresh = true
            return
        }
        field.setSuggestions(items)
    }

    /// Reuses existing suggestion fields; an actively edited field is skipped and refreshed after editing ends.
    private func refreshSuggestions() {
        updateObservedLabel()
        guard let baseline else { return }
        let providers = catalog.providerSuggestions(config: baseline)
        for list in Draft.RowList.allCases {
            for controls in (rowControls[list] ?? [:]).values { setItems(controls.key, providers) }
        }
        for id in (rowControls[.metrics] ?? [:]).keys { refreshLimitSuggestions(rowID: id) }
    }

    private func refreshLimitSuggestions(rowID: Int) {
        guard let baseline, let draft,
              let field = rowControls[.metrics]?[rowID]?.value as? SettingsSuggestionField,
              let row = draft.rows(.metrics).first(where: { $0.id == rowID }) else { return }
        setItems(field, catalog.limitSuggestions(provider: row.key, config: baseline))
    }

    // MARK: Errors

    private func hideAllIssues() {
        var labels: [NSTextField] = Array(fieldErrors.values) + Array(listErrors.values)
        for rows in rowControls.values { labels += rows.values.map(\.error) }
        for label in labels {
            label.stringValue = ""
            label.isHidden = true
        }
        for control in fieldControls.values { (control as? SettingsTextField)?.showsError = false }
        bannerLabel.stringValue = ""
        bannerLabel.isHidden = true
    }

    private func showBanner(_ message: String) {
        bannerLabel.stringValue = message
        bannerLabel.isHidden = false
    }

    private func showIssues(_ issues: [Draft.Issue]) {
        hideAllIssues()
        var scoped: [String] = []
        for issue in issues {
            if issue.scope != nil { scoped.append(issue.message); continue }
            let label: NSTextField?
            if let list = issue.field.rowList {
                label = issue.rowID.flatMap { rowControls[list]?[$0]?.error } ?? listErrors[list]
            } else {
                label = fieldErrors[issue.field]
                (fieldControls[issue.field] as? SettingsTextField)?.showsError = true
            }
            guard let label else { continue }
            label.stringValue = label.isHidden ? issue.message : label.stringValue + "\n" + issue.message
            label.isHidden = false
        }
        if let first = issues.first(where: { $0.scope == nil }) ?? issues.first { select(section(for: first.field)) }
        var message = "\(issues.count) problem\(issues.count == 1 ? "" : "s") must be fixed before saving. Nothing was changed."
        if !scoped.isEmpty { message += "\n" + scoped.joined(separator: "\n") }
        showBanner(message)
    }

    private func hideError(for control: NSTextField) {
        (control as? SettingsTextField)?.showsError = false
        guard let label = errorFor[ObjectIdentifier(control)] else { return }
        label.stringValue = ""
        label.isHidden = true
    }

    // MARK: Text editing

    func controlTextDidChange(_ obj: Notification) {
        guard !isApplyingProgrammaticUpdate, let field = obj.object as? NSTextField,
              let binding = bindings[ObjectIdentifier(field)] else { return }
        let editor = obj.userInfo?["NSFieldEditor"] as? NSText
        binding.apply(editor?.string ?? field.stringValue)
        hideError(for: field)
        if field === fieldControls[.compactMaximum] { renderCompactSummary() }
        else if field === fieldControls[.profile] { profileTextChanged() }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard pendingSuggestionRefresh else { return }
        pendingSuggestionRefresh = false
        DispatchQueue.main.async { [weak self] in self?.refreshSuggestions() }
    }

    /// Editor commands of the ID fields: Down opens the suggestion list; while it is open Up/Down/Return/Escape
    /// drive it. Any other command, and every command while an input method is composing, stays with the editor.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        (control as? SettingsSuggestionField)?.handleEditorCommand(commandSelector) ?? false
    }

    /// Save/Cancel are default/cancel-button key equivalents, which the window may offer Return/Escape to before the
    /// active field editor sees them. A keyboard-initiated Save/Cancel therefore first checks who owns the key:
    ///  - an open suggestion list takes it when it can act (navigation, highlighted row, Escape);
    ///  - otherwise, with a list open or an input method composing (marked text), the active native editor receives
    ///    the actual key event exactly once through its own `keyDown`, so composition is confirmed/cancelled by the
    ///    input method and Return/Escape can never save or discard the whole dialog;
    ///  - with neither, the button proceeds. A mouse click never routes here.
    /// Returns true when the key was consumed.
    private func routeKeyAwayFromButtons(_ command: DropdownNavigation) -> Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown, let window,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        let field = suggestionFields.first(where: \.isPresentingSuggestions)
        if let field {
            guard field.currentEditor() === editor else { return false }
            if field.navigateSuggestions(command) { return true }
        } else if !editor.hasMarkedText() {
            return false
        }
        editor.keyDown(with: event)
        return true
    }

    // MARK: Actions

    @objc private func paceChanged() { draft?.showPace = paceToggle.state == .on }

    @objc private func monitorPressed() {
        let controller = DropdownPopupController.shared
        if controller.isPresented(for: monitorButton) {
            controller.dismiss(for: monitorButton)
            return
        }
        guard draft != nil, monitorButton.window != nil, !monitorButton.isHiddenOrHasHiddenAncestor else { return }
        presentMonitorChoices()
    }

    private func presentMonitorChoices() {
        guard let draft else { return }
        let items = draft.monitorOptions(choices: displayChoices).map { option -> DropdownItem in
            DropdownItem(id: option.id, title: option.title, subtitle: option.subtitle, isSelected: option.isSelected,
                         isEnabled: option.isAvailable) { [weak self] in
                self?.draft?.selectMonitor(uuid: option.displayUUID)
                self?.renderMonitor()
            }
        }
        DropdownPopupController.shared.show(anchor: monitorButton, items: items,
                                            trackingChanged: { [weak self] held in
                                                self?.monitorButton.needsDisplay = true
                                                self?.dropdownTrackingChanged?(held)
                                            })
    }

    /// Re-renders the Monitor control from the staged placement and the latest connected-monitor catalog.
    private func renderMonitor() {
        guard let draft else { return }
        monitorButton.title = draft.monitorButtonTitle(choices: displayChoices)
        monitorButton.setAccessibilityValue(monitorButton.title)
        monitorButton.toolTip = monitorButton.title
        monitorHintLabel.stringValue = draft.monitorHint(choices: displayChoices)
        if DropdownPopupController.shared.isPresented(for: monitorButton) { presentMonitorChoices() }
    }

    @objc private func modeChanged() {
        draft?.providerMode = modeControl.selectedSegment == 1 ? .custom : .automatic
        updateModeState()
    }

    @objc private func chooseOmp() { chooseFile(for: .ompPath, message: "Choose the omp executable") }

    private func chooseFile(for field: Draft.Field, message: String) {
        guard draft != nil, let window, let control = fieldControls[field] else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = message
        panel.prompt = "Choose"
        let current = control.stringValue
        if current.hasPrefix("/") { panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent() }
        panel.beginSheetModal(for: window) { [weak self, weak control] response in
            DispatchQueue.main.async { self?.interactionReleased?() }
            guard response == .OK, let url = panel.url, let self, let control else { return }
            control.stringValue = url.path
            self.draft?.setText(url.path, for: field)
            self.hideError(for: control)
        }
    }

    @objc private func cancelClicked() {
        if routeKeyAwayFromButtons(.cancel) { return }
        close()
    }

    @objc private func checkNowClicked() { checkRequested?() }

    @objc private func updateNowClicked() {
        guard installRequested != nil else { return }
        // Installing restarts the panel, so unsaved edits are never dropped silently: save them first or keep editing.
        window?.endEditing(for: nil)
        guard hasUnsavedChanges, let window else { installRequested?(); return }
        let alert = NSAlert()
        alert.messageText = "Save your settings before updating?"
        alert.informativeText = "Updating restarts OMP Usage Panel. Save & Apply your unsaved changes first, or keep editing and update later."
        alert.addButton(withTitle: "Save & Apply, Then Update")
        alert.addButton(withTitle: "Keep Editing")
        alert.beginSheetModal(for: window) { [weak self] response in
            DispatchQueue.main.async { self?.interactionReleased?() }
            guard response == .alertFirstButtonReturn, let self, self.commit() else { return }
            self.installRequested?()
        }
    }

    @objc private func saveClicked() {
        if routeKeyAwayFromButtons(.activate) { return }
        _ = commit()
    }

    /// Validates and commits the whole draft (configuration, update policy and every changed compact scope); true
    /// when it was committed and the window closed.
    private func commit() -> Bool {
        guard draft != nil else { return false }
        // Commit any in-progress edit (including IME composition) and re-read every control into the draft.
        window?.endEditing(for: nil)
        for binding in Array(bindings.values) {
            if let control = binding.control { binding.apply(control.stringValue) }
        }
        hideAllIssues()
        guard let current = draft else { return false }
        let settingsCommit: SettingsCommit
        do { settingsCommit = try current.commit() }
        catch let failure as Draft.Failure { showIssues(failure.issues); return false }
        catch { showBanner(error.localizedDescription); return false }
        guard let handler = saveRequested else {
            showBanner("Saving is not connected to the running panel. Nothing was changed.")
            return false
        }
        do { try handler(settingsCommit) }
        catch {
            showBanner("Could not save settings: \(error.localizedDescription) Your edits are kept.")
            return false
        }
        close()
        return true
    }
}
