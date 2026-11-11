import Foundation

// Pure Foundation updater model. Nothing here imports Sparkle or AppKit so the transitions, eligibility rules and
// authenticated-metadata validation stay testable. Sparkle (not this file) owns transport, EdDSA verification of the
// signed feed/archive and the automatic check/download preferences.

/// Committed update choices mirrored from Sparkle (automatic checks/downloads) and the app-owned preference blob
/// (notifications). Three independent switches: checking for updates, being notified, and installing automatically.
struct UpdatePolicy: Equatable {
    var automaticChecks: Bool
    var automaticInstallation: Bool
    var notificationsEnabled: Bool

    /// Daily check, notify only. Automatic installation is never on without an explicit opt-in.
    static let defaults = UpdatePolicy(automaticChecks: true, automaticInstallation: false, notificationsEnabled: true)
}

enum UpdatePhase: String, Equatable {
    case stopped, idle, checking, upToDate, available, downloading, extracting, readyToInstall, installing, failed, unsupported

    /// Work is in flight and Check/Update actions should not be offered again.
    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .extracting, .installing: return true
        case .stopped, .idle, .upToDate, .available, .readyToInstall, .failed, .unsupported: return false
        }
    }
}

/// Immutable snapshot published to the UI. `installBlocked` is true only when an explicit install request was refused
/// because installing would discard unsaved work; it clears on the next status change.
struct UpdateStatus: Equatable {
    let installedVersion: String
    let availableVersion: String?
    let phase: UpdatePhase
    let message: String
    let lastCheckedAt: Date?
    let canInstall: Bool
    let lastSkippedVersion: String?
    let installBlocked: Bool

    init(installedVersion: String, availableVersion: String? = nil, phase: UpdatePhase, message: String,
         lastCheckedAt: Date? = nil, canInstall: Bool = false, lastSkippedVersion: String? = nil, installBlocked: Bool = false) {
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.phase = phase
        self.message = message
        self.lastCheckedAt = lastCheckedAt
        self.canInstall = canInstall
        self.lastSkippedVersion = lastSkippedVersion
        self.installBlocked = installBlocked
    }

    static func initial(installedVersion: String) -> UpdateStatus {
        UpdateStatus(installedVersion: installedVersion, phase: .stopped, message: "Update checks have not started.")
    }

    /// Copy with selected changes. `String??`/`Date??` use `.some(nil)` to clear and `nil` to keep. `installBlocked`
    /// always resets unless supplied.
    func with(availableVersion: String?? = nil, phase: UpdatePhase? = nil, message: String? = nil, lastCheckedAt: Date?? = nil,
              canInstall: Bool? = nil, lastSkippedVersion: String?? = nil, installBlocked: Bool = false) -> UpdateStatus {
        UpdateStatus(installedVersion: installedVersion,
                     availableVersion: availableVersion ?? self.availableVersion,
                     phase: phase ?? self.phase,
                     message: message ?? self.message,
                     lastCheckedAt: lastCheckedAt ?? self.lastCheckedAt,
                     canInstall: canInstall ?? self.canInstall,
                     lastSkippedVersion: lastSkippedVersion ?? self.lastSkippedVersion,
                     installBlocked: installBlocked)
    }

    static let installBlockedMessage = "Save or cancel your open Settings changes, then choose Update Now again."
}

enum UpdateCheckOrigin: Equatable {
    /// Started by the user (Settings button or menu). Always bypasses skip/Later; never changes policy.
    case manual
    /// Sparkle's own timer.
    case scheduled
}

// MARK: - Authenticated candidate

enum UpdateAppTreeHashError: Error, Equatable {
    case missing, malformed, conflicting
}

/// Extracts the custom `<omp:appTreeSHA256>` element from a Sparkle appcast item's property dictionary. Only call
/// after Sparkle validated the signed feed; the element is meaningless otherwise.
enum UpdateAppTreeHash {
    static let elementName = "appTreeSHA256"

    static func extract(from properties: [AnyHashable: Any]) -> Result<String, UpdateAppTreeHashError> {
        var found: [String] = []
        for (key, value) in properties {
            guard let name = key as? String, name == elementName || name.hasSuffix(":" + elementName) else { continue }
            found.append(contentsOf: strings(in: value))
        }
        let candidates = Set(found.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        guard let first = candidates.first else { return .failure(.missing) }
        guard candidates.count == 1 else { return .failure(.conflicting) }
        guard isValid(first) else { return .failure(.malformed) }
        return .success(first)
    }

    /// Exactly 64 hexadecimal characters (SHA-256).
    static func isValid(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    private static func strings(in value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let list = value as? [Any] { return list.flatMap(strings(in:)) }
        if let map = value as? [AnyHashable: Any] {
            // Parsed element text is kept under a text-like key; attributes are never used as the hash.
            for key in ["text", "__text", "value", "content"] {
                if let nested = map[key] { return strings(in: nested) }
            }
        }
        return []
    }
}

/// Everything the notice and the installer bridge need about one authenticated release.
struct UpdateCandidate: Equatable {
    let version: String
    let build: String
    let appTreeSHA256: String?
    /// Non-nil blocks installation (display-only candidates are never installable).
    let blockedReason: String?
    let notesText: String?
    let notesURL: URL?
    let publishedAt: Date?

    var isInstallable: Bool { blockedReason == nil && appTreeSHA256 != nil }

    /// Semantic-ish release version: digits with up to three dotted extra parts and an optional pre-release/build suffix.
    static func isValidVersion(_ version: String) -> Bool {
        // `\z` (not `$`): ICU's `$` also matches before a trailing newline, which must not validate.
        version.range(of: #"^[0-9]+(\.[0-9]+){0,3}([-+][0-9A-Za-z.\-+]+)?\z"#, options: .regularExpression) != nil
    }

    /// Builds a candidate from fields read off a Sparkle item. `signatureValidated` must reflect Sparkle's signed-feed
    /// validation; the archive URL must be HTTPS; the custom tree hash must be present and well formed.
    static func make(version: String, build: String, properties: [AnyHashable: Any], signatureValidated: Bool,
                     downloadURL: URL?, informationOnly: Bool, notesText: String?, notesFormat: String?,
                     notesURL: URL?, publishedAt: Date?) -> UpdateCandidate {
        let notes = notesText.map { UpdateReleaseNotes.plainText($0, format: notesFormat) }.flatMap { $0.isEmpty ? nil : $0 }
        let safeNotesURL = notesURL.flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        func blocked(_ reason: String, hash: String? = nil) -> UpdateCandidate {
            UpdateCandidate(version: version, build: build, appTreeSHA256: hash, blockedReason: reason, notesText: notes, notesURL: safeNotesURL, publishedAt: publishedAt)
        }
        guard isValidVersion(version), !build.isEmpty else { return blocked("The update has an invalid version, so it cannot be installed.") }
        guard signatureValidated else { return blocked("The update feed signature could not be verified, so it cannot be installed.") }
        if informationOnly { return blocked("This release is information only and has no app download.") }
        guard downloadURL?.scheme?.lowercased() == "https" else { return blocked("The update archive is not served over HTTPS, so it cannot be installed.") }
        switch UpdateAppTreeHash.extract(from: properties) {
        case .success(let hash):
            return UpdateCandidate(version: version, build: build, appTreeSHA256: hash, blockedReason: nil, notesText: notes, notesURL: safeNotesURL, publishedAt: publishedAt)
        case .failure(.missing): return blocked("The authenticated update lacks its app integrity hash, so it cannot be installed.")
        case .failure(.malformed): return blocked("The authenticated update has a malformed app integrity hash, so it cannot be installed.")
        case .failure(.conflicting): return blocked("The authenticated update lists conflicting app integrity hashes, so it cannot be installed.")
        }
    }
}

// MARK: - Release notes

enum UpdateReleaseNotes {
    static let maximumLength = 6000

    /// Notes as plain text. HTML is reduced to text without loading anything (no WebKit, no scripts, no remote
    /// resources); Markdown/plain text is passed through unchanged apart from length and blank-line normalization.
    static func plainText(_ raw: String, format: String?) -> String {
        var text = raw
        let normalized = (format ?? "html").lowercased()
        if normalized == "html" { text = htmlToText(text) }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = replace(#"[ \t]+\n"#, in: text, with: "\n")
        text = replace(#"\n{3,}"#, in: text, with: "\n\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maximumLength { text = String(text.prefix(maximumLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" }
        return text
    }

    private static func htmlToText(_ html: String) -> String {
        var text = html
        text = replace(#"<!--.*?-->"#, in: text, with: "", options: [.caseInsensitive, .dotMatchesLineSeparators])
        text = replace(#"<(script|style|head)\b.*?</\1\s*>"#, in: text, with: "", options: [.caseInsensitive, .dotMatchesLineSeparators])
        text = replace(#"<li\b[^>]*>"#, in: text, with: "\n• ", options: [.caseInsensitive])
        text = replace(#"</?(p|div|br|h[1-6]|ul|ol|tr|table|pre|blockquote)\b[^>]*>"#, in: text, with: "\n", options: [.caseInsensitive])
        text = replace(#"<[^>]*>"#, in: text, with: "")
        return decodeEntities(text)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        if let numeric = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            let ns = result as NSString
            var output = ""
            var cursor = 0
            for match in numeric.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
                output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let digits = ns.substring(with: match.range(at: 1))
                let code = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
                if let code, let scalar = Unicode.Scalar(code) { output.unicodeScalars.append(scalar) }
                cursor = match.range.location + match.range.length
            }
            output += ns.substring(from: cursor)
            result = output
        }
        // `&amp;` last so "&amp;lt;" stays the literal text "&lt;".
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String, options: NSRegularExpression.Options = []) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: replacement)
    }
}

// MARK: - Eligibility and cutover decisions

enum UpdateSuppression: Equatable {
    case skipped
    case deferred(until: Date)
}

/// What a scheduled (background) discovery of `version` may do.
enum UpdateScheduledDisposition: Equatable {
    /// Skip/Later hold: do not download, install or notify (manual checks are unaffected).
    case suppressed(UpdateSuppression)
    /// Record availability in status only (notifications are off).
    case recordOnly
    /// Eligible for the notice (subject to the live presentation guard).
    case notify
}

/// What may happen at the point where Sparkle's installer would replace the running app.
enum UpdateCutover: Equatable {
    case proceed
    /// Allowed but unsafe right now (unsaved settings, interaction). Wait for `interactionBecameSafe`/a user click.
    case waitForSafeMoment
    /// No consent exists for this version (not authorized by Update Now, automatic installation off or suppressed).
    case needsUserAction
}

/// What a scheduled discovery of an installable release may do with the user's saved automatic-installation consent.
enum UpdateAutomaticStart: Equatable {
    /// Begin the visible download now (through the normal Sparkle user-driver pipeline).
    case start
    /// Consent exists but the host is busy (Settings, menu, drag, expanded panel). Retry when it is safe.
    case waitForSafeMoment
    /// No consent (automatic checks or installation off) or the release is skipped/deferred.
    case notAllowed
}

/// Where Sparkle is in an update session when it reports a found update. `.installing` is already ARMED to install when
/// the app quits: replying dismiss does not cancel it, only a skip (SDK cancellation) or an install reply resolves it.
enum UpdateSessionStage: Equatable {
    case notDownloaded, downloaded, installing
}

/// What to do with a found update, decided from the CURRENT consent and safety (recomputed after every asynchronous step).
enum UpdateFoundAction: Equatable {
    /// No consent to install: report it (dismiss, nothing armed) and maybe show the notice.
    case notify
    /// Explicit Update Now refused because installing now would discard work (nothing started).
    case blocked
    /// Automatic consent exists but the host is busy: retry later (nothing started).
    case waitForSafeMoment
    /// Prepare + arm, then reply install.
    case install
    /// Already-armed `.installing` session with consent but an unsafe moment: prepare, then keep the reply until safe.
    case holdInstalling
    /// Already-armed `.installing` session with no live consent: cancel with a skip. Never dismiss.
    case cancelInstalling
}

/// Facts that decide whether the app may quit right now.
struct UpdateSessionFlags: Equatable {
    /// Sparkle's installer was told to replace and restart: only this authorized final handoff may terminate the app.
    var handedOff = false
    /// An install-capable Sparkle session is live: an install reply was sent, a ready reply is held, or a download runs.
    /// Sparkle would silently install it when the app quits, so a plain Quit must cancel it first.
    var installCapable = false
    /// Cancellation was requested (consent withdrawn, or Quit) while extraction runs; the SDK cannot cancel extraction,
    /// so cancellation waits for the ready callback.
    var withdrawnDuringExtraction = false
    /// A cancellation reply was sent but the SDK session has not yet ended (its transaction is still to be aborted).
    var cancellationUnresolved = false
    /// A resumed, already-armed `.installing` session, or a preparation, has not yet been decided.
    var armedSessionUnresolved = false
}

enum UpdateTermination: Equatable {
    /// Terminate now: nothing could install, or this is the authorized final handoff.
    case allow
    /// A plain Quit while an install-capable session is live: start cancellation, then wait (`terminateLater`).
    case cancelAndHold
    /// Cancellation is under way: keep waiting (`terminateLater`) until it resolves.
    case hold
}

enum UpdateEligibility {
    static func scheduledDisposition(version: String, policy: UpdatePolicy, preferences: UpdatePreferences, now: Date) -> UpdateScheduledDisposition {
        if let suppression = preferences.suppression(for: version, now: now) { return .suppressed(suppression) }
        return policy.notificationsEnabled ? .notify : .recordOnly
    }

    /// `authorizedVersion` is the in-memory one-off Update Now authorization (never persisted, never implies automatic
    /// installation). Without it, installation needs committed automatic consent and no Skip/Later hold.
    static func cutover(version: String, authorizedVersion: String?, policy: UpdatePolicy, preferences: UpdatePreferences,
                        now: Date, safeToInstall: Bool) -> UpdateCutover {
        if authorizedVersion == version { return safeToInstall ? .proceed : .waitForSafeMoment }
        guard policy.automaticChecks, policy.automaticInstallation, preferences.suppression(for: version, now: now) == nil else { return .needsUserAction }
        return safeToInstall ? .proceed : .waitForSafeMoment
    }

    /// Found-update decision for any stage. `safe` is the live safety answer for THIS purpose: for an explicit Update Now
    /// the narrow unsaved-work guard, for automatic installation the full presentation/interaction guard. Call it again
    /// after any asynchronous step; the result alone decides whether an install reply may be sent.
    static func foundAction(stage: UpdateSessionStage, userInitiated: Bool, authorizedVersion: String?, version: String,
                            policy: UpdatePolicy, preferences: UpdatePreferences, now: Date, safe: Bool) -> UpdateFoundAction {
        let installing = stage == .installing
        if authorizedVersion == version { return safe ? .install : (installing ? .holdInstalling : .blocked) }
        if !userInitiated {
            switch automaticStart(version: version, policy: policy, preferences: preferences, now: now, hostAllowsPresentation: safe) {
            case .start: return .install
            case .waitForSafeMoment: return installing ? .holdInstalling : .waitForSafeMoment
            case .notAllowed: break
            }
        }
        return installing ? .cancelInstalling : .notify
    }

    /// Quit guard. Only the final authorized handoff to Sparkle's installer terminates immediately. An ordinary Quit
    /// while an install-capable session is live is a cancellation request (never Sparkle's implicit install-on-quit,
    /// and never a surprise restart), even when automatic installation consent still exists.
    static func termination(_ flags: UpdateSessionFlags) -> UpdateTermination {
        if flags.handedOff { return .allow }
        if flags.installCapable || flags.armedSessionUnresolved { return .cancelAndHold }
        return (flags.withdrawnDuringExtraction || flags.cancellationUnresolved) ? .hold : .allow
    }

    /// An earlier release's prepared transaction may be discarded to prepare another only with proof that its Sparkle
    /// session can no longer install: no install reply outstanding, no held reply, and no cancellation still resolving.
    static func mayDiscardEarlierPreparation(_ flags: UpdateSessionFlags) -> Bool {
        !flags.handedOff && !flags.installCapable && !flags.withdrawnDuringExtraction && !flags.cancellationUnresolved
    }

    /// Scheduled discovery only. Manual checks never auto-start. Skip/Later and a missing consent always win.
    static func automaticStart(version: String, policy: UpdatePolicy, preferences: UpdatePreferences, now: Date, hostAllowsPresentation: Bool) -> UpdateAutomaticStart {
        guard policy.automaticChecks, policy.automaticInstallation, preferences.suppression(for: version, now: now) == nil else { return .notAllowed }
        return hostAllowsPresentation ? .start : .waitForSafeMoment
    }

    /// Live presentation guard for the nonmodal notice: eligible disposition plus the host's current interaction state.
    static func shouldPresentNotice(candidate: UpdateCandidate, origin: UpdateCheckOrigin, policy: UpdatePolicy,
                                    preferences: UpdatePreferences, now: Date, hostAllowsPresentation: Bool, alreadyShowing: Bool) -> Bool {
        guard origin == .scheduled, candidate.isInstallable, !alreadyShowing, hostAllowsPresentation else { return false }
        return scheduledDisposition(version: candidate.version, policy: policy, preferences: preferences, now: now) == .notify
    }
}

// MARK: - Ownership bridge protocol (JSON over the bundled Node `update-ownership.mjs` CLI)

struct UpdateOwnershipPending: Decodable, Equatable {
    let transactionId: String
    let phase: String
    let fromVersion: String?
    let toVersion: String?
}

struct UpdateOwnershipOutcome: Decodable, Equatable {
    let transactionId: String
    let status: String
    let fromVersion: String?
    let toVersion: String?
    let at: String?
    let message: String?
}

struct UpdateOwnershipStatusResponse: Decodable, Equatable {
    let managed: Bool
    let reason: String?
    let version: String?
    let pending: UpdateOwnershipPending?
    let outcome: UpdateOwnershipOutcome?
}

/// `prepare` makes the durable receipt/backup AND arms the independent trusted watcher before it returns.
struct UpdateOwnershipPrepareResponse: Decodable, Equatable {
    let transactionId: String
    let armed: Bool
}

struct UpdateOwnershipAckResponse: Decodable, Equatable {
    let committed: Bool
    let pending: Bool
    /// With `pending:true`: "installer-quiescing" (retry), "rolling-back" or "not-replaced" (stop).
    let reason: String?

    init(committed: Bool, pending: Bool, reason: String? = nil) {
        self.committed = committed
        self.pending = pending
        self.reason = reason
    }
}

/// Launch acknowledgment is retried, not one-shot: the helper may be busy, or Sparkle's installer may still be quiescing,
/// while a healthy replacement is waiting to be confirmed inside the watcher's readiness window.
enum UpdateAckOutcome: Equatable {
    /// Resolved (committed, nothing pending, a permanent failure, or the readiness window ended): continue startup.
    case finished
    /// Recoverable: try again after `retryInterval`.
    case retry

    /// B's watcher waits this long for the new app's acknowledgment before rolling back.
    static let readinessWindow: TimeInterval = 45
    static let retryInterval: TimeInterval = 1
    /// Failures no retry can fix (not a managed install, ownership mismatch, malformed request, no helper/Node).
    static let permanentCodes: Set<String> = ["not-managed", "ownership-mismatch", "invalid-request", "invalid-transaction", "missing-helper", "node-unavailable"]
    /// `pending:true` reasons no retry can resolve: a rollback owns the transaction, or the running app is still the previous tree.
    static let stopReasons: Set<String> = ["rolling-back", "not-replaced"]

    private enum Attempt { case done, transient, permanent }

    private static func classify(_ result: Result<UpdateOwnershipAckResponse, UpdateOwnershipFailure>) -> Attempt {
        switch result {
        case .success(let response):
            if response.committed || !response.pending { return .done }
            if let reason = response.reason, stopReasons.contains(reason) { return .permanent }
            return .transient
        case .failure(let failure):
            return permanentCodes.contains(failure.code) ? .permanent : .transient
        }
    }

    /// What startup does after one attempt that finished `elapsed` seconds after the first.
    static func next(_ result: Result<UpdateOwnershipAckResponse, UpdateOwnershipFailure>, elapsed: TimeInterval) -> UpdateAckOutcome {
        switch classify(result) {
        case .done, .permanent: return .finished
        case .transient: return elapsed >= readinessWindow ? .finished : .retry
        }
    }
}

/// `abort` always revokes the restart authorization; it discards the transaction only when the app is unreplaced AND the
/// Sparkle installer job is provably not running.
struct UpdateOwnershipAbortResponse: Decodable, Equatable {
    let aborted: Bool
    let code: String?
    let reason: String?
}

/// What a finished `abort` attempt means for a held Quit and the retained transaction.
enum UpdateAbortOutcome: Equatable {
    /// Positive evidence: discarded, or the install is already proceeding/finished (nothing left to cancel or hold for).
    case resolved
    /// No proof yet (installer still running, inspection failed): keep holding and retry.
    case retry
    /// The request itself is wrong (a bug, e.g. an invalid installer label): retrying cannot help. Keep holding (no proof)
    /// and tell the user instead of spinning.
    case unrecoverable

    static let terminalCodes: Set<String> = ["replaced", "relaunching", "unknown-transaction"]

    static func classify(_ result: Result<UpdateOwnershipAbortResponse, UpdateOwnershipFailure>) -> UpdateAbortOutcome {
        switch result {
        case .success(let response):
            if response.aborted { return .resolved }
            if let code = response.code, terminalCodes.contains(code) { return .resolved }
            return .retry
        case .failure(let failure):
            if terminalCodes.contains(failure.code) { return .resolved }
            return failure.code == "invalid-request" ? .unrecoverable : .retry
        }
    }
}

/// `authorize` commits the final handoff: only after it may the watcher restart the app once the bundle was replaced.
struct UpdateOwnershipAuthorizeResponse: Decodable, Equatable {
    let authorized: Bool
    let reason: String?
}

/// `revoke` is durable, deletes nothing, and clears the restart authorization (a later `authorize` answers "cancelled").
/// Called as soon as a cancellation is decided, before the SDK is told.
struct UpdateOwnershipRevokeResponse: Decodable, Equatable {
    let revoked: Bool
    let code: String?
    let reason: String?
}

/// Controlled failure of a Node ownership command (never raw process output).
struct UpdateOwnershipFailure: Error, Equatable {
    let code: String
    let message: String
    let recovery: String?

    /// One actionable line for the UI.
    var displayText: String {
        let base = UpdateOwnershipCodec.sanitizedMessage(message, fallback: "The update ownership check failed.")
        guard let recovery, !recovery.isEmpty else { return base }
        return base + " " + UpdateOwnershipCodec.sanitizedMessage(recovery, fallback: "")
    }
}

enum UpdateOwnershipCodec {
    /// stdin object shared by every command, plus command-specific string fields.
    static func request(appPath: String, configPath: String, extra: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["appPath": appPath, "configPath": configPath]
        for (key, value) in extra { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Parses the single JSON stdout line. Exit status 0 requires `"ok":true`; anything else (bad exit, missing/odd
    /// JSON, `"ok":false`) becomes a controlled failure.
    static func parse<T: Decodable>(_ type: T.Type, stdout: Data, exitStatus: Int32) -> Result<T, UpdateOwnershipFailure> {
        let lines = String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        guard let line = lines.last, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ok = object["ok"] as? Bool else {
            return .failure(UpdateOwnershipFailure(code: "invalid-response", message: "The update ownership helper returned an unreadable response.", recovery: nil))
        }
        if ok && exitStatus == 0 {
            if let decoded = try? JSONDecoder().decode(T.self, from: data) { return .success(decoded) }
            return .failure(UpdateOwnershipFailure(code: "invalid-response", message: "The update ownership helper returned an incomplete response.", recovery: nil))
        }
        let error = object["error"] as? [String: Any]
        let code = (error?["code"] as? String) ?? "failed"
        let message = (error?["message"] as? String) ?? "The update ownership helper failed."
        return .failure(UpdateOwnershipFailure(code: code, message: message, recovery: error?["recovery"] as? String))
    }

    /// Controlled one-line text safe for the UI: no control characters, bounded length.
    static func sanitizedMessage(_ text: String?, fallback: String) -> String {
        guard let text else { return fallback }
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : $0 }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return fallback }
        return cleaned.count > 300 ? String(cleaned.prefix(300)) + "…" : cleaned
    }
}

// MARK: - Messages

enum UpdateMessages {
    static func upToDate(version: String) -> String { "OMP Usage Panel \(version) is up to date." }

    static func available(version: String, installed: String, suppression: UpdateSuppression? = nil, formatter: (Date) -> String = { $0.description }) -> String {
        var text = "Version \(version) is available (installed \(installed))."
        switch suppression {
        case .deferred(let until)?: text += " Reminder paused until \(formatter(until))."
        case .skipped?: text += " You skipped this version."
        case nil: break
        }
        return text
    }

    static func skipped(version: String) -> String { "Version \(version) was skipped. Check for Updates to install it anyway." }

    /// Result of the last installation transaction, as recorded durably by the ownership helper.
    static func outcome(_ outcome: UpdateOwnershipOutcome, installed: String) -> String {
        let to = outcome.toVersion ?? "the new version"
        switch outcome.status {
        case "updated": return "Updated to \(outcome.toVersion ?? installed)."
        case "rolled-back": return "The update to \(to) did not start correctly; the previous version \(installed) was restored."
        default:
            let detail = UpdateOwnershipCodec.sanitizedMessage(outcome.message, fallback: "")
            return "The update to \(to) failed." + (detail.isEmpty ? "" : " " + detail)
        }
    }

    /// An update that failed or rolled back should read as a problem; a successful one as ordinary news.
    static func outcomeIsProblem(_ outcome: UpdateOwnershipOutcome) -> Bool { outcome.status != "updated" }
}
