import AppKit

enum UpdateNoticeChoice: Equatable {
    case updateNow(enableAutomaticInstallation: Bool)
    case skipThisVersion
    case later
    case turnOffNotifications
}

/// Nonmodal, nonactivating notice for a scheduled update discovery. It never becomes key or main, never activates the
/// app, never installs a default (Return) or cancel (Escape) key equivalent, and is ordered front without stealing
/// focus. Closing the window is the same as Later.
final class UpdateNoticeWindowController: NSObject, NSWindowDelegate {
    private final class NoticePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Delivered on the main thread, at most once per presentation.
    var choiceMade: ((UpdateNoticeChoice) -> Void)?

    private let panel: NoticePanel
    private let headline = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let notesView = NSTextView()
    private let notesLink = NSButton(title: "Open Release Notes in Browser", target: nil, action: nil)
    private let automaticCheckbox = NSButton(checkboxWithTitle: "Also install future updates automatically", target: nil, action: nil)
    private var notesURL: URL?
    private var resolved = false
    private(set) var presentedVersion: String?

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = NoticePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        super.init()
        panel.title = "OMP Usage Panel Update"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        panel.contentView = buildContent()
    }

    private func buildContent() -> NSView {
        headline.font = .boldSystemFont(ofSize: 14)
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 12)

        notesView.isEditable = false
        notesView.isSelectable = true
        notesView.drawsBackground = false
        notesView.textContainerInset = NSSize(width: 6, height: 6)
        notesView.font = .systemFont(ofSize: 12)
        notesView.isVerticallyResizable = true
        notesView.isHorizontallyResizable = false
        notesView.autoresizingMask = [.width]
        notesView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = notesView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true

        notesLink.target = self
        notesLink.action = #selector(openNotes)
        notesLink.bezelStyle = .inline
        notesLink.isBordered = false
        notesLink.contentTintColor = .linkColor
        notesLink.isHidden = true

        automaticCheckbox.setAccessibilityLabel("Install future updates automatically after this update")

        func button(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.keyEquivalent = ""  // no unsolicited Return/Escape handling
            return button
        }
        let turnOff = button("Turn Off Notifications", #selector(turnOffClicked))
        let skip = button("Skip This Version", #selector(skipClicked))
        let later = button("Later", #selector(laterClicked))
        let updateNow = button("Update Now", #selector(updateNowClicked))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [turnOff, spacer, skip, later, updateNow])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [headline, detail, scroll, notesLink, automaticCheckbox, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [scroll, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        for view in [headline, detail] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        return stack
    }

    /// Shows (or refreshes) the notice without activating the app or taking key focus.
    func present(candidate: UpdateCandidate, installedVersion: String, automaticInstallationEnabled: Bool) {
        resolved = false
        presentedVersion = candidate.version
        headline.stringValue = "OMP Usage Panel \(candidate.version) is available"
        var line = "You have \(installedVersion)."
        if let date = candidate.publishedAt { line += " Published \(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none))." }
        detail.stringValue = line
        setNotes(candidate.notesText, url: candidate.notesURL)
        automaticCheckbox.state = automaticInstallationEnabled ? .on : .off
        automaticCheckbox.isEnabled = !automaticInstallationEnabled
        if automaticInstallationEnabled { automaticCheckbox.title = "Future updates already install automatically" }
        else { automaticCheckbox.title = "Also install future updates automatically" }
        panel.contentView?.layoutSubtreeIfNeeded()
        let fitting = panel.contentView?.fittingSize ?? NSSize(width: 440, height: 360)
        panel.setContentSize(NSSize(width: 440, height: max(fitting.height, 300)))
        if !panel.isVisible { position() }
        panel.orderFrontRegardless()
    }

    /// Programmatic dismissal. Does not report a choice.
    func dismiss() {
        resolved = true
        presentedVersion = nil
        panel.orderOut(nil)
    }

    private func setNotes(_ text: String?, url: URL?) {
        notesURL = url
        notesLink.isHidden = url == nil
        let body = (text?.isEmpty == false) ? text! : "No release notes were included with this update."
        notesView.string = body
        notesView.textColor = .labelColor
    }

    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { panel.center(); return }
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 16, y: area.maxY - size.height - 16))
    }

    private func finish(_ choice: UpdateNoticeChoice) {
        guard !resolved else { return }
        resolved = true
        panel.orderOut(nil)
        presentedVersion = nil
        choiceMade?(choice)
    }

    @objc private func openNotes() { if let url = notesURL, url.scheme?.lowercased() == "https" { NSWorkspace.shared.open(url) } }
    @objc private func updateNowClicked() { finish(.updateNow(enableAutomaticInstallation: automaticCheckbox.isEnabled && automaticCheckbox.state == .on)) }
    @objc private func skipClicked() { finish(.skipThisVersion) }
    @objc private func laterClicked() { finish(.later) }
    @objc private func turnOffClicked() { finish(.turnOffNotifications) }

    /// Window close (title-bar button) is Later.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.later)
        return false
    }
}

/// Nonmodal, nonactivating progress and cancel surface for downloads, verification and the wait before cutover. Like
/// the notice it never becomes key or main, never activates the app and installs no default/cancel key equivalents.
final class UpdateProgressWindowController: NSObject {
    private final class ProgressPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let panel: ProgressPanel
    private let headline = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var cancelAction: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = ProgressPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
                              styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.title = "OMP Usage Panel Update"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true

        headline.font = .boldSystemFont(ofSize: 13)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .regular
        bar.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = ""
        let buttons = NSStackView(views: [NSView(), cancelButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [headline, bar, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [headline, bar, detail, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        panel.contentView = stack
    }

    /// Shows or refreshes the panel without activating the app. `fraction == nil` is indeterminate. A nil `cancel`
    /// disables the Cancel button (the stage cannot be canceled).
    func show(title: String, detail text: String, fraction: Double?, cancel: (() -> Void)?) {
        headline.stringValue = title
        detail.stringValue = text
        if let fraction {
            bar.isIndeterminate = false
            bar.stopAnimation(nil)
            bar.doubleValue = min(1, max(0, fraction))
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
        cancelAction = cancel
        cancelButton.isEnabled = cancel != nil
        if !panel.isVisible {
            panel.contentView?.layoutSubtreeIfNeeded()
            let fitting = panel.contentView?.fittingSize ?? NSSize(width: 400, height: 150)
            panel.setContentSize(NSSize(width: 400, height: max(fitting.height, 130)))
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let area = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 16, y: area.maxY - panel.frame.height - 16))
            } else { panel.center() }
        }
        panel.orderFrontRegardless()
    }

    func dismiss() {
        bar.stopAnimation(nil)
        cancelAction = nil
        panel.orderOut(nil)
    }

    @objc private func cancelClicked() {
        let action = cancelAction
        cancelAction = nil
        cancelButton.isEnabled = false
        action?()
    }
}
