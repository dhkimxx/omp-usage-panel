import Foundation

private let goodHash = String(repeating: "ab12", count: 16)
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func candidate(version: String = "0.2.0", properties: [AnyHashable: Any]? = nil, signed: Bool = true, url: String? = "https://example.com/app.zip",
                       informationOnly: Bool = false, notes: String? = nil, notesFormat: String? = nil, notesURL: String? = nil) -> UpdateCandidate {
    UpdateCandidate.make(version: version, build: version, properties: properties ?? ["omp:appTreeSHA256": goodHash], signatureValidated: signed,
                         downloadURL: url.flatMap(URL.init(string:)), informationOnly: informationOnly, notesText: notes, notesFormat: notesFormat,
                         notesURL: notesURL.flatMap(URL.init(string:)), publishedAt: nil)
}

private func installable(_ version: String = "0.2.0") -> UpdateCandidate { candidate(version: version) }

func runUpdateModelTests() {
    // Defaults: daily checks, notifications on, automatic installation never on without opt-in.
    precondition(UpdatePolicy.defaults == UpdatePolicy(automaticChecks: true, automaticInstallation: false, notificationsEnabled: true))
    precondition(UpdatePolicy.defaults != UpdatePolicy(automaticChecks: true, automaticInstallation: true, notificationsEnabled: true))

    // Busy phases are exactly the in-flight ones.
    let busy = Set([UpdatePhase.checking, .downloading, .extracting, .installing])
    for phase in [UpdatePhase.stopped, .idle, .checking, .upToDate, .available, .downloading, .extracting, .readyToInstall, .installing, .failed, .unsupported] {
        precondition(phase.isBusy == busy.contains(phase), "busy \(phase)")
    }

    // Status copies keep unspecified fields, clear explicitly, and installBlocked never sticks.
    let base = UpdateStatus(installedVersion: "0.1.0", availableVersion: "0.2.0", phase: .available, message: "m", lastCheckedAt: t0, canInstall: true, lastSkippedVersion: "0.1.5")
    let blocked = base.with(message: UpdateStatus.installBlockedMessage, installBlocked: true)
    precondition(blocked.installBlocked && blocked.availableVersion == "0.2.0" && blocked.phase == .available && blocked.canInstall && blocked.lastCheckedAt == t0)
    precondition(!blocked.with(phase: .checking).installBlocked)
    let cleared = base.with(availableVersion: .some(nil), canInstall: false, lastSkippedVersion: .some(nil))
    precondition(cleared.availableVersion == nil && cleared.lastSkippedVersion == nil && !cleared.canInstall && cleared.message == "m")
    precondition(base.with(phase: .failed).lastSkippedVersion == "0.1.5" && base.with(phase: .failed).installedVersion == "0.1.0")
    precondition(UpdateStatus.initial(installedVersion: "0.1.0").phase == .stopped && !UpdateStatus.initial(installedVersion: "0.1.0").canInstall)

    runHashTests()
    runCandidateTests()
    runReleaseNotesTests()
    runEligibilityTests()
    runOwnershipCodecTests()
}

private func runHashTests() {
    func extract(_ properties: [AnyHashable: Any]) -> Result<String, UpdateAppTreeHashError> { UpdateAppTreeHash.extract(from: properties) }
    precondition(extract(["omp:appTreeSHA256": goodHash]) == .success(goodHash))
    precondition(extract(["appTreeSHA256": goodHash]) == .success(goodHash))
    precondition(extract(["omp:appTreeSHA256": "  \(goodHash.uppercased())\n"]) == .success(goodHash), "case and whitespace normalize")
    precondition(extract(["omp:appTreeSHA256": ["text": goodHash]]) == .success(goodHash))
    precondition(extract(["omp:appTreeSHA256": ["__text": goodHash, "attrs": ["x": "y"]]]) == .success(goodHash))
    precondition(extract(["omp:appTreeSHA256": [goodHash, goodHash]]) == .success(goodHash), "repeated identical values are one value")
    precondition(extract([:]) == .failure(.missing))
    precondition(extract(["sparkle:version": "1"]) == .failure(.missing))
    precondition(extract(["omp:otherSHA256": goodHash]) == .failure(.missing), "other element names never qualify")
    precondition(extract(["xappTreeSHA256": goodHash]) == .failure(.missing), "suffix needs a namespace separator")
    precondition(extract(["omp:appTreeSHA256": ["attr": goodHash]]) == .failure(.missing), "attributes are not element text")
    precondition(extract(["omp:appTreeSHA256": String(goodHash.dropLast())]) == .failure(.malformed))
    precondition(extract(["omp:appTreeSHA256": goodHash + "0"]) == .failure(.malformed))
    precondition(extract(["omp:appTreeSHA256": String(repeating: "g", count: 64)]) == .failure(.malformed))
    precondition(extract(["omp:appTreeSHA256": ""]) == .failure(.malformed))
    precondition(extract(["omp:appTreeSHA256": goodHash, "other:appTreeSHA256": String(repeating: "c", count: 64)]) == .failure(.conflicting))
    precondition(UpdateAppTreeHash.isValid(goodHash) && !UpdateAppTreeHash.isValid(goodHash.uppercased()), "stored form is lowercase hex")
}

private func runCandidateTests() {
    let good = installable()
    precondition(good.isInstallable && good.blockedReason == nil && good.appTreeSHA256 == goodHash && good.version == "0.2.0")

    // Each missing authentication fact blocks installation instead of falling back to display-only installability.
    precondition(!candidate(signed: false).isInstallable && candidate(signed: false).blockedReason!.contains("signature"))
    precondition(!candidate(url: "http://example.com/app.zip").isInstallable)
    precondition(!candidate(url: nil).isInstallable)
    precondition(!candidate(informationOnly: true).isInstallable)
    precondition(!candidate(properties: [:]).isInstallable && candidate(properties: [:]).blockedReason!.contains("lacks"))
    precondition(candidate(properties: ["omp:appTreeSHA256": "xyz"]).blockedReason!.contains("malformed"))
    precondition(candidate(properties: ["omp:appTreeSHA256": goodHash, "x:appTreeSHA256": String(repeating: "d", count: 64)]).blockedReason!.contains("conflicting"))
    precondition(candidate(properties: [:]).appTreeSHA256 == nil)
    precondition(candidate(url: "https://example.com/app.zip", informationOnly: false).isInstallable)

    // Versions: digits, optional dotted parts and pre-release/build suffix; no shell/path material reaches the ownership helper.
    for version in ["0.2.0", "10.0", "1.2.3.4", "2.0.0-beta.1", "1.0.0+build.5", "7"] { precondition(UpdateCandidate.isValidVersion(version), version) }
    for version in ["", "v1.0", "1..2", "1.0 ", "1.0; rm -rf /", "../1.0", "1.0\n", "1.2.3.4.5", "-1"] { precondition(!UpdateCandidate.isValidVersion(version), version) }
    precondition(!candidate(version: "1.0; rm").isInstallable)

    // Release-notes links must be HTTPS to be kept.
    precondition(candidate(notesURL: "https://example.com/n").notesURL?.absoluteString == "https://example.com/n")
    precondition(candidate(notesURL: "http://example.com/n").notesURL == nil)
    precondition(candidate(notesURL: "javascript:alert(1)").notesURL == nil)
    precondition(candidate(notes: "<p>Hi</p>", notesFormat: "html").notesText == "Hi")
    precondition(candidate(notes: "   ", notesFormat: "plain-text").notesText == nil)
}

private func runReleaseNotesTests() {
    let html = "<h2>What&#39;s new</h2><ul><li>Faster &amp; safer</li><li>Fix <b>crash</b></li></ul><script>alert(1)</script><style>p{}</style><!-- hidden --><p>5 &lt; 6</p>"
    let text = UpdateReleaseNotes.plainText(html, format: "html")
    precondition(text == "What's new\n\n• Faster & safer\n• Fix crash\n\n5 < 6", text)
    precondition(UpdateReleaseNotes.plainText("&amp;lt;", format: "html") == "&lt;", "ampersand decodes last")
    precondition(UpdateReleaseNotes.plainText("a&#x41;&#66;", format: "html") == "aAB")
    precondition(UpdateReleaseNotes.plainText("<p>a</p><p>b</p>", format: nil) == "a\n\nb")
    precondition(UpdateReleaseNotes.plainText("# Title\n* item <b>x</b>", format: "markdown") == "# Title\n* item <b>x</b>", "markdown is not interpreted")
    precondition(UpdateReleaseNotes.plainText("a\r\n\r\n\r\n\r\nb  \n", format: "plain-text") == "a\n\nb")
    let long = UpdateReleaseNotes.plainText(String(repeating: "x", count: UpdateReleaseNotes.maximumLength + 500), format: "plain-text")
    precondition(long.count == UpdateReleaseNotes.maximumLength + 1 && long.hasSuffix("…"))
    precondition(UpdateReleaseNotes.plainText("", format: "html").isEmpty)
}

private func runEligibilityTests() {
    let policy = UpdatePolicy.defaults
    let clean = UpdatePreferences()
    let skipped = UpdatePreferences(skippedVersion: "0.2.0")
    let deferred = UpdatePreferences(deferredVersion: "0.2.0", deferredUntil: t0.addingTimeInterval(3600))
    let off = UpdatePolicy(automaticChecks: true, automaticInstallation: false, notificationsEnabled: false)

    // Scheduled discovery.
    precondition(UpdateEligibility.scheduledDisposition(version: "0.2.0", policy: policy, preferences: clean, now: t0) == .notify)
    precondition(UpdateEligibility.scheduledDisposition(version: "0.2.0", policy: off, preferences: clean, now: t0) == .recordOnly)
    precondition(UpdateEligibility.scheduledDisposition(version: "0.2.0", policy: policy, preferences: skipped, now: t0) == .suppressed(.skipped))
    precondition(UpdateEligibility.scheduledDisposition(version: "0.2.1", policy: policy, preferences: skipped, now: t0) == .notify, "a skip covers only that exact version")
    precondition(UpdateEligibility.scheduledDisposition(version: "0.2.0", policy: policy, preferences: deferred, now: t0) == .suppressed(.deferred(until: t0.addingTimeInterval(3600))))
    precondition(UpdateEligibility.scheduledDisposition(version: "0.2.0", policy: policy, preferences: deferred, now: t0.addingTimeInterval(3600)) == .notify, "deferral ends at its deadline")
    precondition(UpdateEligibility.scheduledDisposition(version: "0.3.0", policy: policy, preferences: deferred, now: t0) == .notify, "a newer release is not deferred")
    precondition(UpdateEligibility.scheduledDisposition(version: "0.2.0", policy: off, preferences: skipped, now: t0) == .suppressed(.skipped), "skip wins over a notifications-off record")

    // Cutover: Update Now authorizes exactly one release, automatic installation needs committed consent and no hold.
    func cutover(_ version: String = "0.2.0", authorized: String? = nil, policy: UpdatePolicy = policy, prefs: UpdatePreferences = clean, safe: Bool = true) -> UpdateCutover {
        UpdateEligibility.cutover(version: version, authorizedVersion: authorized, policy: policy, preferences: prefs, now: t0, safeToInstall: safe)
    }
    let auto = UpdatePolicy(automaticChecks: true, automaticInstallation: true, notificationsEnabled: true)
    precondition(cutover(authorized: "0.2.0") == .proceed)
    precondition(cutover(authorized: "0.2.0", safe: false) == .waitForSafeMoment)
    precondition(cutover(authorized: "0.2.0", prefs: skipped) == .proceed, "an explicit Update Now overrides Skip for that release")
    precondition(cutover(authorized: "0.2.0", prefs: deferred) == .proceed)
    precondition(cutover(authorized: "0.1.9") == .needsUserAction, "authorization is not transferable to another release")
    precondition(cutover() == .needsUserAction, "defaults never install without consent")
    precondition(cutover(policy: off) == .needsUserAction)
    precondition(cutover(policy: auto) == .proceed)
    precondition(cutover(policy: auto, safe: false) == .waitForSafeMoment)
    precondition(cutover(policy: auto, prefs: skipped) == .needsUserAction, "automatic installation honors Skip")
    precondition(cutover(policy: auto, prefs: deferred) == .needsUserAction, "automatic installation honors Later")
    precondition(cutover("0.3.0", policy: auto, prefs: skipped) == .proceed)
    precondition(cutover(policy: UpdatePolicy(automaticChecks: false, automaticInstallation: true, notificationsEnabled: true)) == .needsUserAction, "checks off disables automatic installation")
    precondition(cutover(policy: UpdatePolicy(automaticChecks: true, automaticInstallation: true, notificationsEnabled: false)) == .proceed, "notifications are independent of installation consent")

    // Scheduled discovery with saved automatic consent: start visibly when the host is safe, wait when busy, never when held.
    func start(_ version: String = "0.2.0", policy: UpdatePolicy = auto, prefs: UpdatePreferences = clean, host: Bool = true) -> UpdateAutomaticStart {
        UpdateEligibility.automaticStart(version: version, policy: policy, preferences: prefs, now: t0, hostAllowsPresentation: host)
    }
    precondition(start() == .start)
    precondition(start(host: false) == .waitForSafeMoment, "a busy host (Settings, menu, drag, expanded panel) defers the visible download")
    precondition(start(policy: policy) == .notAllowed, "defaults (consent off) never start automatically")
    precondition(start(policy: UpdatePolicy(automaticChecks: false, automaticInstallation: true, notificationsEnabled: true)) == .notAllowed)
    precondition(start(policy: UpdatePolicy(automaticChecks: true, automaticInstallation: true, notificationsEnabled: false)) == .start, "notifications are independent of installation consent")
    precondition(start(prefs: skipped) == .notAllowed && start(prefs: deferred) == .notAllowed, "Skip and Later hold automatic installs")
    precondition(start(prefs: skipped, host: false) == .notAllowed, "a hold wins over a busy host")
    precondition(start("0.3.0", prefs: skipped) == .start && start("0.3.0", prefs: deferred) == .start)
    precondition(UpdateEligibility.automaticStart(version: "0.2.0", policy: auto, preferences: deferred, now: t0.addingTimeInterval(3600), hostAllowsPresentation: true) == .start, "a lapsed Later no longer holds")

    // Notice presentation: scheduled + installable + eligible + host allows + not already showing.
    func present(_ c: UpdateCandidate = installable(), origin: UpdateCheckOrigin = .scheduled, policy: UpdatePolicy = policy, prefs: UpdatePreferences = clean, host: Bool = true, showing: Bool = false) -> Bool {
        UpdateEligibility.shouldPresentNotice(candidate: c, origin: origin, policy: policy, preferences: prefs, now: t0, hostAllowsPresentation: host, alreadyShowing: showing)
    }
    precondition(present())
    precondition(!present(origin: .manual), "manual checks report inline, never by popup")
    precondition(!present(host: false), "an unsafe host moment suppresses the notice")
    precondition(!present(showing: true))
    precondition(!present(policy: off))
    precondition(!present(prefs: skipped) && !present(prefs: deferred))
    precondition(!present(candidate(properties: [:])), "an update that cannot be installed is never offered")
    precondition(present(policy: auto), "the notice still appears if automatic installation is on and checks found it")

    // Found-update decision for every SDK stage. `.installing` is already armed to install on quit: dismiss never cancels it.
    func found(_ stage: UpdateSessionStage, userInitiated: Bool = false, authorized: String? = nil, policy: UpdatePolicy = policy, prefs: UpdatePreferences = clean, safe: Bool = true) -> UpdateFoundAction {
        UpdateEligibility.foundAction(stage: stage, userInitiated: userInitiated, authorizedVersion: authorized, version: "0.2.0", policy: policy, preferences: prefs, now: t0, safe: safe)
    }
    for stage in [UpdateSessionStage.notDownloaded, .downloaded] {
        precondition(found(stage) == .notify, "a scheduled find without consent is only reported")
        precondition(found(stage, userInitiated: true) == .notify, "a manual check alone never installs")
        precondition(found(stage, policy: auto) == .install && found(stage, policy: auto, safe: false) == .waitForSafeMoment)
        precondition(found(stage, userInitiated: true, policy: auto) == .notify, "manual checks never auto-start even with consent")
        precondition(found(stage, policy: auto, prefs: skipped) == .notify && found(stage, policy: auto, prefs: deferred) == .notify)
        precondition(found(stage, userInitiated: true, authorized: "0.2.0") == .install)
        precondition(found(stage, userInitiated: true, authorized: "0.2.0", safe: false) == .blocked, "Update Now with unsaved work is refused, not started")
        precondition(found(stage, authorized: "0.1.9") == .notify, "authorization is exact to the release")
    }
    precondition(found(.installing) == .cancelInstalling, "no authorization: cancel the armed session, never dismiss")
    precondition(found(.installing, userInitiated: true) == .cancelInstalling)
    precondition(found(.installing, policy: auto, prefs: skipped) == .cancelInstalling && found(.installing, policy: auto, prefs: deferred) == .cancelInstalling)
    precondition(found(.installing, policy: UpdatePolicy(automaticChecks: true, automaticInstallation: false, notificationsEnabled: true)) == .cancelInstalling, "consent withdrawn while preparing cancels")
    precondition(found(.installing, policy: auto) == .install && found(.installing, policy: auto, safe: false) == .holdInstalling)
    precondition(found(.installing, userInitiated: true, authorized: "0.2.0") == .install && found(.installing, userInitiated: true, authorized: "0.2.0", safe: false) == .holdInstalling)
    precondition(found(.installing, authorized: "0.2.0", prefs: skipped) == .install, "an explicit Update Now overrides Skip")

    // Quit guard: ONLY the final authorized handoff terminates while an update is in play. A plain Quit with an install-capable
    // session live starts cancellation (never Sparkle's implicit install-on-quit); unresolved cancellation keeps waiting.
    precondition(UpdateEligibility.termination(UpdateSessionFlags()) == .allow, "nothing can install: quit freely")
    precondition(UpdateEligibility.termination(UpdateSessionFlags(installCapable: true)) == .cancelAndHold, "Quit before the final handoff cancels, even with consent still on")
    precondition(UpdateEligibility.termination(UpdateSessionFlags(armedSessionUnresolved: true)) == .cancelAndHold, "an armed or preparing session is cancelled on Quit")
    precondition(UpdateEligibility.termination(UpdateSessionFlags(installCapable: true, withdrawnDuringExtraction: true)) == .cancelAndHold)
    precondition(UpdateEligibility.termination(UpdateSessionFlags(withdrawnDuringExtraction: true)) == .hold, "uncancelable extraction: keep the app until the ready skip")
    precondition(UpdateEligibility.termination(UpdateSessionFlags(cancellationUnresolved: true)) == .hold, "cancel sent, SDK session not ended: keep waiting")
    precondition(UpdateEligibility.termination(UpdateSessionFlags(handedOff: true, installCapable: true, withdrawnDuringExtraction: true, cancellationUnresolved: true, armedSessionUnresolved: true)) == .allow, "only the authorized final handoff is never held")

    // An earlier prepared transaction may be replaced only with proof its Sparkle session can no longer install.
    precondition(UpdateEligibility.mayDiscardEarlierPreparation(UpdateSessionFlags()))
    precondition(!UpdateEligibility.mayDiscardEarlierPreparation(UpdateSessionFlags(installCapable: true)), "an install reply is outstanding")
    precondition(!UpdateEligibility.mayDiscardEarlierPreparation(UpdateSessionFlags(cancellationUnresolved: true)), "prior cancellation not yet ended")
    precondition(!UpdateEligibility.mayDiscardEarlierPreparation(UpdateSessionFlags(withdrawnDuringExtraction: true)))
    precondition(!UpdateEligibility.mayDiscardEarlierPreparation(UpdateSessionFlags(handedOff: true)), "never once handed off")
    precondition(UpdateEligibility.mayDiscardEarlierPreparation(UpdateSessionFlags(armedSessionUnresolved: true)), "a new preparation in flight does not block replacing a finished one")
}

private func runOwnershipCodecTests() {
    // Request encoding: exact keys, sorted, no extras.
    let request = try! UpdateOwnershipCodec.request(appPath: "/Apps/OMP Usage.app", configPath: "/tmp/c.json", extra: ["expectedVersion": "0.2.0", "ownerPid": 4242])
    let object = try! JSONSerialization.jsonObject(with: request) as! [String: Any]
    precondition(Set(object.keys) == ["appPath", "configPath", "expectedVersion", "ownerPid"])
    precondition(object["appPath"] as? String == "/Apps/OMP Usage.app" && object["configPath"] as? String == "/tmp/c.json" && object["expectedVersion"] as? String == "0.2.0")
    precondition(object["ownerPid"] as? Int == 4242, "the owner pid stays a JSON number")

    func parseStatus(_ line: String, exit: Int32 = 0) -> Result<UpdateOwnershipStatusResponse, UpdateOwnershipFailure> {
        UpdateOwnershipCodec.parse(UpdateOwnershipStatusResponse.self, stdout: Data(line.utf8), exitStatus: exit)
    }
    let managed = parseStatus(#"{"ok":true,"command":"status","managed":true,"version":"0.1.0","pending":null,"outcome":{"transactionId":"t1","status":"rolled-back","fromVersion":"0.1.0","toVersion":"0.2.0","at":"2026-01-01T00:00:00Z","message":"x"}}"# + "\n")
    guard case .success(let status) = managed else { preconditionFailure("managed status") }
    precondition(status.managed && status.pending == nil && status.outcome?.status == "rolled-back")
    let unmanaged = parseStatus(#"{"ok":true,"command":"status","managed":false,"reason":"Not installed by the installer.","pending":{"transactionId":"t","phase":"prepared","fromVersion":"0.1.0","toVersion":"0.2.0"},"outcome":null}"#)
    guard case .success(let other) = unmanaged else { preconditionFailure("unmanaged status") }
    precondition(!other.managed && other.reason == "Not installed by the installer." && other.pending?.phase == "prepared")

    // Controlled failures: structured error, bad exit, unreadable output, ok:true with failing exit, wrong shape.
    let structured = parseStatus(#"{"ok":false,"command":"status","error":{"code":"busy","message":"Another install is running.","recovery":"Try again."}}"#, exit: 1)
    guard case .failure(let failure) = structured else { preconditionFailure("structured") }
    precondition(failure.code == "busy" && failure.displayText == "Another install is running. Try again.")
    for (text, exit) in [("", Int32(1)), ("not json", 0), ("{\"managed\":true}", 0), (#"{"ok":true,"managed":true}"#, 3), (#"{"ok":true,"command":"status"}"#, 0)] as [(String, Int32)] {
        guard case .failure(let bad) = parseStatus(text, exit: exit) else { preconditionFailure("must fail: \(text)") }
        precondition(!bad.message.isEmpty && bad.code != "")
    }
    // The last stdout line wins (warnings before the JSON line cannot hijack the result).
    precondition({ if case .success = parseStatus("warning: x\n" + #"{"ok":true,"managed":true}"# + "\n") { return true } else { return false } }())
    guard case .success(let prepared) = UpdateOwnershipCodec.parse(UpdateOwnershipPrepareResponse.self, stdout: Data(#"{"ok":true,"command":"prepare","transactionId":"t9","armed":true}"#.utf8), exitStatus: 0) else { preconditionFailure("prepare") }
    precondition(prepared.transactionId == "t9" && prepared.armed)
    if case .success = UpdateOwnershipCodec.parse(UpdateOwnershipPrepareResponse.self, stdout: Data(#"{"ok":true,"command":"prepare","transactionId":"t9"}"#.utf8), exitStatus: 0) {
        preconditionFailure("a prepare response that does not say the watcher is armed must not decode")
    }
    guard case .success(let ack) = UpdateOwnershipCodec.parse(UpdateOwnershipAckResponse.self, stdout: Data(#"{"ok":true,"committed":false,"pending":false}"#.utf8), exitStatus: 0) else { preconditionFailure("ack") }
    precondition(!ack.committed && !ack.pending)

    // Launch acknowledgment: retried within the 45 s readiness window; only a permanent failure or a resolved outcome stops early.
    func ackOK(_ committed: Bool, _ pending: Bool, reason: String? = nil) -> Result<UpdateOwnershipAckResponse, UpdateOwnershipFailure> {
        .success(UpdateOwnershipAckResponse(committed: committed, pending: pending, reason: reason))
    }
    func ackFail(_ code: String) -> Result<UpdateOwnershipAckResponse, UpdateOwnershipFailure> {
        .failure(UpdateOwnershipFailure(code: code, message: "m", recovery: nil))
    }
    precondition(UpdateAckOutcome.next(ackOK(true, false), elapsed: 0) == .finished, "committed")
    precondition(UpdateAckOutcome.next(ackOK(false, false), elapsed: 0) == .finished, "nothing pending")
    precondition(UpdateAckOutcome.next(ackOK(false, true), elapsed: 0) == .retry, "pending but not committed yet: do not give up")
    precondition(UpdateAckOutcome.next(ackOK(false, true, reason: "installer-quiescing"), elapsed: 5) == .retry, "the installer is still quiescing: retry")
    for reason in ["rolling-back", "not-replaced"] {
        precondition(UpdateAckOutcome.next(ackOK(false, true, reason: reason), elapsed: 0) == .finished, "\(reason): retrying cannot change the outcome")
    }
    precondition(UpdateAckOutcome.next(ackOK(false, true), elapsed: 44) == .retry)
    precondition(UpdateAckOutcome.next(ackOK(false, true), elapsed: UpdateAckOutcome.readinessWindow) == .finished, "bounded by the watcher readiness window")
    for code in ["busy", "io-error", "timeout", "invalid-response"] {
        precondition(UpdateAckOutcome.next(ackFail(code), elapsed: 3) == .retry, "\(code) is transient")
        precondition(UpdateAckOutcome.next(ackFail(code), elapsed: 60) == .finished, "\(code) stops at the deadline")
    }
    for code in ["not-managed", "ownership-mismatch", "invalid-request", "invalid-transaction", "missing-helper", "node-unavailable"] {
        precondition(UpdateAckOutcome.next(ackFail(code), elapsed: 0) == .finished, "\(code) is permanent: no retry")
    }
    // The final-handoff authorization: a refusal (dead watcher, replaced app, unknown id) is data, not a crash; a missing flag never authorizes.
    guard case .success(let granted) = UpdateOwnershipCodec.parse(UpdateOwnershipAuthorizeResponse.self, stdout: Data(#"{"ok":true,"command":"authorize","authorized":true}"#.utf8), exitStatus: 0) else { preconditionFailure("authorize") }
    precondition(granted.authorized && granted.reason == nil)
    guard case .success(let denied) = UpdateOwnershipCodec.parse(UpdateOwnershipAuthorizeResponse.self, stdout: Data(#"{"ok":true,"command":"authorize","authorized":false,"reason":"The watcher is not running."}"#.utf8), exitStatus: 0) else { preconditionFailure("authorize denied") }
    precondition(!denied.authorized && denied.reason == "The watcher is not running.")
    if case .success = UpdateOwnershipCodec.parse(UpdateOwnershipAuthorizeResponse.self, stdout: Data(#"{"ok":true,"command":"authorize"}"#.utf8), exitStatus: 0) {
        preconditionFailure("an authorize response without an explicit flag must not decode")
    }
    guard case .success(let revoked) = UpdateOwnershipCodec.parse(UpdateOwnershipRevokeResponse.self, stdout: Data(#"{"ok":true,"command":"revoke","revoked":true}"#.utf8), exitStatus: 0) else { preconditionFailure("revoke") }
    precondition(revoked.revoked && revoked.code == nil)
    guard case .success(let notRevoked) = UpdateOwnershipCodec.parse(UpdateOwnershipRevokeResponse.self, stdout: Data(#"{"ok":true,"command":"revoke","revoked":false,"code":"replaced","reason":"Already replaced."}"#.utf8), exitStatus: 0) else { preconditionFailure("revoke refused") }
    precondition(!notRevoked.revoked && notRevoked.code == "replaced")

    // Abort needs POSITIVE evidence: a dismissal or a quiet response is never proof the installer is cancelled.
    func abortResult(_ json: String, exit: Int32 = 0) -> Result<UpdateOwnershipAbortResponse, UpdateOwnershipFailure> {
        UpdateOwnershipCodec.parse(UpdateOwnershipAbortResponse.self, stdout: Data(json.utf8), exitStatus: exit)
    }
    precondition(UpdateAbortOutcome.classify(abortResult(#"{"ok":true,"command":"abort","aborted":true}"#)) == .resolved, "discarded with the installer provably gone")
    precondition(UpdateAbortOutcome.classify(abortResult(#"{"ok":true,"command":"abort","aborted":false,"code":"installer-live","reason":"The Sparkle installer is still running."}"#)) == .retry, "installer still running: keep holding Quit")
    precondition(UpdateAbortOutcome.classify(abortResult(#"{"ok":true,"command":"abort","aborted":false}"#)) == .retry, "no code and no abort is no proof")
    precondition(UpdateAbortOutcome.classify(abortResult(#"{"ok":true,"command":"abort","aborted":false,"code":"something-new"}"#)) == .retry, "an unknown refusal never releases Quit")
    for code in ["replaced", "relaunching", "unknown-transaction"] {
        precondition(UpdateAbortOutcome.classify(abortResult(#"{"ok":true,"command":"abort","aborted":false,"code":"\#(code)"}"#)) == .resolved, "\(code): install already proceeding, nothing left to hold for")
    }
    precondition(UpdateAbortOutcome.classify(abortResult(#"{"ok":false,"command":"abort","error":{"code":"io-error","message":"launchctl failed"}}"#, exit: 1)) == .retry, "a failed installer inspection is no proof")
    precondition(UpdateAbortOutcome.classify(abortResult(#"{"ok":false,"command":"abort","error":{"code":"unknown-transaction","message":"No such transaction."}}"#, exit: 1)) == .resolved)
    precondition(UpdateAbortOutcome.classify(abortResult("garbage", exit: 0)) == .retry)
    precondition(UpdateAbortOutcome.classify(abortResult(#"{"ok":false,"command":"abort","error":{"code":"invalid-request","message":"Invalid installer label."}}"#, exit: 1)) == .unrecoverable, "a malformed request is a bug: no retry spin, and still no release")
    for code in ["inspection-failed", "busy", "io-error"] {
        precondition(UpdateAbortOutcome.classify(abortResult(#"{"ok":false,"command":"abort","error":{"code":"\#(code)","message":"x"}}"#, exit: 1)) == .retry, "\(code) is retried, never treated as proof")
    }
    guard case .failure(let refused) = UpdateOwnershipCodec.parse(UpdateOwnershipPrepareResponse.self, stdout: Data(#"{"ok":false,"command":"prepare","error":{"code":"ownership-mismatch","message":"The app was modified."}}"#.utf8), exitStatus: 1) else { preconditionFailure("refused") }
    precondition(refused.code == "ownership-mismatch" && refused.recovery == nil && refused.displayText == "The app was modified.")

    // Sanitizing: controls removed, bounded, fallback for blank.
    precondition(UpdateOwnershipCodec.sanitizedMessage("a\u{0}b\nc\u{7f}d", fallback: "f") == "a b c d")
    precondition(UpdateOwnershipCodec.sanitizedMessage("  \n ", fallback: "f") == "f" && UpdateOwnershipCodec.sanitizedMessage(nil, fallback: "f") == "f")
    let longMessage = UpdateOwnershipCodec.sanitizedMessage(String(repeating: "z", count: 900), fallback: "f")
    precondition(longMessage.count == 301 && longMessage.hasSuffix("…"))

    // Durable outcome wording.
    func outcome(_ status: String, message: String? = nil) -> UpdateOwnershipOutcome {
        UpdateOwnershipOutcome(transactionId: "t", status: status, fromVersion: "0.1.0", toVersion: "0.2.0", at: nil, message: message)
    }
    precondition(UpdateMessages.outcome(outcome("updated"), installed: "0.2.0") == "Updated to 0.2.0.")
    precondition(UpdateMessages.outcome(outcome("rolled-back"), installed: "0.1.0").contains("previous version 0.1.0 was restored"))
    precondition(UpdateMessages.outcome(outcome("failed", message: "disk full"), installed: "0.1.0") == "The update to 0.2.0 failed. disk full")
    precondition(!UpdateMessages.outcomeIsProblem(outcome("updated")) && UpdateMessages.outcomeIsProblem(outcome("rolled-back")) && UpdateMessages.outcomeIsProblem(outcome("failed")))
    precondition(UpdateMessages.available(version: "0.2.0", installed: "0.1.0", suppression: .skipped).contains("skipped"))
    precondition(UpdateMessages.available(version: "0.2.0", installed: "0.1.0", suppression: .deferred(until: t0), formatter: { _ in "TOMORROW" }).contains("paused until TOMORROW"))
}
