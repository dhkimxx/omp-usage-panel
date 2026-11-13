import AppKit

/// One-time native setup shown when OMP Usage is opened without arguments from anywhere but its managed location
/// (the DMG, Downloads, any copy). It never creates the panel or the updater and never writes a file itself: Install
/// & Open hands the confirmed values to the bundled `setup-install.mjs`, which copies the app to ~/Applications,
/// writes the configuration and registers the login item, then this process exits.
///
/// Accessibility identifiers: setup.title, setup.notice, setup.disclosure, setup.config.status, setup.omp.path,
/// setup.omp.choose, setup.omp.status, setup.detect,
/// setup.profile, setup.hint, setup.error, setup.progress, setup.quit, setup.install.
final class SetupWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private static let contentWidth: CGFloat = 520
    private static let cardInnerWidth: CGFloat = 492

    private let home: String
    private let sourceAppPath: String
    private let helperPath: String
    private let runner: SetupRunner
    private var draft: SetupDraft
    private var gate = SetupQuitGate()

    private var ompTouched = false
    private var discovering = false
    private var discoveryFinished = false
    private var discoveryGeneration = 0
    private var failureMessage: String?
    private var installTakingLong = false

    private let ompField = SettingsTextField(frame: .zero)
    private let profileField = SettingsTextField(frame: .zero)
    private let ompChoose = SettingsButton(title: "Choose\u{2026}", style: .secondary, compact: true)
    private let detectButton = SettingsButton(title: "Detect Again", style: .quiet, compact: true)
    private let ompStatus = NSTextField(wrappingLabelWithString: "")
    private let configStatus = NSTextField(wrappingLabelWithString: "")
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let quitButton = SettingsButton(title: "Quit", style: .secondary)
    private let installButton = SettingsButton(title: "Install & Open", style: .primary)

    /// `notice` is shown above the form (for example why a managed launch fell back to setup).
    init(home: String, sourceAppPath: String, helperPath: String, runner: SetupRunner, notice: String?) {
        self.home = home
        self.sourceAppPath = sourceAppPath
        self.helperPath = helperPath
        self.runner = runner
        let existing = SetupExistingConfig.read(path: SetupLaunch.defaultConfigPath(home: home))
        let discovery = SetupDiscoveryEnvironment(home: home, path: ProcessInfo.processInfo.environment["PATH"])
        // Suggestions only: nothing is written until the user presses Install & Open.
        draft = SetupDraft(existing: existing, suggestedOmp: SetupDiscovery.ompCandidates(discovery).first ?? "")
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth + 64, height: 640),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "OMP Usage Setup"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = SettingsPalette.window
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        if let notice { noticeLabel.stringValue = notice; noticeLabel.isHidden = false }
        loadFields()
        render()
        window.center()
        beginInitialChecks()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Quit is deferred while the install is mutating and honoured as soon as it finishes.
    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        gate.quitAsked() == .terminateNow ? .terminateNow : .terminateCancel
    }

    // MARK: Layout

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = SettingsPalette.text, width: CGFloat = SetupWindowController.contentWidth, identifier: String? = nil) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = SettingsPalette.font(size, weight)
        field.textColor = color
        field.preferredMaxLayoutWidth = width
        if let identifier { field.setAccessibilityIdentifier(identifier) }
        return field
    }

    private func style(_ field: NSTextField, size: CGFloat, color: NSColor, identifier: String, width: CGFloat = SetupWindowController.contentWidth) {
        field.font = SettingsPalette.font(size)
        field.textColor = color
        field.preferredMaxLayoutWidth = width
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(identifier)
    }

    /// Same rule as the Settings window: a leading-aligned vertical stack whose children are stretched to the stack
    /// width with an explicit constraint (NSStackView has no valid "fill width" alignment), minus insets.
    private func fill(_ view: NSView, in stack: NSStackView, inset: CGFloat = 0) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset).isActive = true
    }

    private func card(_ views: [NSView]) -> SettingsCardView {
        let card = SettingsCardView(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views { fill(view, in: stack, inset: 28) }
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor), stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)])
        return card
    }

    private func configure(_ field: SettingsTextField, placeholder: String, identifier: String, label text: String) {
        field.placeholderString = placeholder
        field.delegate = self
        field.lineBreakMode = .byTruncatingMiddle
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(text)
    }

    private func pathRow(title: String, field: SettingsTextField, choose: SettingsButton?, status: NSTextField) -> NSStackView {
        let caption = label(title, size: 12, weight: .medium, color: SettingsPalette.secondary, width: Self.cardInnerWidth)
        var rowViews: [NSView] = [field]
        if let choose { rowViews.append(choose) }
        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.distribution = .fill
        row.spacing = 8
        row.alignment = .centerY
        field.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        if let choose { choose.setContentHuggingPriority(.required, for: .horizontal) }
        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 4
        for view in [caption, row, status] { fill(view, in: block) }
        return block
    }

    private func buildContent(in window: NSWindow) {
        let background = SettingsFillView(color: SettingsPalette.window)
        window.contentView = background

        let title = label("Set up OMP Usage", size: 22, weight: .semibold, identifier: "setup.title")
        let subtitle = label("OMP Usage shows your omp provider limits in a floating panel. This one-time setup installs it for your account and keeps it running from your Applications folder.", size: 12, color: SettingsPalette.secondary)

        noticeLabel.font = SettingsPalette.font(12)
        noticeLabel.textColor = SettingsPalette.warning
        noticeLabel.preferredMaxLayoutWidth = Self.contentWidth
        noticeLabel.setAccessibilityIdentifier("setup.notice")
        noticeLabel.isHidden = true

        let disclosure = label("Clicking Install & Open means you agree to this:\n\u{2022} OMP Usage is copied to ~/Applications/OMP Usage.app.\n\u{2022} Its settings are saved in ~/Library/Application Support/omp-usage-panel.\n\u{2022} A login item is registered so it starts automatically every time you log in.\n\u{2022} OMP Usage runs on its own bundled copy of Node.js, unpacked into ~/Library/Application Support/omp-usage-panel/runtime; you do not need to install Node.js.\n\u{2022} omp is used from the path below and is never copied. This setup does not read or copy your omp sign-in or plugins; after setup, usage collection runs through the installed omp.\n\u{2022} This app is not notarized by Apple, so macOS may ask you to confirm opening it.", size: 12, color: SettingsPalette.secondary, width: Self.cardInnerWidth, identifier: "setup.disclosure")

        style(configStatus, size: 12, color: SettingsPalette.secondary, identifier: "setup.config.status", width: Self.cardInnerWidth)
        configStatus.isHidden = true

        configure(ompField, placeholder: "~/.local/bin/omp (absolute path)", identifier: "setup.omp.path", label: "omp path")
        configure(profileField, placeholder: SetupDraft.defaultProfile, identifier: "setup.profile", label: "Profile")
        style(ompStatus, size: 11, color: SettingsPalette.muted, identifier: "setup.omp.status", width: Self.cardInnerWidth)
        for (button, id, name) in [(ompChoose, "setup.omp.choose", "Choose omp"), (detectButton, "setup.detect", "Detect Again")] {
            button.setAccessibilityIdentifier(id)
            button.setAccessibilityLabel(name)
        }
        ompChoose.target = self; ompChoose.action = #selector(chooseOmp)
        detectButton.target = self; detectButton.action = #selector(detectClicked)

        let form = card([
            configStatus,
            pathRow(title: "omp", field: ompField, choose: ompChoose, status: ompStatus),
            pathRow(title: "Profile", field: profileField, choose: nil, status: NSTextField(wrappingLabelWithString: "")),
        ])

        style(hintLabel, size: 11, color: SettingsPalette.muted, identifier: "setup.hint")
        style(errorLabel, size: 12, color: SettingsPalette.error, identifier: "setup.error")
        errorLabel.isHidden = true
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityIdentifier("setup.progress")
        progress.setAccessibilityLabel("Installing")
        quitButton.target = self; quitButton.action = #selector(quitClicked)
        quitButton.setAccessibilityIdentifier("setup.quit")
        quitButton.keyEquivalent = "\u{1b}"
        installButton.target = self; installButton.action = #selector(installClicked)
        installButton.setAccessibilityIdentifier("setup.install")
        installButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let buttons = NSStackView(views: [detectButton, spacer, progress, quitButton, installButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill
        buttons.spacing = 10
        buttons.alignment = .centerY

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        for view in [title, subtitle, noticeLabel, card([disclosure]), form, errorLabel, hintLabel, buttons] { fill(view, in: stack) }
        stack.setCustomSpacing(6, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 40),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
        background.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: Self.contentWidth + 64, height: ceil(stack.fittingSize.height) + 72))
    }

    // MARK: State

    private func loadFields() {
        ompField.stringValue = draft.ompPath
        profileField.stringValue = draft.profile
        let editable = !draft.isReadOnly && !draft.isRefused
        for field in [ompField, profileField] {
            field.isEditable = editable
            field.isSelectable = true
        }
        switch draft.existing {
        case .valid:
            configStatus.stringValue = "An existing configuration was found. It stays exactly as it is, and the values below come from it. To change them, edit that file or use Settings after setup."
            configStatus.isHidden = false
        case .refused(let message):
            configStatus.stringValue = message + " Setup will not replace or reset this file. Fix or move it, then open this app again."
            configStatus.textColor = SettingsPalette.error
            configStatus.isHidden = false
        case .none:
            configStatus.isHidden = true
        }
    }

    private func beginInitialChecks() {
        switch draft.existing {
        case .valid: discoveryFinished = true; render()
        case .none: runDiscovery(force: false)
        case .refused: discoveryFinished = true; render()
        }
    }

    private func render() {
        let busy = gate.isMutating
        let editable = !draft.isReadOnly && !draft.isRefused && !busy
        for field in [ompField, profileField] { field.isEnabled = !busy; field.isEditable = editable }
        ompChoose.isEnabled = editable
        detectButton.isEnabled = editable && !discovering
        detectButton.isHidden = draft.isReadOnly || draft.isRefused
        ompChoose.isHidden = draft.isReadOnly || draft.isRefused
        quitButton.isEnabled = !busy
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }

        ompField.showsError = !draft.isReadOnly && draft.ompIssue() != nil && !draft.ompPath.isEmpty
        profileField.showsError = !draft.isReadOnly && draft.profileIsBlank

        let (ompText, ompColor) = ompStatusText()
        ompStatus.stringValue = ompText; ompStatus.textColor = ompColor

        let blocker = draft.blocker()
        installButton.isEnabled = !busy && blocker == nil
        hintLabel.stringValue = busy ? (installTakingLong ? "Still installing \u{2014} this is taking longer than usual. Please keep this window open; it finishes on its own." : "Installing\u{2026} this can take a moment. Please keep this window open.") : (blocker.map { draft.blockerMessage($0) } ?? "")
        hintLabel.isHidden = hintLabel.stringValue.isEmpty
        errorLabel.stringValue = failureMessage ?? ""
        errorLabel.isHidden = failureMessage == nil
        for button in [installButton, quitButton, ompChoose, detectButton] { button.needsDisplay = true }
    }

    private func ompStatusText() -> (String, NSColor) {
        if draft.isRefused { return ("", SettingsPalette.muted) }
        if draft.isReadOnly { return (draft.ompIssue() == nil ? "" : "The configured omp file is not currently usable. It does not block setup; fix it in Settings \u{2192} Runtime after setup if needed.", SettingsPalette.warning) }
        if let issue = draft.ompIssue() {
            if draft.ompPath.isEmpty { return ("omp was not found. Install it, then press Detect Again or choose it.", SettingsPalette.muted) }
            return (issue.message(subject: "omp"), SettingsPalette.error)
        }
        return ("omp found.", NSColor.systemGreen)
    }

    // MARK: Discovery

    private func runDiscovery(force: Bool) {
        discoveryGeneration += 1
        let generation = discoveryGeneration
        if force { ompTouched = false }
        discovering = true
        failureMessage = nil
        render()
        let environment = SetupDiscoveryEnvironment(home: home, path: ProcessInfo.processInfo.environment["PATH"])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let omp = SetupDiscovery.ompCandidates(environment).first
            DispatchQueue.main.async {
                guard let self, generation == self.discoveryGeneration else { return }
                self.discovering = false
                self.discoveryFinished = true
                if !self.ompTouched, let omp { self.draft.setOmpPath(omp); self.ompField.stringValue = omp }
                self.render()
            }
        }
    }

    // MARK: Editing

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, !draft.isReadOnly, !gate.isMutating else { return }
        failureMessage = nil
        if field === ompField { ompTouched = true; draft.setOmpPath(field.stringValue) }
        else if field === profileField { draft.setProfile(field.stringValue) }
        render()
    }

    @objc private func chooseOmp() { choose(message: "Choose the omp executable") { [weak self] path in
        guard let self else { return }
        self.ompTouched = true; self.draft.setOmpPath(path); self.ompField.stringValue = path; self.render()
    } }

    private func choose(message: String, apply: @escaping (String) -> Void) {
        guard !gate.isMutating, !draft.isReadOnly, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Version managers keep executables in hidden folders (for example ~/.nvm), so hidden files must be visible.
        panel.showsHiddenFiles = true
        panel.message = message
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.failureMessage = nil
            apply(url.path)
            self.render()
        }
    }

    @objc private func detectClicked() { guard !draft.isReadOnly, !gate.isMutating else { return }; runDiscovery(force: true) }

    // MARK: Actions

    /// Install/Quit are default/cancel key-equivalent buttons, which the window may offer Return/Escape to before
    /// the active field editor sees them (same rule as the Settings window's Save/Cancel). While an input method is
    /// composing (marked text) the actual key event goes to the editor exactly once, so Return confirms the
    /// composition and Escape cancels it instead of installing or quitting. A mouse click never routes here.
    /// Returns true when the key was consumed.
    private func routeKeyToComposingEditor() -> Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown, let window,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, editor.hasMarkedText() else { return false }
        editor.keyDown(with: event)
        return true
    }

    @objc private func quitClicked() {
        if routeKeyToComposingEditor() { return }
        requestQuit()
    }

    private func requestQuit() {
        guard !gate.isMutating else { NSSound.beep(); return }
        if draft.isDirty, let window {
            let alert = NSAlert()
            alert.messageText = "Quit without installing?"
            alert.informativeText = "Your entries will be discarded and OMP Usage will not be installed."
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Quit")
            alert.beginSheetModal(for: window) { response in if response == .alertSecondButtonReturn { NSApp.terminate(nil) } }
            return
        }
        NSApp.terminate(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestQuit()
        return false
    }

    @objc private func installClicked() {
        if routeKeyToComposingEditor() { return }
        window?.endEditing(for: nil)
        guard !gate.isMutating, let request = draft.request(sourceAppPath: sourceAppPath, hostPid: Int(ProcessInfo.processInfo.processIdentifier)) else { render(); return }
        failureMessage = nil
        gate.beginMutation()
        render()
        runner.run(command: .install, ompPath: draft.ompPath, helperPath: helperPath, request: request, timeout: SetupRunner.installNoticeDelay, onStillRunning: { [weak self] in
            guard let self, self.gate.isMutating else { return }
            self.installTakingLong = true; self.render()
        }) { [weak self] result in
            self?.installFinished(result)
        }
    }

    private func installFinished(_ result: Result<SetupSuccess, SetupFailure>) {
        installTakingLong = false
        let quitDeferred = gate.endMutation()
        switch result {
        case .success(let success) where success.action != .continue:
            // The managed job (or the verified running one) owns the panel now; this bootstrap only exits.
            if success.action == .activate, let pid = success.pid { NSRunningApplication(processIdentifier: pid_t(pid))?.activate(options: []) }
            NSApp.terminate(nil)
        case .success:
            failureMessage = SetupFailure(code: "invalid-response").userMessage
        case .failure(let failure):
            failureMessage = failure.userMessage
        }
        render()
        if quitDeferred { NSApp.terminate(nil) }
    }
}
