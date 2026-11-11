import AppKit
import Sparkle

/// One retained updater per app lifetime, independent of usage-configuration generations. Sparkle (standard
/// transport, EdDSA-signed feed and archive verification, scheduled automatic checks) does the update work; this object
/// adds the app-specific policy (notifications, Skip/Later, the explicit automatic-installation consent), the nonmodal
/// notice and nonactivating progress/cancel panel, installation ownership through the bundled Node `update-ownership.mjs`,
/// and safe cutover timing.
///
/// SDK lifetime (Sparkle 2.10.1): `SPUUpdater.applicationBundle` is the RUNNING host app, because Sparkle's installer
/// waits for that bundle's process to terminate. `updaterShouldRelaunchApplication` returns false: the SDK then aborts
/// any `installWithToolAndRelaunch` request (an `.install` reply at the ready callback), so that reply is never used.
/// The FINAL handoff is Sparkle's documented prepared install-on-quit: after the helper's `authorize`, the ready (or resumed
/// `.installing`) reply is `.dismiss`, which keeps the prepared installer waiting for this host process; the app then
/// terminates itself (authorized, `handedOff`) and the independently armed, trusted, copied watcher started by `prepare`
/// restarts the verified LaunchAgent. Sparkle never reopens the app. Cancellation (`.skip`, download cancel) is a one-way
/// message plus a local abort in the SDK, so a dismissal or cycle end proves nothing: the prepared transaction is kept and
/// Quit stays held until the helper's `abort` reports positive evidence that the installer job is gone.
/// Sparkle's silent automatic-download driver is disabled in Info.plist: every installation, manual or automatic, runs
/// through the normal user-driver pipeline and is prepared AND armed before any install-capable reply (a host that quits
/// during download/extraction is installed silently, with no ready callback).
///
/// Everything runs on the main thread.
final class UpdaterCoordinator: NSObject, SPUUpdaterDelegate {
    static let errorDomain = "com.dhkim.omp-usage-panel.update"
    private enum GateErrorCode: Int { case skipped = 1, deferred = 2, blocked = 3, cancelling = 4 }
    static let stillCancellingMessage = "An earlier update is still being cancelled safely. Try again in a moment."

    // MARK: Public surface

    private(set) var policy: UpdatePolicy
    private(set) var status: UpdateStatus
    var statusChanged: ((UpdateStatus) -> Void)?
    var policyChanged: ((UpdatePolicy) -> Void)?
    /// Full presentation guard (Settings visible/minimized, sheets, menus, drag, held mouse, expanded panel): notice and
    /// automatic start. false/unset = never.
    var canPresentNotice: (() -> Bool)?
    /// True when replacing and restarting the app is safe. `explicit` = the user pressed Update Now for this release:
    /// the narrow unsaved-work guard applies (a clean open Settings window is fine). `false` = automatic installation:
    /// the full presentation guard applies. Unset = explicit allowed, automatic refused.
    var canInstallUpdate: ((_ explicit: Bool) -> Bool)?
    /// Sparkle wants its update UI in focus (e.g. the user checked again while an update is in progress).
    var showUpdatesRequested: (() -> Void)?

    // MARK: Collaborators and state

    private var config: PanelConfig
    private var configPath: String
    /// The current Sparkle session has begun downloading/installing (errors then also use Sparkle's standard alert).
    private var pastDownload = false
    private let hostBundle: Bundle
    private let store: UpdatePreferencesStore
    /// Host defaults Sparkle itself uses (`SUDefaultsDomain` suite or standard).
    private let sparkleDefaults: UserDefaults
    /// Sparkle's own reader/writer of the persisted automatic-check preference (host defaults, then Info.plist).
    private let settings: SPUUpdaterSettings
    private let now: () -> Date
    private let notice = UpdateNoticeWindowController()
    private let progress = UpdateProgressWindowController()
    private var ownership: UpdateOwnershipRunner

    private var updater: SPUUpdater?
    private var driver: UpdateUserDriver?

    private var started = false
    private var stopped = false
    private var generation = 0
    private enum Acknowledgement { case notRequested, inFlight, finished }
    private var acknowledgement: Acknowledgement = .notRequested
    private var startAfterAcknowledgement = false

    private var candidate: UpdateCandidate?
    private var noticePending = false
    private var checkOrigin: UpdateCheckOrigin = .scheduled
    /// Changes whenever a new Sparkle discovery begins; stale asynchronous completions are recognized by it.
    private var sessionRevision = 0
    /// In-memory one-off Update Now authorization. Never persisted; never implies automatic installation.
    private var authorizedVersion: String?
    /// A Sparkle install-capable reply being held (ready-to-install callback, or a resumed `.installing` found callback).
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    /// `readyReply` came from the found-update callback of an armed `.installing` session (a skip there records a Sparkle skip).
    private var heldIsFoundStage = false
    private var heldFoundBuild: String?
    /// Release whose installation is driven by the saved automatic-installation consent (not by Update Now).
    private var automaticVersion: String?
    /// Sparkle's real download cancellation (only valid while its download runs).
    private var cancelDownload: (() -> Void)?
    /// Consent was withdrawn while extraction runs (the SDK cannot cancel it): cancel at the ready callback and keep the app running until then.
    private var cancelWhenReady = false
    private var autoStartPending = false
    private var autoStartTimer: Timer?
    private var handedOff = false
    private var modalAlertVisible = false

    /// A `.skip` reply cancelling an install-capable session was sent; the SDK session has not ended yet.
    private var cancelReplyInFlight = false
    /// The prepared transaction must be aborted once the SDK session that could install it has ended.
    private var abortAfterSessionEnd = false
    /// Prepared transactions whose Sparkle session ended and that must still be aborted. A UI dismissal is not proof the
    /// installer is cancelled, so each stays queued (holding Quit) until `abort` reports positive evidence.
    private var pendingAborts: Set<String> = []
    private var abortInFlight = false
    private var abortRetryTimer: Timer?
    private var handoffTerminateTimer: Timer?
    /// A resumed armed `.installing` session is not yet prepared/decided.
    private var armedSessionUnresolved = false
    /// Sparkle recorded a skip because we cancelled an armed session; the user never chose it, so it is removed afterwards.
    private var clearSparkleSkipBuild: String?
    private var terminationPending = false
    private var terminationTimer: Timer?
    /// We replied `.install` at the found callback and Sparkle has not yet reached its ready callback or ended.
    private var installReplySent = false
    /// The user asked to quit while an install-capable session was live: every consent is void until that session ends.
    private var quitRequested = false
    /// `authorize` is running: the final handoff is being committed; nothing else may start an install meanwhile.
    private var handoffInFlight = false

    private enum Preparation { case preparing([(Bool) -> Void]), prepared(String) }
    private var preparations: [String: Preparation] = [:]
    private var lastPreparationFailure: String?

    private var expectedContentLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    private var lastPublishedPercent = -1

    private var retryTimer: Timer?
    private var reminderTimer: Timer?

    // MARK: Lifecycle

    /// `defaults == nil` follows Sparkle's own domain semantics: the host bundle's `SUDefaultsDomain` suite when it names
    /// one (so app-owned metadata and Sparkle's preferences always share one domain), otherwise the standard defaults.
    init(config: PanelConfig, configPath: String, defaults: UserDefaults? = nil, hostBundle: Bundle = .main, now: @escaping () -> Date = Date.init) {
        self.config = config
        self.configPath = configPath
        self.hostBundle = hostBundle
        self.now = now
        let resolvedDefaults: UserDefaults
        if let defaults { resolvedDefaults = defaults }
        else if let suite = hostBundle.object(forInfoDictionaryKey: "SUDefaultsDomain") as? String, !suite.isEmpty, let named = UserDefaults(suiteName: suite) { resolvedDefaults = named }
        else { resolvedDefaults = .standard }
        self.sparkleDefaults = resolvedDefaults
        let preferences = UpdatePreferencesStore(defaults: resolvedDefaults)
        self.store = preferences
        let sparkleSettings = SPUUpdaterSettings(hostBundle: hostBundle)
        self.settings = sparkleSettings
        self.ownership = UpdateOwnershipRunner(nodePath: config.nodePath, hostBundle: hostBundle, appPath: hostBundle.bundleURL.path, configPath: configPath)
        let installed = (hostBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The persisted Sparkle preference is read before any editable policy is exposed: no provisional default.
        self.policy = UpdatePolicy(automaticChecks: sparkleSettings.automaticallyChecksForUpdates, automaticInstallation: preferences.preferences.automaticInstallation,
                                   notificationsEnabled: preferences.preferences.notificationsEnabled)
        self.status = UpdateStatus.initial(installedVersion: installed)
        super.init()
        notice.choiceMade = { [weak self] choice in self?.noticeChoice(choice) }
    }

    deinit { stop() }

    private var acknowledgeStartedAt: Date?
    private var acknowledgeRetryTimer: Timer?

    /// Called once at launch, before `start()`, after the configuration loaded and the controller started. Commits a
    /// just-installed update through the ownership helper. Never blocks or fails startup: attempts run off the main thread
    /// and a recoverable outcome (busy helper, SDK installer still quiescing, `committed:false,pending:true`) is retried
    /// every second until the helper's own readiness window (45 s) ends, so a healthy replacement is not rolled back for a
    /// transient condition. A permanent ownership failure stops at once. Sparkle starts only after this has resolved.
    func acknowledgeStartup() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard acknowledgement == .notRequested else { return }
        acknowledgement = .inFlight
        let version = status.installedVersion
        guard !version.isEmpty else { finishAcknowledgement(); return }
        acknowledgeStartedAt = now()
        runAcknowledgeAttempt(version: version)
    }

    private func runAcknowledgeAttempt(version: String) {
        let token = generation
        let runner = ownership
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = runner.run(UpdateOwnershipAckResponse.self, command: "acknowledge", extra: ["version": version])
            DispatchQueue.main.async {
                // `stop()` bumps the generation: a stopped coordinator neither retries nor starts Sparkle.
                guard let self, self.generation == token, !self.stopped else { return }
                let elapsed = self.now().timeIntervalSince(self.acknowledgeStartedAt ?? self.now())
                switch UpdateAckOutcome.next(result, elapsed: elapsed) {
                case .finished:
                    self.finishAcknowledgement()
                case .retry:
                    if self.started, elapsed >= 2 { self.publish(self.status.with(message: "Confirming the installed update…")) }
                    self.acknowledgeRetryTimer?.invalidate()
                    self.acknowledgeRetryTimer = Timer.scheduledTimer(withTimeInterval: UpdateAckOutcome.retryInterval, repeats: false) { [weak self] _ in
                        self?.acknowledgeRetryTimer = nil
                        self?.runAcknowledgeAttempt(version: version)
                    }
                }
            }
        }
    }

    private func finishAcknowledgement() {
        acknowledgement = .finished
        if startAfterAcknowledgement { startAfterAcknowledgement = false; beginOwnershipGate() }
    }

    /// Starts the updater: acknowledge first (requested here if the host did not), then verify ownership, then Sparkle.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true
        stopped = false
        if status.installedVersion.isEmpty {
            publish(status.with(phase: .unsupported, message: "This copy of OMP Usage Panel has no version number, so it cannot be updated automatically. Reinstall it with the installer.", canInstall: false))
            return
        }
        store.clearHolds(forInstalledVersion: status.installedVersion)
        publish(status.with(phase: .idle, message: "Preparing update checks…", lastSkippedVersion: .some(store.preferences.skippedVersion)))
        if acknowledgement == .notRequested { acknowledgeStartup() }
        if acknowledgement == .inFlight { startAfterAcknowledgement = true } else { beginOwnershipGate() }
    }

    /// Stops background work. Never changes persisted policy and never touches an installer already handed off to
    /// Sparkle or the armed watcher (independent processes).
    func stop() {
        guard !stopped else { return }
        stopped = true
        started = false
        generation &+= 1
        retryTimer?.invalidate(); retryTimer = nil
        acknowledgeRetryTimer?.invalidate(); acknowledgeRetryTimer = nil
        autoStartTimer?.invalidate(); autoStartTimer = nil
        reminderTimer?.invalidate(); reminderTimer = nil
        terminationTimer?.invalidate(); terminationTimer = nil
        notice.dismiss()
        noticePending = false
        startAfterAcknowledgement = false
    }

    /// Node path changes update the ownership runtime context; profile and other collector changes do not touch policy.
    func updateRuntime(config: PanelConfig, configPath: String) {
        self.config = config
        self.configPath = configPath
        ownership = UpdateOwnershipRunner(nodePath: config.nodePath, hostBundle: hostBundle, appPath: hostBundle.bundleURL.path, configPath: configPath)
    }

    // MARK: Termination guard

    /// A Sparkle session that would silently install when the app quits is live.
    private var installCapable: Bool { !handedOff && (installReplySent || readyReply != nil || cancelDownload != nil) }

    private var preparationInFlight: Bool {
        preparations.values.contains { if case .preparing = $0 { return true } else { return false } }
    }

    private var sessionFlags: UpdateSessionFlags {
        UpdateSessionFlags(handedOff: handedOff, installCapable: installCapable, withdrawnDuringExtraction: cancelWhenReady,
                           cancellationUnresolved: cancelReplyInFlight || abortAfterSessionEnd || !pendingAborts.isEmpty || abortInFlight,
                           armedSessionUnresolved: armedSessionUnresolved || preparationInFlight)
    }

    /// AppKit `applicationShouldTerminate`. ONLY the final authorized handoff to Sparkle's installer (`handedOff`)
    /// terminates while an update is in play. An ordinary Quit before that is a cancellation request, not Sparkle's
    /// implicit install-on-quit and not a restart: a running download is cancelled through Sparkle, a held ready reply is
    /// answered with a skip, and extraction (which the SDK cannot cancel) keeps the app running (`terminateLater`) until
    /// its ready callback is skipped and the prepared transaction is aborted. This holds even if automatic installation
    /// consent still exists. It never fails open: on the deadline the quit is declined and the app and its lease stay
    /// alive until the SDK has really cancelled; Quit can then be retried.
    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        var first = UpdateEligibility.termination(sessionFlags)
        if first == .allow && !handedOff {
            // Nothing can install, but a leftover prepared transaction must still be aborted (with installer proof) before leaving.
            abortPreparations()
            first = UpdateEligibility.termination(sessionFlags)
        }
        guard first != .allow else { return .terminateNow }
        if first == .cancelAndHold {
            cancelInstallForQuit()
            if UpdateEligibility.termination(sessionFlags) == .allow { return .terminateNow }
        }
        terminationPending = true
        terminationTimer?.invalidate()
        terminationTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            guard let self, self.terminationPending else { return }
            self.terminationPending = false
            self.terminationTimer = nil
            self.publishStillCancelling()
            NSApp.reply(toApplicationShouldTerminate: false)
        }
        return .terminateLater
    }

    private func publishStillCancelling() {
        publish(status.with(message: "Quit is waiting for the pending update to be cancelled safely. The app stays open; choose Quit again in a moment."))
    }

    private func releaseTerminationIfPossible() {
        guard terminationPending, UpdateEligibility.termination(sessionFlags) == .allow else { return }
        terminationPending = false
        terminationTimer?.invalidate(); terminationTimer = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Starts cancelling whatever install-capable stage is live, at its real cancel point.
    private func cancelInstallForQuit() {
        quitRequested = true
        autoStartPending = false
        autoStartTimer?.invalidate(); autoStartTimer = nil
        if readyReply != nil {
            cancelPendingInstall(message: "Quit canceled the pending update. Nothing was changed.")
        } else if let cancel = cancelDownload {
            authorizedVersion = nil
            automaticVersion = nil
            cancelDownload = nil
            cancel()
        } else if installReplySent {
            // Sparkle is between our install reply and its download callback, or extracting (not cancellable): resolve at
            // the next real cancel point while the app keeps running.
            cancelWhenReady = true
        }
        // A preparation or found decision still in flight sees `quitRequested` when it completes and cancels.
    }

    // MARK: Ownership gate and Sparkle start

    private func beginOwnershipGate() {
        let token = generation
        let runner = ownership
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = runner.run(UpdateOwnershipStatusResponse.self, command: "status", extra: [:])
            DispatchQueue.main.async {
                guard let self, self.generation == token, !self.stopped else { return }
                self.ownershipResolved(result)
            }
        }
    }

    private func ownershipResolved(_ result: Result<UpdateOwnershipStatusResponse, UpdateOwnershipFailure>) {
        switch result {
        case .failure(let failure):
            publish(status.with(phase: .unsupported, message: "Automatic updates are unavailable: \(failure.displayText)", canInstall: false))
        case .success(let state):
            guard state.managed else {
                let reason = UpdateOwnershipCodec.sanitizedMessage(state.reason, fallback: "This copy was not installed by the OMP Usage Panel installer.")
                publish(status.with(phase: .unsupported, message: "Automatic updates are unavailable: \(reason)", canInstall: false))
                return
            }
            startSparkle(outcome: state.outcome)
        }
    }

    private func startSparkle(outcome: UpdateOwnershipOutcome?) {
        let driver = UpdateUserDriver(hostBundle: hostBundle, coordinator: self)
        // The application bundle is the running host: Sparkle's installer waits for ITS termination.
        let updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle, userDriver: driver, delegate: self)
        do { try updater.start() } catch {
            publish(status.with(phase: .failed, message: "Automatic updates could not start: \(UpdateOwnershipCodec.sanitizedMessage(error.localizedDescription, fallback: "Sparkle reported a configuration error."))", canInstall: false))
            return
        }
        self.driver = driver
        self.updater = updater
        // Sparkle's silent automatic driver can neither be vetoed nor made visible, so it is never used
        // (SUAllowsAutomaticUpdates=false). The automatic-installation consent is app-owned and drives the normal pipeline.
        if updater.automaticallyDownloadsUpdates { updater.automaticallyDownloadsUpdates = false }
        var message = "Update checks are ready."
        var phase = UpdatePhase.idle
        if let outcome, store.markOutcomeShown(outcome.transactionId) {
            message = UpdateMessages.outcome(outcome, installed: status.installedVersion)
            phase = UpdateMessages.outcomeIsProblem(outcome) ? .failed : .idle
        }
        publish(status.with(phase: phase, message: message, lastCheckedAt: .some(updater.lastUpdateCheckDate), canInstall: false, lastSkippedVersion: .some(store.preferences.skippedVersion)))
        refreshPolicy()
    }

    // MARK: Policy

    /// Commits the user's update choices. Automatic CHECKS are Sparkle's own preference (written through Sparkle's API,
    /// never duplicated here); the notification choice and the explicit automatic-installation consent live in the
    /// app-wide preference blob and are independent of each other. Withdrawing automatic installation cancels any queued or
    /// in-flight automatic installation that has not yet replaced the app.
    func applyPolicy(_ requested: UpdatePolicy) {
        dispatchPrecondition(condition: .onQueue(.main))
        store.setNotificationsEnabled(requested.notificationsEnabled, now: now())
        store.setAutomaticInstallation(requested.automaticInstallation, now: now())
        if let updater {
            if updater.automaticallyChecksForUpdates != requested.automaticChecks { updater.automaticallyChecksForUpdates = requested.automaticChecks }
        } else if settings.automaticallyChecksForUpdates != requested.automaticChecks {
            settings.automaticallyChecksForUpdates = requested.automaticChecks
        }
        refreshPolicy()
        if !requested.automaticInstallation { cancelAutomaticPipeline() }
        if !policy.notificationsEnabled { notice.dismiss(); noticePending = false }
        considerNotice()
        if status.phase == .readyToInstall { attemptCutover() }
    }

    private func refreshPolicy() {
        let refreshed = UpdatePolicy(automaticChecks: updater?.automaticallyChecksForUpdates ?? settings.automaticallyChecksForUpdates,
                                     automaticInstallation: store.preferences.automaticInstallation,
                                     notificationsEnabled: store.preferences.notificationsEnabled)
        guard refreshed != policy else { return }
        policy = refreshed
        policyChanged?(refreshed)
    }

    // MARK: User actions

    /// Explicit user check. Always allowed (even with automatic checks and notifications off); bypasses Skip/Later and
    /// never changes policy. Reports inline through `statusChanged`; no popup.
    func checkForUpdates() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let updater else {
            if status.phase == .stopped || status.phase == .idle {
                publish(status.with(message: "Update checks are still starting. Try again in a moment."))
            }
            return
        }
        if cancellationResolving {
            publish(status.with(message: Self.stillCancellingMessage))
            return
        }
        guard updater.canCheckForUpdates else {
            publish(status.with(message: "An update check or download is already in progress."))
            return
        }
        checkOrigin = .manual
        noticePending = false
        notice.dismiss()
        if !updater.sessionInProgress { publish(status.with(phase: .checking, message: "Checking for updates…", canInstall: false)) }
        updater.checkForUpdates()
    }

    /// Update Now from Settings. Authorizes only this release, once. Refuses (with `installBlocked`) when installing
    /// would discard unsaved work.
    func installAvailableUpdate() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard updater != nil, let candidate, candidate.isInstallable else {
            publish(status.with(message: candidate?.blockedReason ?? "There is no installable update. Check for updates first.", canInstall: false))
            return
        }
        guard canInstallUpdate?(true) ?? true else {
            publish(status.with(message: UpdateStatus.installBlockedMessage, installBlocked: true))
            return
        }
        beginAuthorizedInstall(candidate)
    }

    /// Host interaction state became safe: re-evaluate a pending notice, a waiting automatic start or a waiting cutover.
    func interactionBecameSafe() {
        dispatchPrecondition(condition: .onQueue(.main))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started, !self.stopped else { return }
            self.considerNotice()
            self.kickAutomaticStart()
            if self.status.phase == .readyToInstall { self.attemptCutover() }
        }
    }

    private func beginAuthorizedInstall(_ candidate: UpdateCandidate) {
        authorizedVersion = candidate.version
        store.recordUpdateNow(version: candidate.version, now: now())
        noticePending = false
        notice.dismiss()
        switch status.phase {
        case .readyToInstall:
            attemptCutover()
        case .downloading, .extracting, .installing:
            break
        default:
            guard let updater, updater.canCheckForUpdates else {
                publish(status.with(message: "An update check is already in progress. Choose Update Now again when it finishes."))
                authorizedVersion = nil
                return
            }
            checkOrigin = .manual
            publish(status.with(phase: .checking, message: "Starting the download of version \(candidate.version)…", canInstall: false))
            updater.checkForUpdates()
        }
    }

    // MARK: Notice

    private func noticeChoice(_ choice: UpdateNoticeChoice) {
        guard let candidate else { return }
        noticePending = false
        switch choice {
        case .updateNow(let enableAutomaticInstallation):
            if enableAutomaticInstallation {
                applyPolicy(UpdatePolicy(automaticChecks: true, automaticInstallation: true, notificationsEnabled: policy.notificationsEnabled))
            }
            beginAuthorizedInstall(candidate)
        case .skipThisVersion:
            store.skip(version: candidate.version, now: now())
            publish(status.with(availableVersion: .some(nil), phase: .idle, message: UpdateMessages.skipped(version: candidate.version), canInstall: false,
                                lastSkippedVersion: .some(candidate.version)))
        case .later:
            let until = store.deferVersion(candidate.version, now: now())
            scheduleReminder(at: until)
            publishAvailable(candidate)
        case .turnOffNotifications:
            store.setNotificationsEnabled(false, now: now())
            refreshPolicy()
            publishAvailable(candidate)
        }
    }

    /// Presents the notice only when every rule holds at this moment; otherwise keeps it pending and retries.
    private func considerNotice() {
        guard noticePending, let candidate, status.phase == .available, !stopped else { return }
        let show = UpdateEligibility.shouldPresentNotice(
            candidate: candidate, origin: .scheduled, policy: policy, preferences: store.preferences, now: now(),
            hostAllowsPresentation: hostAllowsPresentation,
            alreadyShowing: notice.isVisible && notice.presentedVersion == candidate.version)
        if show {
            notice.present(candidate: candidate, installedVersion: status.installedVersion, automaticInstallationEnabled: policy.automaticInstallation)
            retryTimer?.invalidate(); retryTimer = nil
            return
        }
        if notice.isVisible && notice.presentedVersion == candidate.version { return }
        // Wait for the host to become safe, or for a Later deferral to lapse.
        let disposition = UpdateEligibility.scheduledDisposition(version: candidate.version, policy: policy, preferences: store.preferences, now: now())
        if case .suppressed(.deferred(let until)) = disposition {
            scheduleReminder(at: until)
        } else if case .notify = disposition {
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.retryTimer = nil
            self.considerNotice()
        }
    }

    private func scheduleReminder(at date: Date) {
        reminderTimer?.invalidate()
        let interval = max(1, date.timeIntervalSince(now()) + 1)
        reminderTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.reminderTimer = nil
            self.noticePending = self.candidate != nil
            self.considerNotice()
        }
    }

    // MARK: Status helpers

    private func publish(_ new: UpdateStatus) {
        guard new != status else { return }
        status = new
        statusChanged?(new)
    }

    private func publishAvailable(_ candidate: UpdateCandidate) {
        let suppression = store.preferences.suppression(for: candidate.version, now: now())
        let message = candidate.isInstallable
            ? UpdateMessages.available(version: candidate.version, installed: status.installedVersion, suppression: suppression,
                                       formatter: { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) })
            : (candidate.blockedReason ?? "Version \(candidate.version) cannot be installed.")
        publish(status.with(availableVersion: .some(candidate.version), phase: .available, message: message, lastCheckedAt: .some(now()),
                            canInstall: candidate.isInstallable, lastSkippedVersion: .some(store.preferences.skippedVersion)))
    }

    private func makeCandidate(_ item: SUAppcastItem) -> UpdateCandidate {
        UpdateCandidate.make(
            version: item.displayVersionString, build: item.versionString, properties: item.propertiesDictionary,
            signatureValidated: item.signingValidationStatus == .succeeded, downloadURL: item.fileURL, informationOnly: item.isInformationOnlyUpdate,
            notesText: item.itemDescription, notesFormat: item.itemDescriptionFormat, notesURL: item.releaseNotesURL, publishedAt: item.date)
    }

    private func gateError(_ code: GateErrorCode, _ message: String) -> NSError {
        NSError(domain: Self.errorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private var hostAllowsPresentation: Bool { (canPresentNotice?() ?? false) && !modalAlertVisible }

    // MARK: Ownership preparation (durable receipt + backup + armed independent watcher)

    private func preparationKey(_ candidate: UpdateCandidate) -> String { candidate.version + ":" + (candidate.appTreeSHA256 ?? "") }

    private func isPrepared(_ candidate: UpdateCandidate) -> Bool {
        if case .prepared? = preparations[preparationKey(candidate)] { return true }
        return false
    }

    /// Runs the ownership helper's `prepare` once per release. It creates the durable transaction and arms the trusted
    /// watcher BEFORE returning, so Sparkle must not be allowed to download/extract/install unless this succeeded.
    private func ensurePrepared(_ candidate: UpdateCandidate, completion: @escaping (Bool) -> Void) {
        guard candidate.isInstallable, let hash = candidate.appTreeSHA256 else { completion(false); return }
        let key = preparationKey(candidate)
        switch preparations[key] {
        case .prepared?: completion(true); return
        case .preparing(let waiting)?: preparations[key] = .preparing(waiting + [completion]); return
        case nil: preparations[key] = .preparing([completion])
        }
        // An earlier release's transaction is never dropped without positive abort proof (installer provably gone). It is
        // queued for the proof-gated abort loop (only when its Sparkle session can no longer install) and this preparation
        // is refused for now; the helper allows one live authorization per owner.
        var hasEarlier = false
        for (otherKey, value) in preparations where otherKey != key { if case .prepared = value { hasEarlier = true } }
        if hasEarlier {
            preparations[key] = nil
            if UpdateEligibility.mayDiscardEarlierPreparation(sessionFlags) { abortPreparations() }
            lastPreparationFailure = "An earlier update is still being cleaned up. Try again in a moment."
            completion(false)
            return
        }
        let token = generation
        let runner = ownership
        let installed = status.installedVersion
        let version = candidate.version
        let ownerPid = Int(ProcessInfo.processInfo.processIdentifier)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // (prepare runs only with no earlier transaction outstanding)
            let result = runner.run(UpdateOwnershipPrepareResponse.self, command: "prepare",
                                    extra: ["expectedVersion": version, "expectedAppTreeSHA256": hash, "currentVersion": installed, "ownerPid": ownerPid])
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                var waiting: [(Bool) -> Void] = []
                if case .preparing(let list)? = self.preparations[key] { waiting = list }
                switch result {
                case .success(let prepared) where prepared.armed:
                    self.preparations[key] = .prepared(prepared.transactionId)
                    self.lastPreparationFailure = nil
                    waiting.forEach { $0(true) }
                case .success:
                    self.preparations[key] = nil
                    self.lastPreparationFailure = "The independent restart watcher could not be armed."
                    waiting.forEach { $0(false) }
                case .failure(let failure):
                    self.preparations[key] = nil
                    self.lastPreparationFailure = failure.displayText
                    waiting.forEach { $0(false) }
                }
            }
        }
    }

    /// Installer proof label: Sparkle submits its installer as the user-domain launchd job `<bundle id>-sparkle-updater`
    /// (SUInstallerLauncher). The helper treats the job as gone only when launchd reports it not running.
    private func abortExtra(_ transactionID: String) -> [String: Any] {
        var extra: [String: Any] = ["transactionId": transactionID]
        if let identifier = hostBundle.bundleIdentifier, !identifier.isEmpty { extra["installerLabel"] = identifier + "-sparkle-updater" }
        return extra
    }

    /// Queues every prepared transaction for abort and drives the attempts. Only call once the Sparkle session that could
    /// install it has ended (`sessionEnded`) or Sparkle aborted with an error; never while an install may still proceed.
    private func abortPreparations() {
        guard !handedOff else { return }
        for (key, value) in preparations { if case .prepared(let id) = value { pendingAborts.insert(id); preparations[key] = nil } }
        drivePendingAborts()
    }

    /// Runs `abort` (revoke authorization; discard only with the installer provably not running) for every queued
    /// transaction and retries until each is resolved. Quit stays held (`cancellationUnresolved`) meanwhile; a dismissal
    /// or cycle end alone never releases it.
    private func drivePendingAborts() {
        guard !pendingAborts.isEmpty, !abortInFlight, !handedOff else { return }
        abortInFlight = true
        abortRetryTimer?.invalidate(); abortRetryTimer = nil
        let ids = Array(pendingAborts)
        let runner = ownership
        let extras = ids.map { abortExtra($0) }
        let token = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var resolved: [String] = []
            var unrecoverable = false
            for (id, extra) in zip(ids, extras) {
                let result = runner.run(UpdateOwnershipAbortResponse.self, command: "abort", extra: extra)
                switch UpdateAbortOutcome.classify(result) {
                case .resolved: resolved.append(id)
                case .retry: break
                case .unrecoverable: unrecoverable = true
                }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.abortInFlight = false
                resolved.forEach { self.pendingAborts.remove($0) }
                if self.pendingAborts.isEmpty {
                    self.releaseTerminationIfPossible()
                } else if unrecoverable {
                    // A malformed request cannot be retried into proof. Nothing is released: the transaction and Quit stay held.
                    self.publish(self.status.with(phase: .failed, message: "Cancelling the pending update could not be verified. Quit is held to keep your app safe; restart your Mac or reinstall OMP Usage Panel if this persists."))
                } else {
                    self.abortRetryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                        self?.abortRetryTimer = nil
                        self?.drivePendingAborts()
                    }
                }
            }
        }
    }

    /// The Sparkle session that could have installed ended: now it is safe to abort a cancelled transaction, restore a
    /// skip Sparkle recorded for a release the user never skipped, and let a held quit proceed.
    private func sessionEnded() {
        if !handedOff {
            cancelReplyInFlight = false
            installReplySent = false
            quitRequested = false
            if abortAfterSessionEnd { abortAfterSessionEnd = false; abortPreparations() }
            if let build = clearSparkleSkipBuild {
                clearSparkleSkipBuild = nil
                // Sparkle's documented skip record (SUSkippedVersion in the host defaults) is cleared only when it names the
                // release WE cancelled; a user's own skip of anything else is never touched.
                if sparkleDefaults.string(forKey: "SUSkippedVersion") == build { sparkleDefaults.removeObject(forKey: "SUSkippedVersion") }
            }
        }
        releaseTerminationIfPossible()
    }

    // MARK: Cutover and cancellation

    /// Preparation failed: nothing may be installed. A held Sparkle reply is answered with `.skip`, which cancels the
    /// pending installation without skipping the version.
    private func preparationFailed() {
        let reason = lastPreparationFailure ?? "The installation could not be prepared."
        let pending = readyReply
        readyReply = nil
        authorizedVersion = nil
        automaticVersion = nil
        cancelWhenReady = false
        armedSessionUnresolved = false
        progress.dismiss()
        publish(status.with(phase: .failed, message: "The update was not installed: \(reason) The current app was not changed.", canInstall: candidate?.isInstallable ?? false))
        if let pending {
            cancelReplyInFlight = true
            abortAfterSessionEnd = true
            skipRevokingFirst(pending)
        }
    }

    /// A cancellation (consent withdrawn, Quit, refusal) is still resolving: its Sparkle session, its installer proof or
    /// its transaction abort is outstanding. No new Sparkle session may start meanwhile.
    private var cancellationResolving: Bool { cancelReplyInFlight || abortAfterSessionEnd || !pendingAborts.isEmpty || abortInFlight }

    /// Replies Sparkle's `.skip` (its real cancellation) only AFTER the helper revoked any restart authorization for
    /// every prepared transaction ("revoke" deletes nothing and is durable). A failed revoke does not block the cancel:
    /// the later `abort` always revokes first and is retried until it proves the installer is gone.
    private func skipRevokingFirst(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
        var ids: [String] = []
        for value in preparations.values { if case .prepared(let id) = value { ids.append(id) } }
        guard !ids.isEmpty else { reply(.skip); return }
        let runner = ownership
        DispatchQueue.global(qos: .userInitiated).async {
            for id in ids { _ = runner.run(UpdateOwnershipRevokeResponse.self, command: "revoke", extra: ["transactionId": id]) }
            DispatchQueue.main.async { reply(.skip) }
        }
    }

    /// The FINAL handoff. `prepare` armed the watcher but did not authorize a restart (a plain Quit never restarts the
    /// app). Only here, immediately before the install reply, is the watcher authorized to restart the verified
    /// LaunchAgent once the host has exited and the bundle was authentically replaced. Consent, quit state and safety are
    /// re-checked after that asynchronous step; anything but a clean proceed cancels (skip + abort, which also clears the authorization).
    private func beginHandoff(_ candidate: UpdateCandidate) {
        guard !handoffInFlight, case .prepared(let transactionID)? = preparations[preparationKey(candidate)] else { return }
        handoffInFlight = true
        retryTimer?.invalidate(); retryTimer = nil
        progress.show(title: "Finishing OMP Usage Panel \(candidate.version)", detail: "Committing a safe restart…", fraction: nil, cancel: nil)
        let token = generation
        let runner = ownership
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = runner.run(UpdateOwnershipAuthorizeResponse.self, command: "authorize", extra: ["transactionId": transactionID])
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.handoffInFlight = false
                var refusal: String?
                switch result {
                case .success(let response) where response.authorized: refusal = nil
                case .success(let response): refusal = UpdateOwnershipCodec.sanitizedMessage(response.reason, fallback: "The restart watcher refused the handoff.")
                case .failure(let failure): refusal = failure.displayText
                }
                guard let current = self.candidate, self.readyReply != nil, !self.handedOff, !self.stopped else { return }
                if let refusal {
                    self.lastPreparationFailure = refusal
                    self.preparationFailed()
                    return
                }
                let explicit = self.authorizedVersion == current.version
                let safe = self.canInstallUpdate?(explicit) ?? explicit
                let decision = UpdateEligibility.cutover(version: current.version, authorizedVersion: self.authorizedVersion, policy: self.policy,
                                                         preferences: self.store.preferences, now: self.now(), safeToInstall: safe)
                guard decision == .proceed, !self.quitRequested else {
                    self.cancelPendingInstall(message: "Version \(current.version) was not installed because the app or your consent changed at the last moment. Choose Update Now to install it.")
                    return
                }
                self.handedOff = true
                self.heldIsFoundStage = false
                self.publish(self.status.with(phase: .installing, message: "Installing version \(current.version). OMP Usage Panel will quit and restart.", canInstall: false))
                self.progress.show(title: "Installing OMP Usage Panel \(current.version)", detail: "The app quits and restarts automatically when the installation finishes.", fraction: nil, cancel: nil)
                // Sparkle's `.install` reply cannot be used: with `updaterShouldRelaunchApplication` false the SDK aborts the whole
                // install request. Dismissing a ready (or resumed `.installing`) session keeps the prepared installer waiting for
                // this host process to terminate (documented install-on-quit); the app then terminates itself, authorized, and the
                // armed watcher restarts the verified LaunchAgent. No SDK reopen.
                let reply = self.readyReply
                self.readyReply = nil
                reply?(.dismiss)
                DispatchQueue.main.async { [weak self] in self?.terminateForHandoff(attempt: 1) }
            }
        }
    }

    /// Terminates the app for the committed handoff after the SDK callback unwound. `handedOff` makes
    /// `applicationShouldTerminate` answer terminateNow. If AppKit/another delegate declines, retry, then say how to finish.
    private func terminateForHandoff(attempt: Int) {
        guard handedOff, !stopped else { return }
        NSApp.terminate(nil)
        handoffTerminateTimer?.invalidate()
        handoffTerminateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, self.handedOff else { return }
            if attempt < 3 { self.terminateForHandoff(attempt: attempt + 1) }
            else { self.publish(self.status.with(message: "Version \(self.candidate?.version ?? "") is staged. Quit OMP Usage Panel to finish updating.")) }
        }
    }

    /// Replaces the app when (and only when) consent exists, ownership is prepared and armed, and the host says it is
    /// safe. Explicit Update Now uses the narrow guard; automatic installation the full presentation guard. Consent that
    /// no longer exists cancels instead of waiting.
    private func attemptCutover() {
        guard let candidate, status.phase == .readyToInstall, !handedOff, !stopped, readyReply != nil, isPrepared(candidate) else { return }
        if quitRequested {
            cancelPendingInstall(message: "Quit canceled the pending update. Nothing was changed.")
            return
        }
        let explicit = authorizedVersion == candidate.version
        let safe = canInstallUpdate?(explicit) ?? explicit
        switch UpdateEligibility.cutover(version: candidate.version, authorizedVersion: authorizedVersion, policy: policy,
                                         preferences: store.preferences, now: now(), safeToInstall: safe) {
        case .proceed:
            beginHandoff(candidate)
        case .waitForSafeMoment:
            showWaitingForSafeMoment(candidate)
            scheduleRetryForCutover()
        case .needsUserAction:
            cancelPendingInstall(message: "Version \(candidate.version) was not installed because automatic installation is off or the release is on hold. Choose Update Now to install it.")
        }
    }

    private func showWaitingForSafeMoment(_ candidate: UpdateCandidate) {
        publish(status.with(availableVersion: .some(candidate.version), phase: .readyToInstall,
                            message: "Version \(candidate.version) is ready. It installs and restarts the app as soon as your Settings changes are saved or closed.",
                            canInstall: true))
        progress.show(title: "OMP Usage Panel \(candidate.version) is ready", detail: "It installs and restarts when your Settings changes are saved or closed.",
                      fraction: 1, cancel: { [weak self] in self?.userCanceledPipeline() })
    }

    private func scheduleRetryForCutover() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.retryTimer = nil
            if self.status.phase == .readyToInstall { self.attemptCutover() }
        }
    }

    /// Cancels a held install-capable session with Sparkle's real reply (`.skip` = cancel; from a ready callback it does
    /// not skip the version). The prepared transaction is aborted only after the SDK session has ended.
    private func cancelPendingInstall(message: String) {
        let reply = readyReply
        readyReply = nil
        authorizedVersion = nil
        automaticVersion = nil
        cancelWhenReady = false
        armedSessionUnresolved = false
        retryTimer?.invalidate(); retryTimer = nil
        if heldIsFoundStage { clearSparkleSkipBuild = heldFoundBuild }
        heldIsFoundStage = false
        heldFoundBuild = nil
        abortAfterSessionEnd = true
        progress.dismiss()
        if let candidate {
            publish(status.with(availableVersion: .some(candidate.version), phase: .available, message: message, lastCheckedAt: .some(now()), canInstall: candidate.isInstallable))
        }
        if let reply {
            cancelReplyInFlight = true
            skipRevokingFirst(reply)
        } else {
            sessionEnded()
        }
    }

    /// Cancel from the progress panel: the user's own cancel of whatever stage has a real cancel point.
    private func userCanceledPipeline() {
        authorizedVersion = nil
        automaticVersion = nil
        if readyReply != nil {
            cancelPendingInstall(message: "The installation was canceled. Nothing was changed.")
        } else if let cancel = cancelDownload {
            cancelDownload = nil
            cancel()
        }
    }

    /// Automatic installation was withdrawn: cancel what it queued or started, at the real cancel point of each stage.
    /// An Update Now the user explicitly gave for this release keeps going. Extraction cannot be canceled by the SDK, so
    /// that stage keeps the app running (termination guard) until the ready callback resolves the cancellation.
    private func cancelAutomaticPipeline() {
        autoStartPending = false
        autoStartTimer?.invalidate(); autoStartTimer = nil
        guard let version = automaticVersion, authorizedVersion != version else { return }
        if readyReply != nil {
            cancelPendingInstall(message: "Automatic installation was turned off, so version \(version) was not installed. Choose Update Now to install it.")
        } else if let cancel = cancelDownload {
            automaticVersion = nil
            cancelDownload = nil
            cancel()
        } else {
            cancelWhenReady = true
        }
    }

    private func scheduleAutoStartRetry() {
        guard autoStartTimer == nil else { return }
        autoStartTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.autoStartTimer = nil
            self.kickAutomaticStart()
        }
    }

    /// A scheduled discovery had saved automatic consent but the host was busy. When it is safe, ask Sparkle to run its
    /// scheduled pipeline again so the normal driver (and its visible progress/cancel) performs the download.
    private func kickAutomaticStart() {
        guard autoStartPending, !quitRequested, !stopped, let updater else { return }
        guard policy.automaticChecks, policy.automaticInstallation else { autoStartPending = false; return }
        guard hostAllowsPresentation, !cancellationResolving, updater.canCheckForUpdates, !updater.sessionInProgress else { scheduleAutoStartRetry(); return }
        autoStartPending = false
        updater.checkForUpdatesInBackground()
    }

    // MARK: SPUUpdaterDelegate

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] { [] }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }

    /// Sparkle's own unregistered direct reopen of the app is suppressed: restarting is the job of the independently
    /// armed trusted watcher (it relaunches through the verified LaunchAgent, waits for readiness, then commits or rolls back).
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { false }

    /// No new Sparkle session may start while a cancellation is unresolved (installer proof / transaction abort pending).
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard cancellationResolving else { return }
        if status.phase == .checking { publish(status.with(phase: .idle, message: Self.stillCancellingMessage)) } else { publish(status.with(message: Self.stillCancellingMessage)) }
        throw gateError(.cancelling, Self.stillCancellingMessage)
    }

    /// Release notes come from the signed appcast item itself (or the notice's HTTPS link opened by the user); no extra
    /// network fetch is made on the user's behalf.
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        // No account data or ambient credentials accompany the download request.
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        if candidate?.version != item.displayVersionString { candidate = makeCandidate(item) }
    }

    /// Skip/Later and authenticated-metadata gate. Throwing stops the download and any notice; Sparkle never shows a
    /// scheduled error for it.
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        let found = makeCandidate(updateItem)
        let origin: UpdateCheckOrigin = updateCheck == .updates ? .manual : .scheduled
        checkOrigin = origin
        pastDownload = false
        sessionRevision &+= 1
        candidate = found
        guard found.isInstallable else {
            publishAvailable(found)
            throw gateError(.blocked, found.blockedReason ?? "The update cannot be installed.")
        }
        guard origin == .scheduled else { return }
        switch UpdateEligibility.scheduledDisposition(version: found.version, policy: policy, preferences: store.preferences, now: now()) {
        case .suppressed(.skipped):
            publish(status.with(availableVersion: .some(nil), phase: .idle, message: UpdateMessages.skipped(version: found.version), lastCheckedAt: .some(now()),
                                canInstall: false, lastSkippedVersion: .some(found.version)))
            throw gateError(.skipped, "Version \(found.version) was skipped.")
        case .suppressed(.deferred(let until)):
            publishAvailable(found)
            scheduleReminder(at: until)
            throw gateError(.deferred, "The reminder for version \(found.version) is paused.")
        case .recordOnly, .notify:
            return
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let nsError = error as NSError
        let reasonCode = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber).flatMap { SPUNoUpdateFoundReason(rawValue: OSStatus($0.int32Value)) }
        candidate = nil
        noticePending = false
        notice.dismiss()
        let message: String
        switch reasonCode {
        case .some(.systemIsTooOld): message = "A newer version exists but needs a newer macOS than this Mac runs."
        case .some(.systemIsTooNew): message = "A newer version exists but does not support this macOS yet."
        case .some(.hardwareDoesNotSupportARM64): message = "A newer version exists but does not support this Mac's hardware."
        default: message = UpdateMessages.upToDate(version: status.installedVersion)
        }
        let upToDate = reasonCode == nil || reasonCode == .onLatestVersion || reasonCode == .onNewerThanLatestVersion || reasonCode == .unknown
        publish(status.with(availableVersion: .some(nil), phase: upToDate ? .upToDate : .idle, message: message, lastCheckedAt: .some(now()), canInstall: false,
                            lastSkippedVersion: .some(store.preferences.skippedVersion)))
    }

    /// The user (or withdrawn consent) cancelled the download through Sparkle's real cancellation. The SDK session ends next;
    /// the prepared transaction is aborted then (`sessionEnded`).
    func userDidCancelDownload(_ updater: SPUUpdater) {
        authorizedVersion = nil
        automaticVersion = nil
        cancelDownload = nil
        abortAfterSessionEnd = true
        progress.dismiss()
        if let candidate { publishAvailable(candidate) }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        handedOff = true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        driverError(error: error as NSError)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if !handedOff { authorizedVersion = nil }
        sessionEnded()
        guard status.phase == .checking else { return }
        publish(status.with(phase: .idle, message: "The update check finished.", lastCheckedAt: .some(now()), canInstall: false))
    }

    // MARK: Driver callbacks (main thread)

    func driverBeganUserInitiatedCheck(cancellation: @escaping () -> Void) {
        pastDownload = false
        sessionRevision &+= 1
        publish(status.with(phase: .checking, message: "Checking for updates…", canInstall: false))
    }

    private func sessionStage(_ stage: SPUUserUpdateStage) -> UpdateSessionStage {
        switch stage {
        case .notDownloaded: return .notDownloaded
        case .downloaded: return .downloaded
        case .installing: return .installing
        @unknown default: return .installing  // Treat any unknown stage as armed: it must never be silently dismissed.
        }
    }

    /// The live safety answer for the purpose of THIS decision (see `canInstallUpdate`/`canPresentNotice`).
    private func safetyForFound(_ found: UpdateCandidate, stage: UpdateSessionStage) -> Bool {
        let explicit = authorizedVersion == found.version
        if stage == .installing { return canInstallUpdate?(explicit) ?? explicit }
        return explicit ? (canInstallUpdate?(true) ?? true) : hostAllowsPresentation
    }

    private func currentFoundAction(_ found: UpdateCandidate, stage: UpdateSessionStage, userInitiated: Bool) -> UpdateFoundAction {
        // A Quit in progress voids every consent: nothing may install, and an armed session is cancelled.
        if quitRequested { return stage == .installing ? .cancelInstalling : .notify }
        return UpdateEligibility.foundAction(stage: stage, userInitiated: userInitiated, authorizedVersion: authorizedVersion, version: found.version,
                                             policy: policy, preferences: store.preferences, now: now(), safe: safetyForFound(found, stage: stage))
    }

    func driverFoundUpdate(item: SUAppcastItem, userInitiated: Bool, stage sdkStage: SPUUserUpdateStage, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        sessionRevision &+= 1
        let revision = sessionRevision
        let stage = sessionStage(sdkStage)
        let found = makeCandidate(item)
        candidate = found
        guard found.isInstallable else {
            publishAvailable(found)
            if stage == .installing { cancelArmedInstalling(found, message: found.blockedReason ?? "The update cannot be installed.", reply: reply) } else { reply(.dismiss) }
            return
        }
        if stage == .installing { armedSessionUnresolved = true }
        switch currentFoundAction(found, stage: stage, userInitiated: userInitiated) {
        case .notify:
            reply(.dismiss)
            publishAvailable(found)
            if !userInitiated { noticePending = true; considerNotice() }
        case .blocked:
            reply(.dismiss)
            authorizedVersion = nil
            publishAvailable(found)
            publish(status.with(message: UpdateStatus.installBlockedMessage, installBlocked: true))
        case .waitForSafeMoment:
            reply(.dismiss)
            publishAvailable(found)
            autoStartPending = true
            scheduleAutoStartRetry()
        case .cancelInstalling:
            cancelArmedInstalling(found, message: "Version \(found.version) was already staged to install when the app quits, but it is not authorized, so it was canceled. Choose Update Now to install it.", reply: reply)
        case .install, .holdInstalling:
            // Durable prepare + armed watcher FIRST; consent, revision and safety are re-checked afterwards.
            ensurePrepared(found) { [weak self] ok in
                guard let self else { reply(stage == .installing ? .skip : .dismiss); return }
                self.finishFound(found, stage: stage, userInitiated: userInitiated, revision: revision, prepared: ok, reply: reply)
            }
        }
    }

    /// After asynchronous preparation: recompute the decision from the CURRENT consent and safety, then reply.
    private func finishFound(_ found: UpdateCandidate, stage: UpdateSessionStage, userInitiated: Bool, revision: Int, prepared: Bool,
                             reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard prepared else {
            let reason = lastPreparationFailure ?? "The installation could not be prepared."
            authorizedVersion = nil
            automaticVersion = nil
            publish(status.with(phase: .failed, message: "The update was not installed: \(reason) The current app was not changed.", canInstall: found.isInstallable))
            if stage == .installing { cancelArmedInstalling(found, message: nil, reply: reply) } else { reply(.dismiss) }
            return
        }
        // A newer discovery superseded this one while preparing: nothing here may install.
        let current = revision == sessionRevision && !stopped
        let action: UpdateFoundAction = current ? currentFoundAction(found, stage: stage, userInitiated: userInitiated) : (stage == .installing ? .cancelInstalling : .notify)
        switch action {
        case .install:
            armedSessionUnresolved = false
            if authorizedVersion != found.version { automaticVersion = found.version }
            autoStartPending = false
            autoStartTimer?.invalidate(); autoStartTimer = nil
            if stage == .installing {
                // Final handoff: authorize the restart watcher first (attemptCutover -> beginHandoff), then reply.
                readyReply = reply
                heldIsFoundStage = true
                heldFoundBuild = found.build
                publish(status.with(availableVersion: .some(found.version), phase: .readyToInstall, message: "Version \(found.version) is staged. Confirming a safe installation…", canInstall: true))
                attemptCutover()
                return
            }
            publish(status.with(availableVersion: .some(found.version), phase: .downloading,
                                message: "Downloading version \(found.version)\(automaticVersion == found.version ? " (automatic updates)" : "")…", canInstall: false))
            installReplySent = true
            reply(.install)
        case .holdInstalling:
            // Prepared and consented, but not safe yet: keep the armed session's reply until it is (or consent ends).
            armedSessionUnresolved = false
            readyReply = reply
            heldIsFoundStage = true
            heldFoundBuild = found.build
            showWaitingForSafeMoment(found)
            scheduleRetryForCutover()
        case .cancelInstalling:
            cancelArmedInstalling(found, message: "Version \(found.version) was already staged to install when the app quits, but it is no longer authorized, so it was canceled. Choose Update Now to install it.", reply: reply)
        case .notify, .blocked, .waitForSafeMoment:
            // Nothing is armed for a not-yet-downloaded/downloaded session: dismiss, and discard the prepared transaction
            // once this SDK session has ended.
            abortAfterSessionEnd = true
            reply(.dismiss)
            publishAvailable(found)
            if action == .blocked {
                authorizedVersion = nil
                publish(status.with(message: UpdateStatus.installBlockedMessage, installBlocked: true))
            } else if action == .waitForSafeMoment {
                autoStartPending = true
                scheduleAutoStartRetry()
            } else if !userInitiated {
                noticePending = true
                considerNotice()
            }
        }
    }

    /// An already-armed `.installing` session has no live authorization. `.dismiss` would leave it armed to install on
    /// quit, so it is cancelled with Sparkle's real cancellation (a skip). Sparkle then records a skip for a release the
    /// user never skipped; it is removed once the session ends.
    private func cancelArmedInstalling(_ found: UpdateCandidate, message: String?, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        armedSessionUnresolved = false
        authorizedVersion = nil
        automaticVersion = nil
        clearSparkleSkipBuild = found.build
        abortAfterSessionEnd = true
        cancelReplyInFlight = true
        if let message { publishAvailable(found); publish(status.with(message: message)) }
        skipRevokingFirst(reply)
    }

    /// Sparkle reported a failure (idempotent: it reaches both the delegate and the driver). Shown inline only; the
    /// caller acknowledges to Sparkle at once so the installer job can exit and the prepared transaction can be drained.
    func driverError(error: NSError) {
        if error.domain == Self.errorDomain { return }
        if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) { return }
        // Sparkle aborted the session with an error: nothing can install, so the transaction is discarded now.
        handedOff = false
        installReplySent = false
        quitRequested = false
        abortPreparations()
        let afterDownload = pastDownload
        authorizedVersion = nil
        automaticVersion = nil
        cancelDownload = nil
        cancelWhenReady = false
        armedSessionUnresolved = false
        cancelReplyInFlight = false
        readyReply = nil
        progress.dismiss()
        let canceled = error.domain == SUSparkleErrorDomain && error.code == Int(SUError.installationCanceledError.rawValue)
        let detail = UpdateOwnershipCodec.sanitizedMessage(error.localizedDescription, fallback: "Sparkle reported an error.")
        let message = canceled ? "The installation was canceled." : (afterDownload ? "The update failed: \(detail)" : "The update check failed: \(detail)")
        publish(status.with(phase: canceled ? .available : .failed, message: message, lastCheckedAt: .some(now()), canInstall: candidate?.isInstallable ?? false))
        releaseTerminationIfPossible()
    }

    func driverDownloadStarted(cancel: @escaping () -> Void) {
        pastDownload = true
        cancelDownload = cancel
        if cancelWhenReady {
            // Consent was withdrawn or Quit was chosen before the download could be cancelled: cancel it now through Sparkle.
            cancelWhenReady = false
            authorizedVersion = nil
            automaticVersion = nil
            cancelDownload = nil
            cancel()
            return
        }
        expectedContentLength = 0; receivedLength = 0; lastPublishedPercent = -1
        let version = candidate?.version ?? status.availableVersion ?? "the update"
        publish(status.with(phase: .downloading, message: "Downloading version \(version)…", canInstall: false))
        progress.show(title: "Downloading OMP Usage Panel \(version)", detail: "Starting the download…", fraction: nil, cancel: { [weak self] in self?.userCanceledPipeline() })
    }

    func driverExpectedContentLength(_ length: UInt64) { expectedContentLength = length }

    func driverReceivedData(_ length: UInt64) {
        receivedLength += length
        guard expectedContentLength > 0 else { return }
        let fraction = min(1, Double(receivedLength) / Double(expectedContentLength))
        let percent = Int(fraction * 100)
        guard percent != lastPublishedPercent else { return }
        lastPublishedPercent = percent
        let version = candidate?.version ?? ""
        publish(status.with(phase: .downloading, message: "Downloading version \(version)… \(percent)%", canInstall: false))
        progress.show(title: "Downloading OMP Usage Panel \(version)", detail: "\(percent)%", fraction: fraction, cancel: { [weak self] in self?.userCanceledPipeline() })
    }

    func driverExtractionStarted() {
        pastDownload = true
        cancelDownload = nil
        let version = candidate?.version ?? ""
        publish(status.with(phase: .extracting, message: "Verifying and unpacking version \(version)…", canInstall: false))
        progress.show(title: "Verifying OMP Usage Panel \(version)", detail: "Checking the signed download…", fraction: nil, cancel: nil)
    }

    func driverExtractionProgress(_ fraction: Double) {
        let percent = min(100, max(0, Int(fraction * 100)))
        let version = candidate?.version ?? ""
        publish(status.with(phase: .extracting, message: "Verifying and unpacking version \(version)… \(percent)%", canInstall: false))
        progress.show(title: "Verifying OMP Usage Panel \(version)", detail: "\(percent)%", fraction: fraction, cancel: nil)
    }

    func driverReadyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pastDownload = true
        installReplySent = false
        cancelDownload = nil
        guard let candidate, candidate.isInstallable else {
            progress.dismiss()
            publish(status.with(phase: .failed, message: "The downloaded update could not be matched to an authenticated release, so it was not installed.", canInstall: false))
            cancelReplyInFlight = true
            abortAfterSessionEnd = true
            skipRevokingFirst(reply)
            return
        }
        readyReply = reply
        heldIsFoundStage = false
        if cancelWhenReady || quitRequested {
            // The SDK could not cancel extraction; consent was withdrawn or Quit was chosen meanwhile. Resolve it now, with the app still running.
            cancelPendingInstall(message: quitRequested ? "Quit canceled the pending update. Nothing was changed."
                                                        : "Automatic installation was turned off, so version \(candidate.version) was not installed. Choose Update Now to install it.")
            return
        }
        publish(status.with(availableVersion: .some(candidate.version), phase: .readyToInstall, message: "Version \(candidate.version) is downloaded. Preparing a safe installation…", canInstall: true))
        progress.show(title: "Preparing OMP Usage Panel \(candidate.version)", detail: "Backing up the current app before installing…", fraction: nil, cancel: nil)
        // Normally already prepared and armed before extraction began; this covers only a session without that history.
        ensurePrepared(candidate) { [weak self] ok in
            guard let self else { return }
            guard self.readyReply != nil else { if ok { self.abortAfterSessionEnd = true }; return }
            guard ok else { self.preparationFailed(); return }
            self.attemptCutover()
        }
    }

    func driverInstalling(applicationTerminated: Bool) {
        pastDownload = true
        handedOff = true
        publish(status.with(phase: .installing, message: "Installing version \(candidate?.version ?? ""). OMP Usage Panel will restart.", canInstall: false))
    }

    func driverInstalled(relaunched: Bool) {
        publish(status.with(phase: .installing, message: relaunched ? "The update was installed and the app relaunched." : "The update was installed.", canInstall: false))
    }

    func driverDismissed() {
        // Sparkle ended its session; a reply held for it can no longer be used.
        readyReply = nil
        cancelDownload = nil
        if !handedOff {
            authorizedVersion = nil
            automaticVersion = nil
            cancelWhenReady = false
            armedSessionUnresolved = false
            progress.dismiss()
        }
        sessionEnded()
    }

    func driverShowUpdateInFocus() {
        showUpdatesRequested?()
    }

    func driverModalAlert(visible: Bool) {
        modalAlertVisible = visible
        if visible { notice.dismiss() } else { interactionBecameSafe() }
        if visible, candidate != nil, status.phase == .available { noticePending = true }
    }
}

// MARK: - Node ownership bridge

/// Runs `<node> <bundle>/Contents/Resources/runtime/apps/macos/update-ownership.mjs <command>` with one JSON object on
/// stdin and one JSON line on stdout. Blocking: call off the main thread.
struct UpdateOwnershipRunner {
    static let modulePath = "runtime/apps/macos/update-ownership.mjs"
    static let timeout: TimeInterval = 35

    let nodePath: String
    let hostBundle: Bundle
    let appPath: String
    let configPath: String

    func run<T: Decodable>(_ type: T.Type, command: String, extra: [String: Any] = [:]) -> Result<T, UpdateOwnershipFailure> {
        func failure(_ code: String, _ message: String) -> Result<T, UpdateOwnershipFailure> { .failure(UpdateOwnershipFailure(code: code, message: message, recovery: nil)) }
        guard let module = hostBundle.resourceURL?.appendingPathComponent(Self.modulePath).path, FileManager.default.fileExists(atPath: module) else {
            return failure("missing-helper", "The bundled update ownership helper is missing.")
        }
        guard let input = try? UpdateOwnershipCodec.request(appPath: appPath, configPath: configPath, extra: extra) else {
            return failure("invalid-request", "The update ownership request could not be encoded.")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: nodePath)
        task.arguments = [module, command]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        do { try task.run() } catch { return failure("node-unavailable", "Node.js could not be started from the configured path.") }
        let group = DispatchGroup()
        let lock = NSLock()
        var output = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); output = data; lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async { _ = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        let deadline = DispatchTime.now() + Self.timeout
        if group.wait(timeout: deadline) == .timedOut {
            task.terminate()
            return failure("timeout", "The update ownership helper did not finish in time.")
        }
        task.waitUntilExit()
        lock.lock(); let data = output; lock.unlock()
        return UpdateOwnershipCodec.parse(type, stdout: data, exitStatus: task.terminationStatus)
    }
}
