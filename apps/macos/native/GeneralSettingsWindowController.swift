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
    let key: NSComboBox
    let value: NSTextField?
    let up: NSButton?
    let down: NSButton?
    let remove: NSButton
    let error: NSTextField
    var targets: [GeneralActionTarget] = []

    init(key: NSComboBox, value: NSTextField?, up: NSButton?, down: NSButton?, remove: NSButton, error: NSTextField) {
        self.key = key; self.value = value; self.up = up; self.down = down; self.remove = remove; self.error = error
    }
}

/// The native Settings window for the editable `config.json` fields and the app-wide updater choices. Everything
/// edits a transactional `GeneralSettingsDraft`; nothing reaches disk or the running panel until Save & Apply
/// succeeds through `saveRequested` (collector configuration first, then the staged update policy). Cancel or
/// closing the window discards the draft. Check Now and Update Now are explicit immediate actions, not part of
/// the draft; update status refreshes never touch the draft, the selected tab or the focus.
final class GeneralSettingsWindowController: NSWindowController, NSWindowDelegate, NSComboBoxDelegate {
    /// Synchronous commit hook. Must persist and apply the candidate or throw; a throw keeps the draft open.
    var saveRequested: ((PanelConfig, UpdatePolicy) throws -> Void)?
    /// Immediate manual update actions. They never read or commit the draft.
    var checkRequested: (() -> Void)?
    var installRequested: (() -> Void)?
    /// Called when a window state that blocked an unsolicited update prompt or restart may have ended
    /// (window closed, sheet dismissed). The window is still on screen during the call; defer the re-evaluation.
    var interactionReleased: (() -> Void)?
    /// Optional read-only location of the configuration file shown on the Runtime tab.
    var configLocation: String? { didSet { locationValue.stringValue = configLocation ?? "Not available" } }

    private struct Binding {
        weak var control: NSTextField?
        let apply: (String) -> Void
    }

    private var draft: Draft?
    private var baseline: PanelConfig?
    private var baselinePolicy = UpdatePolicy.defaults
    private var updateStatusValue: UpdateStatus?
    private var catalog = Draft.Catalog()
    private var isApplyingProgrammaticUpdate = false
    private var pendingSuggestionRefresh = false

    private let tabView = NSTabView()
    private var fieldControls: [Draft.Field: NSTextField] = [:]
    private var fieldErrors: [Draft.Field: NSTextField] = [:]
    private var listErrors: [Draft.RowList: NSTextField] = [:]
    private var errorFor: [ObjectIdentifier: NSTextField] = [:]
    private var rowStacks: [Draft.RowList: NSStackView] = [:]
    private var rowControls: [Draft.RowList: [Int: GeneralRowControls]] = [:]
    private var addButtons: [Draft.RowList: NSButton] = [:]
    private var bindings: [ObjectIdentifier: Binding] = [:]

    private let paceCheckbox = NSButton(checkboxWithTitle: "Show elapsed-period pace markers", target: nil, action: nil)
    private let modeControl = NSSegmentedControl(labels: ["Automatic", "Custom"], trackingMode: .selectOne, target: nil, action: nil)
    private let modeHint = NSTextField(wrappingLabelWithString: "")
    private let observedLabel = NSTextField(wrappingLabelWithString: "")
    private let versionValue = NSTextField(labelWithString: "")
    private let locationValue = NSTextField(wrappingLabelWithString: "Not available")
    private let bannerLabel = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save & Apply", target: nil, action: nil)

    private let updatesVersionValue = NSTextField(labelWithString: "")
    private let automaticChecksCheckbox = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let notificationsCheckbox = NSButton(checkboxWithTitle: "Show a notice when an update is available", target: nil, action: nil)
    private let automaticInstallCheckbox = NSButton(checkboxWithTitle: "Download and install updates automatically", target: nil, action: nil)
    private let updateStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let updateAvailableLabel = NSTextField(labelWithString: "")
    private let updateCheckedLabel = NSTextField(labelWithString: "")
    private let updateSkippedLabel = NSTextField(wrappingLabelWithString: "")
    private let updateProgress = NSProgressIndicator()
    private let checkNowButton = NSButton(title: "Check Now", target: nil, action: nil)
    private let updateNowButton = NSButton(title: "Update Now", target: nil, action: nil)
    private static let lastCheckedFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init() {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 440)
        window.setFrameAutosaveName("OMPUsageGeneralSettings")
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Public API

    /// Starts a fresh draft from the committed config when the window is closed. While it is open the draft is
    /// kept as is (only observed suggestions refresh). Never presents or activates the window.
    func edit(config: PanelConfig, updatePolicy: UpdatePolicy, result: PanelResult?) {
        catalog = Draft.Catalog(result: result)
        if draft != nil, let window, window.isVisible || window.isMiniaturized {
            refreshSuggestions()
            return
        }
        baseline = config
        baselinePolicy = updatePolicy
        draft = Draft(config: config, updatePolicy: updatePolicy)
        loadControlsFromDraft()
        refreshSuggestions()
    }

    /// True while unsaved edits (collector configuration or staged update choices) exist.
    var hasUnsavedChanges: Bool {
        guard let draft, let baseline else { return false }
        return draft.hasChanges(from: baseline, updatePolicy: baselinePolicy)
    }

    /// Visible or minimized: an unsolicited update prompt must stay quiet.
    var isInUse: Bool {
        guard let window else { return false }
        return window.isVisible || window.isMiniaturized || window.attachedSheet != nil
    }

    /// Shows the latest updater status. Changes labels and button states only; never the draft, tab or focus.
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

    func selectUpdatesTab() {
        tabView.selectTabViewItem(withIdentifier: "Updates")
    }

    /// Changes only the observed ID suggestions; never the draft, the committed config, focus or the save hook.
    func updateCatalog(result: PanelResult?) {
        catalog = Draft.Catalog(result: result)
        refreshSuggestions()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        draft = nil
        baseline = nil
        pendingSuggestionRefresh = false
        hideAllIssues()
        interactionReleased?()
    }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.setAccessibilityIdentifier("general.tabs")
        addTab("Collection", collectionPage())
        addTab("Display", displayPage())
        addTab("Providers", providersPage())
        addTab("Labels", labelsPage())
        addTab("Metrics", metricsPage())
        addTab("Runtime", runtimePage())
        addTab("Updates", updatesPage())
        tabView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)

        bannerLabel.font = .systemFont(ofSize: 12)
        bannerLabel.textColor = .systemRed
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

        let rootViews: [NSView] = [tabView, bannerLabel, buttons]
        let root = NSStackView(views: rootViews)
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 14, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        for view in rootViews { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true }
        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window.contentView = content

        paceCheckbox.target = self
        paceCheckbox.action = #selector(paceChanged)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0
        updateModeState()
        updateObservedLabel()
        renderUpdateStatus()
    }

    private func addTab(_ title: String, _ page: NSScrollView) {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = page
        tabView.addTabViewItem(item)
    }

    private func tabIndex(for field: Draft.Field) -> Int {
        switch field {
        case .refreshSeconds, .cacheMinutes, .timeoutSeconds: return 0
        case .warnPercent, .criticalPercent: return 1
        case .providers: return 2
        case .labels: return 3
        case .metrics: return 4
        case .nodePath, .ompPath, .profile: return 5
        }
    }

    private func fill(_ view: NSView, in stack: NSStackView, inset: CGFloat) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset).isActive = true
    }

    private func makePage(_ views: [NSView]) -> NSScrollView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views { fill(view, in: stack, inset: 36) }
        let document = GeneralFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
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

    private func group(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        for view in views { fill(view, in: stack, inset: 0) }
        return stack
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 14)
        return label
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeErrorLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .systemRed
        label.isHidden = true
        return label
    }

    private func bind(_ control: NSTextField, apply: @escaping (String) -> Void) {
        bindings[ObjectIdentifier(control)] = Binding(control: control, apply: apply)
    }

    private func makeTextField(field: Draft.Field, identifier: String, accessibility: String, width: CGFloat? = nil,
                               rightAligned: Bool = false, placeholder: String? = nil) -> NSTextField {
        let input = NSTextField()
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
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let input = makeTextField(field: field, identifier: identifier, accessibility: title, width: 110, rightAligned: true)
        let unitLabel = NSTextField(labelWithString: unit)
        unitLabel.textColor = .secondaryLabelColor
        let rowViews: [NSView] = [titleLabel, input, unitLabel]
        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        let error = makeErrorLabel()
        fieldErrors[field] = error
        errorFor[ObjectIdentifier(input)] = error
        return group([row, error, hint(help)])
    }

    private func pathGroup(_ title: String, field: Draft.Field, identifier: String, placeholder: String,
                           help: String, choose: Selector) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let input = makeTextField(field: field, identifier: identifier, accessibility: title, placeholder: placeholder)
        input.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let chooseButton = NSButton(title: "Choose…", target: self, action: choose)
        chooseButton.setAccessibilityIdentifier(identifier + ".choose")
        chooseButton.setAccessibilityLabel("Choose \(title)")
        chooseButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let rowViews: [NSView] = [titleLabel, input, chooseButton]
        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        let error = makeErrorLabel()
        fieldErrors[field] = error
        errorFor[ObjectIdentifier(input)] = error
        return group([row, error, hint(help)])
    }

    // MARK: Pages

    private func collectionPage() -> NSScrollView {
        makePage([
            heading("Collection"),
            numberGroup("Refresh every", field: .refreshSeconds, identifier: "general.refreshSeconds", unit: "seconds",
                        help: "How often the panel collects usage. Values below 1 second run at 1 second. Fractions are allowed."),
            numberGroup("Reuse results for", field: .cacheMinutes, identifier: "general.cacheMinutes", unit: "minutes",
                        help: "How long a collected result may be reused before omp is asked again. 0 never reuses by age. Fractions are allowed."),
            numberGroup("Collection timeout", field: .timeoutSeconds, identifier: "general.timeoutSeconds", unit: "seconds",
                        help: "The longest one collection may run before it is stopped."),
        ])
    }

    private func displayPage() -> NSScrollView {
        paceCheckbox.setAccessibilityIdentifier("general.showPace")
        paceCheckbox.setAccessibilityLabel("Show elapsed-period pace markers")
        return makePage([
            heading("Display"),
            numberGroup("Warning at", field: .warnPercent, identifier: "general.warnPercent", unit: "%",
                        help: "Usage at or above this percentage is shown as a warning. 0 or more; values above 100 are allowed."),
            numberGroup("Critical at", field: .criticalPercent, identifier: "general.criticalPercent", unit: "%",
                        help: "Usage at or above this percentage is shown as critical. Must be at least the warning value; values above 100 are allowed."),
            paceCheckbox,
            hint("Pace markers show how much of each limit's period has elapsed, next to the usage."),
        ])
    }

    private func providersPage() -> NSScrollView {
        modeHint.font = .systemFont(ofSize: 11)
        modeHint.textColor = .secondaryLabelColor
        modeControl.setAccessibilityLabel("Provider list mode")
        modeControl.setAccessibilityIdentifier("general.providers.mode")
        var views: [NSView] = [heading("Summary providers"), modeControl, modeHint]
        views += listSection(.providers, addTitle: "Add provider ID", addIdentifier: "general.providers.add", add: #selector(addProviderRow))
        views.append(hint("Providers only choose and order the summary list. Collection still reads every account, and All in the provider filter still shows them. IDs are matched exactly; unreported IDs are allowed. Credentials stay managed by omp."))
        return makePage(views)
    }

    private func labelsPage() -> NSScrollView {
        var views: [NSView] = [heading("Display labels")]
        views += listSection(.labels, addTitle: "Add label", addIdentifier: "general.labels.add", add: #selector(addLabelRow))
        views.append(hint("Each row renames one provider ID in summaries. Rows are independent of the provider list, so entries for unreported or unselected providers are kept."))
        return makePage(views)
    }

    private func metricsPage() -> NSScrollView {
        observedLabel.font = .systemFont(ofSize: 11)
        observedLabel.textColor = .secondaryLabelColor
        observedLabel.isSelectable = true
        observedLabel.setAccessibilityIdentifier("general.metrics.observed")
        var views: [NSView] = [heading("Representative metrics")]
        views += listSection(.metrics, addTitle: "Add metric override", addIdentifier: "general.metrics.add", add: #selector(addMetricRow))
        views.append(hint("The limit ID must match a limit ID exactly (not its window or label); a missing ID shows an unknown metric. Remove a row to return that provider to automatic selection."))
        views.append(observedLabel)
        return makePage(views)
    }

    private func runtimePage() -> NSScrollView {
        versionValue.textColor = .secondaryLabelColor
        versionValue.setAccessibilityIdentifier("general.version")
        locationValue.isSelectable = true
        locationValue.font = .systemFont(ofSize: 11)
        locationValue.textColor = .secondaryLabelColor
        locationValue.setAccessibilityIdentifier("general.location")
        let profileTitle = NSTextField(labelWithString: "Profile")
        profileTitle.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let profileInput = makeTextField(field: .profile, identifier: "general.profile", accessibility: "Profile", placeholder: "default")
        profileInput.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let profileViews: [NSView] = [profileTitle, profileInput]
        let profileRow = NSStackView(views: profileViews)
        profileRow.orientation = .horizontal
        profileRow.spacing = 8
        profileRow.alignment = .firstBaseline
        let profileError = makeErrorLabel()
        fieldErrors[.profile] = profileError
        errorFor[ObjectIdentifier(profileInput)] = profileError
        let locationTitle = NSTextField(labelWithString: "Configuration file")
        locationTitle.font = .boldSystemFont(ofSize: 12)
        return makePage([
            heading("Runtime"),
            pathGroup("Node executable", field: .nodePath, identifier: "general.nodePath", placeholder: "/path/to/node",
                      help: "Absolute path of the Node.js executable that runs the collector.", choose: #selector(chooseNode)),
            pathGroup("omp executable", field: .ompPath, identifier: "general.ompPath", placeholder: "/path/to/omp",
                      help: "Absolute path of the omp executable the collector calls.", choose: #selector(chooseOmp)),
            group([profileRow, profileError, hint("Selects an existing omp profile. Sign-in and credentials stay managed by omp; this panel never reads or edits them.")]),
            locationTitle,
            locationValue,
            versionValue,
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
        updatesVersionValue.isSelectable = true
        updatesVersionValue.setAccessibilityIdentifier("general.updates.version")

        automaticChecksCheckbox.target = self
        automaticChecksCheckbox.action = #selector(automaticChecksChanged)
        automaticChecksCheckbox.setAccessibilityIdentifier("general.updates.automaticChecks")
        automaticChecksCheckbox.setAccessibilityLabel("Check for updates automatically")
        notificationsCheckbox.target = self
        notificationsCheckbox.action = #selector(notificationsChanged)
        notificationsCheckbox.setAccessibilityIdentifier("general.updates.notifications")
        notificationsCheckbox.setAccessibilityLabel("Show a notice when an update is available")
        automaticInstallCheckbox.target = self
        automaticInstallCheckbox.action = #selector(automaticInstallChanged)
        automaticInstallCheckbox.setAccessibilityIdentifier("general.updates.automaticInstall")
        automaticInstallCheckbox.setAccessibilityLabel("Download and install updates automatically")

        updateStatusLabel.isSelectable = true
        updateStatusLabel.setAccessibilityIdentifier("general.updates.status")
        updateAvailableLabel.setAccessibilityIdentifier("general.updates.available")
        updateCheckedLabel.textColor = .secondaryLabelColor
        updateCheckedLabel.font = .systemFont(ofSize: 11)
        updateCheckedLabel.setAccessibilityIdentifier("general.updates.lastChecked")
        updateSkippedLabel.textColor = .secondaryLabelColor
        updateSkippedLabel.font = .systemFont(ofSize: 11)
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
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actionViews: [NSView] = [checkNowButton, updateNowButton, updateProgress, spacer]
        let actions = NSStackView(views: actionViews)
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY

        return makePage([
            heading("Updates"),
            updatesVersionValue,
            group([automaticChecksCheckbox, hint("Looks for a new version about once a day. Manual checks always work, even when this is off.")]),
            group([notificationsCheckbox, hint("Shows a small notice that never takes keyboard focus. Turning this off never changes how updates are installed.")]),
            group([automaticInstallCheckbox, hint("Off by default. When on, updates found by automatic checks are downloaded and installed, then the panel restarts once nothing is being edited. Requires automatic checks.")]),
            hint("These three choices apply when you press Save & Apply."),
            heading("Status"),
            updateStatusLabel,
            updateAvailableLabel,
            updateCheckedLabel,
            updateSkippedLabel,
            actions,
            hint("Check Now and Update Now act immediately and are not part of Save & Apply. Update Now installs only this update and restarts the panel. Checking contacts the update feed; no usage, account or configuration data is sent."),
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
        let button = NSButton(title: addTitle, target: self, action: add)
        button.setAccessibilityIdentifier(addIdentifier)
        addButtons[list] = button
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let addViews: [NSView] = [button, spacer]
        let addRow = NSStackView(views: addViews)
        addRow.orientation = .horizontal
        return [rows, error, addRow]
    }

    // MARK: Rows

    private func listName(_ list: Draft.RowList) -> String {
        switch list {
        case .providers: return "providers"
        case .labels: return "labels"
        case .metrics: return "metrics"
        }
    }

    private func makeCombo(identifier: String, accessibility: String, text: String, placeholder: String, fixedWidth: CGFloat?) -> NSComboBox {
        let box = NSComboBox()
        box.isEditable = true
        box.completes = false
        box.numberOfVisibleItems = 8
        box.hasVerticalScroller = true
        box.delegate = self
        box.stringValue = text
        box.placeholderString = placeholder
        box.setAccessibilityLabel(accessibility)
        box.setAccessibilityIdentifier(identifier)
        if let fixedWidth { box.widthAnchor.constraint(equalToConstant: fixedWidth).isActive = true }
        else { box.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal) }
        return box
    }

    private func makeSmallButton(_ title: String, identifier: String, accessibility: String, handler: @escaping () -> Void) -> (NSButton, GeneralActionTarget) {
        let target = GeneralActionTarget(handler)
        let button = NSButton(title: title, target: target, action: #selector(GeneralActionTarget.fire))
        button.controlSize = .small
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(accessibility)
        return (button, target)
    }

    private func makeRowControls(_ list: Draft.RowList, row: Draft.Row) -> GeneralRowControls {
        let id = row.id
        let prefix = "general.\(listName(list)).row.\(id)"
        let keyBox = makeCombo(identifier: prefix + ".providerID", accessibility: "Provider ID", text: row.key,
                               placeholder: "provider-id", fixedWidth: list == .providers ? nil : 200)
        bind(keyBox) { [weak self] text in
            self?.draft?.setRow(list, id: id, key: text)
            if list == .metrics { self?.refreshLimitSuggestions(rowID: id) }
        }

        var value: NSTextField?
        switch list {
        case .providers: break
        case .labels:
            let field = NSTextField()
            field.delegate = self
            field.stringValue = row.value
            field.placeholderString = "Display label"
            field.setAccessibilityLabel("Display label")
            field.setAccessibilityIdentifier(prefix + ".label")
            field.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            bind(field) { [weak self] text in self?.draft?.setRow(list, id: id, value: text) }
            value = field
        case .metrics:
            let box = makeCombo(identifier: prefix + ".limitID", accessibility: "Limit ID", text: row.value,
                                placeholder: "limit-id", fixedWidth: nil)
            bind(box) { [weak self] text in self?.draft?.setRow(list, id: id, value: text) }
            value = box
        }

        var targets: [GeneralActionTarget] = []
        var up: NSButton?
        var down: NSButton?
        if list == .providers {
            let (upButton, upTarget) = makeSmallButton("↑", identifier: prefix + ".up", accessibility: "Move provider up") { [weak self] in
                self?.moveRow(list, id: id, by: -1)
            }
            let (downButton, downTarget) = makeSmallButton("↓", identifier: prefix + ".down", accessibility: "Move provider down") { [weak self] in
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

        var lineViews: [NSView] = [keyBox]
        if let value { lineViews.append(value) }
        if let up { lineViews.append(up) }
        if let down { lineViews.append(down) }
        lineViews.append(remove)
        let line = NSStackView(views: lineViews)
        line.orientation = .horizontal
        line.spacing = 6
        line.alignment = .centerY
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
        draft?.updatePolicy.automaticChecks = automaticChecksCheckbox.state == .on
        updateAutomaticInstallEnablement()
    }
    @objc private func notificationsChanged() { draft?.updatePolicy.notificationsEnabled = notificationsCheckbox.state == .on }
    @objc private func automaticInstallChanged() { draft?.updatePolicy.automaticInstallation = automaticInstallCheckbox.state == .on }

    // MARK: Updates

    private func loadUpdatePolicyControls() {
        guard let policy = draft?.updatePolicy else { return }
        automaticChecksCheckbox.state = policy.automaticChecks ? .on : .off
        notificationsCheckbox.state = policy.notificationsEnabled ? .on : .off
        automaticInstallCheckbox.state = policy.automaticInstallation ? .on : .off
        updateAutomaticInstallEnablement()
    }

    private func updateAutomaticInstallEnablement() {
        let enabled = automaticChecksCheckbox.state == .on
        if automaticInstallCheckbox.isEnabled != enabled { automaticInstallCheckbox.isEnabled = enabled }
    }

    private func setEnabled(_ button: NSButton, _ enabled: Bool) {
        if button.isEnabled != enabled { button.isEnabled = enabled }
    }

    private func renderUpdateStatus() {
        guard let status = updateStatusValue else {
            updateStatusLabel.stringValue = "Update status is not available yet."
            updateStatusLabel.textColor = .secondaryLabelColor
            updateAvailableLabel.isHidden = true
            updateCheckedLabel.stringValue = "Not checked yet."
            updateSkippedLabel.isHidden = true
            updateProgress.stopAnimation(nil)
            setEnabled(checkNowButton, false)
            setEnabled(updateNowButton, false)
            return
        }
        updateStatusLabel.stringValue = status.message
        updateStatusLabel.textColor = status.phase == .failed ? .systemRed : (status.installBlocked ? .systemOrange : .labelColor)
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
        paceCheckbox.state = draft.showPace ? .on : .off
        loadUpdatePolicyControls()
        modeControl.selectedSegment = draft.providerMode == .custom ? 1 : 0
        versionValue.stringValue = "Schema version \(draft.version) (read-only)"
        hideAllIssues()
        for list in Draft.RowList.allCases {
            clearRows(list)
            syncRows(list)
        }
        updateModeState()
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

    private func setItems(_ box: NSComboBox, _ items: [String]) {
        if let current = box.objectValues as? [String], current.count == items.count, zip(current, items).allSatisfy({ $0.isExactlyEqual(to: $1) }) { return }
        if let editor = box.currentEditor(), window?.firstResponder === editor {
            pendingSuggestionRefresh = true
            return
        }
        let text = box.stringValue
        let wasApplying = isApplyingProgrammaticUpdate
        isApplyingProgrammaticUpdate = true
        box.removeAllItems()
        box.addItems(withObjectValues: items)
        if !box.stringValue.isExactlyEqual(to: text) { box.stringValue = text }
        isApplyingProgrammaticUpdate = wasApplying
    }

    /// Reuses existing combo controls; an actively edited combo is skipped and refreshed after editing ends.
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
              let combo = rowControls[.metrics]?[rowID]?.value as? NSComboBox,
              let row = draft.rows(.metrics).first(where: { $0.id == rowID }) else { return }
        setItems(combo, catalog.limitSuggestions(provider: row.key, config: baseline))
    }

    // MARK: Errors

    private func hideAllIssues() {
        var labels: [NSTextField] = Array(fieldErrors.values) + Array(listErrors.values)
        for rows in rowControls.values { labels += rows.values.map(\.error) }
        for label in labels {
            label.stringValue = ""
            label.isHidden = true
        }
        bannerLabel.stringValue = ""
        bannerLabel.isHidden = true
    }

    private func showBanner(_ message: String) {
        bannerLabel.stringValue = message
        bannerLabel.isHidden = false
    }

    private func showIssues(_ issues: [Draft.Issue]) {
        hideAllIssues()
        for issue in issues {
            let label: NSTextField?
            if let list = issue.field.rowList {
                label = issue.rowID.flatMap { rowControls[list]?[$0]?.error } ?? listErrors[list]
            } else {
                label = fieldErrors[issue.field]
            }
            guard let label else { continue }
            label.stringValue = label.isHidden ? issue.message : label.stringValue + "\n" + issue.message
            label.isHidden = false
        }
        if let first = issues.first {
            let index = tabIndex(for: first.field)
            if index < tabView.numberOfTabViewItems { tabView.selectTabViewItem(at: index) }
        }
        showBanner("\(issues.count) problem\(issues.count == 1 ? "" : "s") must be fixed before saving. Nothing was changed.")
    }

    private func hideError(for control: NSTextField) {
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
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard pendingSuggestionRefresh else { return }
        pendingSuggestionRefresh = false
        DispatchQueue.main.async { [weak self] in self?.refreshSuggestions() }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard !isApplyingProgrammaticUpdate, let box = notification.object as? NSComboBox,
              let binding = bindings[ObjectIdentifier(box)],
              let selected = box.objectValueOfSelectedItem as? String else { return }
        binding.apply(selected)
        hideError(for: box)
    }

    // MARK: Actions

    @objc private func paceChanged() { draft?.showPace = paceCheckbox.state == .on }

    @objc private func modeChanged() {
        draft?.providerMode = modeControl.selectedSegment == 1 ? .custom : .automatic
        updateModeState()
    }

    @objc private func chooseNode() { chooseFile(for: .nodePath, message: "Choose the Node.js executable") }
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

    @objc private func cancelClicked() { close() }

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

    @objc private func saveClicked() { _ = commit() }

    /// Validates and commits the draft; true when it was committed and the window closed.
    private func commit() -> Bool {
        guard draft != nil else { return false }
        // Commit any in-progress edit (including IME composition) and re-read every control into the draft.
        window?.endEditing(for: nil)
        for binding in Array(bindings.values) {
            if let control = binding.control { binding.apply(control.stringValue) }
        }
        hideAllIssues()
        guard let current = draft else { return false }
        let candidate: PanelConfig
        do { candidate = try current.candidate() }
        catch let failure as Draft.Failure { showIssues(failure.issues); return false }
        catch { showBanner(error.localizedDescription); return false }
        guard let handler = saveRequested else {
            showBanner("Saving is not connected to the running panel. Nothing was changed.")
            return false
        }
        do { try handler(candidate, current.updatePolicy) }
        catch {
            showBanner("Could not save settings: \(error.localizedDescription) Your edits are kept.")
            return false
        }
        close()
        return true
    }
}
