import AppKit

private final class FlippedDocumentView: NSView { override var isFlipped: Bool { true } }

final class CompactSettingsWindowController: NSWindowController, NSTextFieldDelegate {
    var preferencesChanged: ((CompactPreferences) -> Void)?

    private var preferences = CompactPreferences()
    private var providers: [CompactProviderChoice] = []
    private var isApplyingProgrammaticUpdate = false

    private let countField = NSTextField()
    private let stepper = NSStepper()
    private let sidePicker = NSSegmentedControl(labels: ["Left", "Right"], trackingMode: .selectOne, target: nil, action: nil)
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let countErrorLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No providers reported yet. Selected providers appear here once known.")
    private let rowsStack = NSStackView()
    private var rowButtons: [String: NSButton] = [:]
    private var rowOrder: [String] = []

    init() {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Compact Settings"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("OMPUsageCompactSettings")
        super.init(window: window)
        buildContent(in: window)
        window.center()
        refreshControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Public API

    /// Programmatic refresh: never emits edits, never shows/activates the window, preserves an in-progress count edit.
    func update(preferences: CompactPreferences, providers: [CompactProviderChoice]) {
        isApplyingProgrammaticUpdate = true
        defer { isApplyingProgrammaticUpdate = false }
        self.preferences = preferences.normalized
        self.providers = providers
        refreshControls()
    }

    /// Ends an in-progress count edit while the previous profile's store still receives `preferencesChanged`.
    /// Valid text was already emitted on every keystroke; invalid text reverts to the previous profile's saved value.
    /// Afterwards no pending edit can commit into the next profile, and the following silent `update` replaces every
    /// control (it preserves an edit only while one is active). Does not copy or clear any stored preferences.
    func finishEditingForProfileChange() {
        guard let window = window, countField.currentEditor() != nil else { return }
        if !window.makeFirstResponder(nil) { window.endEditing(for: nil) }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        let title = NSTextField(labelWithString: "Compact Display")
        title.font = .boldSystemFont(ofSize: 15)

        let countLabel = NSTextField(labelWithString: "Maximum slots")
        countField.alignment = .right
        countField.delegate = self
        countField.target = self
        countField.action = #selector(countCommitted)
        countField.setAccessibilityLabel("Maximum compact slots")
        countField.setAccessibilityIdentifier("compact.maximumVisibleSlots")
        countField.toolTip = "Total compact controls, including the More button."
        countField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        stepper.minValue = -1
        stepper.maxValue = 1
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        stepper.setAccessibilityLabel("Maximum compact slots stepper")
        let countViews: [NSView] = [countLabel, countField, stepper]
        let countRow = NSStackView(views: countViews)
        countRow.orientation = .horizontal
        countRow.spacing = 8

        countErrorLabel.textColor = .systemRed
        countErrorLabel.font = .systemFont(ofSize: 11)
        countErrorLabel.stringValue = ""
        countErrorLabel.isHidden = true

        let sideLabel = NSTextField(labelWithString: "Side of the camera")
        sidePicker.target = self
        sidePicker.action = #selector(sideChanged)
        sidePicker.setAccessibilityLabel("Compact wing side")
        sidePicker.setAccessibilityIdentifier("compact.side")
        let sideViews: [NSView] = [sideLabel, sidePicker]
        let sideRow = NSStackView(views: sideViews)
        sideRow.orientation = .horizontal
        sideRow.spacing = 8

        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .labelColor

        let hint = NSTextField(wrappingLabelWithString:
            "The maximum counts every compact control, and the More button uses the last slot when providers overflow. "
            + "These settings only affect the compact row; the expanded dashboard still shows everything. "
            + "Existing app or status menus are not detected, so reduce the count or switch sides if they overlap.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let providersTitle = NSTextField(labelWithString: "Providers shown in compact")
        providersTitle.font = .boldSystemFont(ofSize: 12)
        let selectAllButton = NSButton(title: "Select All", target: self, action: #selector(selectAllProviders))
        selectAllButton.setAccessibilityIdentifier("compact.selectAll")
        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearAllProviders))
        clearButton.setAccessibilityIdentifier("compact.clear")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerViews: [NSView] = [providersTitle, spacer, selectAllButton, clearButton]
        let headerRow = NSStackView(views: headerViews)
        headerRow.orientation = .horizontal
        headerRow.spacing = 8

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .secondaryLabelColor
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        scroll.documentView = document
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 10),
            rowsStack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -10),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
        ])

        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        done.keyEquivalent = "\r"
        let doneViews: [NSView] = [NSView(), done]
        let doneRow = NSStackView(views: doneViews)
        doneRow.orientation = .horizontal

        let rootViews: [NSView] = [title, countRow, countErrorLabel, sideRow, summaryLabel, hint, headerRow, scroll, doneRow]
        let root = NSStackView(views: rootViews)
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        let widthViews: [NSView] = [summaryLabel, hint, headerRow, scroll, doneRow]
        for view in widthViews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true
        }
        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window.contentView = content
    }

    // MARK: Rendering (cached controls, keyed by provider ID)

    private func displayedChoices() -> [CompactProviderChoice] {
        var choices = providers
        let known = Set(choices.map(\.id))
        for id in preferences.selectedProviderIDs ?? [] where !known.contains(id) {
            choices.append(CompactProviderChoice(id: id, label: id, detail: nil, isReported: false))
        }
        return choices
    }

    private func refreshControls() {
        let editingCount = window?.firstResponder === countField.currentEditor() && countField.currentEditor() != nil
        if !editingCount {
            countField.stringValue = String(preferences.maximumVisibleSlots)
            countErrorLabel.isHidden = true
        }
        stepper.integerValue = 0
        sidePicker.selectedSegment = preferences.side == .left ? 0 : 1
        let selected = Set(preferences.selectedProviderIDs ?? [])
        summaryLabel.stringValue = CompactPreferences.capacitySummary(selectedCount: selected.count, maximum: preferences.maximumVisibleSlots)

        let choices = displayedChoices()
        let order = choices.map(\.id)
        for choice in choices {
            let button: NSButton
            if let cached = rowButtons[choice.id] { button = cached } else {
                button = NSButton(checkboxWithTitle: "", target: self, action: #selector(providerToggled(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(choice.id)
                button.setAccessibilityIdentifier("compact.provider.\(choice.id)")
                rowButtons[choice.id] = button
            }
            var title = choice.label
            if let detail = choice.detail, !detail.isEmpty { title += " — \(detail)" }
            if !choice.isReported { title += " (not reported)" }
            if button.title != title { button.title = title }
            button.toolTip = choice.id
            button.setAccessibilityLabel(title)
            button.state = selected.contains(choice.id) ? .on : .off
        }
        for id in rowButtons.keys where !order.contains(id) { rowButtons[id] = nil }
        if order != rowOrder {
            rowOrder = order
            for view in rowsStack.arrangedSubviews { rowsStack.removeArrangedSubview(view); view.removeFromSuperview() }
            if choices.isEmpty { rowsStack.addArrangedSubview(emptyLabel) }
            for id in order { if let button = rowButtons[id] { rowsStack.addArrangedSubview(button) } }
        }
    }

    // MARK: Actions

    private func emit(_ updated: CompactPreferences) {
        guard !isApplyingProgrammaticUpdate else { return }
        let normalized = updated.normalized
        guard normalized != preferences else { return }
        preferences = normalized
        summaryLabel.stringValue = CompactPreferences.capacitySummary(
            selectedCount: Set(normalized.selectedProviderIDs ?? []).count, maximum: normalized.maximumVisibleSlots)
        preferencesChanged?(normalized)
    }

    private func parsedCount(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(trimmed), value >= 1 else { return nil }
        return value
    }

    private func applyCountText() {
        guard !isApplyingProgrammaticUpdate else { return }
        if let value = parsedCount(countField.stringValue) {
            countErrorLabel.isHidden = true
            var updated = preferences
            updated.maximumVisibleSlots = value
            emit(updated)
        } else {
            countErrorLabel.stringValue = "Enter a whole number of 1 or more."
            countErrorLabel.isHidden = false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === countField { applyCountText() }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === countField else { return }
        if parsedCount(countField.stringValue) == nil { countField.stringValue = String(preferences.maximumVisibleSlots) }
        countErrorLabel.isHidden = true
    }

    @objc private func countCommitted() { applyCountText() }

    @objc private func stepperChanged() {
        // Relative stepper (-1/0/+1, reset after each action): no lossy Double conversion or arbitrary ceiling.
        let delta = stepper.integerValue
        stepper.integerValue = 0
        let current = preferences.maximumVisibleSlots
        let value = delta > 0 ? (current == Int.max ? current : current + 1) : (delta < 0 ? max(1, current - 1) : current)
        countField.stringValue = String(value)
        countErrorLabel.isHidden = true
        var updated = preferences
        updated.maximumVisibleSlots = value
        emit(updated)
    }

    @objc private func sideChanged() {
        var updated = preferences
        updated.side = sidePicker.selectedSegment == 0 ? .left : .right
        emit(updated)
    }

    @objc private func providerToggled(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? ""
        var ids = preferences.selectedProviderIDs ?? []
        if sender.state == .on { if !ids.contains(id) { ids.append(id) } } else { ids.removeAll { $0 == id } }
        var updated = preferences
        updated.selectedProviderIDs = ids
        emit(updated)
    }

    @objc private func selectAllProviders() {
        var updated = preferences
        updated.selectedProviderIDs = displayedChoices().map(\.id)
        emit(updated)
        refreshControls()
    }

    @objc private func clearAllProviders() {
        var updated = preferences
        updated.selectedProviderIDs = []
        emit(updated)
        refreshControls()
    }

    @objc private func doneClicked() { close() }
}
