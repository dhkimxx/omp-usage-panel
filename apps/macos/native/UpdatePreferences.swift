import Foundation

enum UpdateUserAction: String, Codable, Equatable {
    case updateNow, skipped, deferred, notificationsDisabled, notificationsEnabled, automaticInstallationEnabled, automaticInstallationDisabled
}

/// App-wide (not profile-scoped) updater metadata owned by this app: notifications, the explicit automatic-installation
/// consent (Sparkle's silent automatic driver is disabled, so this app is its only authority), Skip/Later and last-action
/// metadata. Automatic CHECKS are deliberately NOT stored here: Sparkle's own defaults are their only authority.
struct UpdatePreferences: Codable, Equatable {
    /// "Later" lasts exactly this long. Clock changes cannot extend it beyond this (see `suppression`).
    static let deferralInterval: TimeInterval = 24 * 60 * 60

    var notificationsEnabled: Bool
    /// Explicit opt-in to install future updates automatically. Off until the user commits it; independent of notifications.
    var automaticInstallation: Bool
    /// Exactly one skipped release; a newer release is never covered.
    var skippedVersion: String?
    var deferredVersion: String?
    var deferredUntil: Date?
    var lastAction: UpdateUserAction?
    var lastActionVersion: String?
    var lastActionAt: Date?
    /// Transaction id of the last installation outcome already shown to the user (outcomes are shown once).
    var shownOutcomeID: String?

    init(notificationsEnabled: Bool = true, automaticInstallation: Bool = false, skippedVersion: String? = nil, deferredVersion: String? = nil, deferredUntil: Date? = nil,
         lastAction: UpdateUserAction? = nil, lastActionVersion: String? = nil, lastActionAt: Date? = nil, shownOutcomeID: String? = nil) {
        self.notificationsEnabled = notificationsEnabled
        self.automaticInstallation = automaticInstallation
        self.skippedVersion = skippedVersion
        self.deferredVersion = deferredVersion
        self.deferredUntil = deferredUntil
        self.lastAction = lastAction
        self.lastActionVersion = lastActionVersion
        self.lastActionAt = lastActionAt
        self.shownOutcomeID = shownOutcomeID
    }

    /// Skip/Later hold for `version` at `now`; nil when a scheduled discovery may proceed. A deferral expires at its
    /// deadline, and one whose deadline lies implausibly far ahead (clock moved backwards) is treated as expired.
    func suppression(for version: String, now: Date) -> UpdateSuppression? {
        if let skippedVersion, skippedVersion == version { return .skipped }
        if let deferredVersion, deferredVersion == version, let until = deferredUntil,
           until > now, until.timeIntervalSince(now) <= Self.deferralInterval + 60 {
            return .deferred(until: until)
        }
        return nil
    }
}

final class UpdatePreferencesStore {
    static let storageKey = "updatePreferences.v1"

    private let defaults: UserDefaults
    private(set) var preferences: UpdatePreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(UpdatePreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = UpdatePreferences()
        }
    }

    /// Persists only the notification choice; skip/Later metadata and the separate automatic-installation consent are untouched.
    func setNotificationsEnabled(_ enabled: Bool, now: Date) {
        guard preferences.notificationsEnabled != enabled else { return }
        var updated = preferences
        updated.notificationsEnabled = enabled
        updated.lastAction = enabled ? .notificationsEnabled : .notificationsDisabled
        updated.lastActionVersion = nil
        updated.lastActionAt = now
        save(updated)
    }

    /// Commits (or withdraws) the explicit automatic-installation consent. Never touches notifications or Skip/Later.
    func setAutomaticInstallation(_ enabled: Bool, now: Date) {
        guard preferences.automaticInstallation != enabled else { return }
        var updated = preferences
        updated.automaticInstallation = enabled
        updated.lastAction = enabled ? .automaticInstallationEnabled : .automaticInstallationDisabled
        updated.lastActionVersion = nil
        updated.lastActionAt = now
        save(updated)
    }

    /// Replaces any earlier skip (only one exact version is ever skipped) and clears a deferral of that version.
    func skip(version: String, now: Date) {
        var updated = preferences
        updated.skippedVersion = version
        if updated.deferredVersion == version { updated.deferredVersion = nil; updated.deferredUntil = nil }
        updated.lastAction = .skipped
        updated.lastActionVersion = version
        updated.lastActionAt = now
        save(updated)
    }

    /// 24-hour reminder deferral for exactly `version`. Returns the deadline.
    @discardableResult
    func deferVersion(_ version: String, now: Date) -> Date {
        let until = now.addingTimeInterval(UpdatePreferences.deferralInterval)
        var updated = preferences
        updated.deferredVersion = version
        updated.deferredUntil = until
        updated.lastAction = .deferred
        updated.lastActionVersion = version
        updated.lastActionAt = now
        save(updated)
        return until
    }

    /// Records a one-off Update Now; changes no policy.
    func recordUpdateNow(version: String, now: Date) {
        var updated = preferences
        updated.lastAction = .updateNow
        updated.lastActionVersion = version
        updated.lastActionAt = now
        save(updated)
    }

    /// Drops hold metadata that can never apply again once `installedVersion` is the held release (or newer metadata
    /// replaced it). Keeps the blob from retaining a stale skip for the running version.
    func clearHolds(forInstalledVersion installedVersion: String) {
        var updated = preferences
        if updated.skippedVersion == installedVersion { updated.skippedVersion = nil }
        if updated.deferredVersion == installedVersion { updated.deferredVersion = nil; updated.deferredUntil = nil }
        guard updated != preferences else { return }
        save(updated)
    }

    /// Returns true exactly once per transaction id so a durable install outcome is reported a single time.
    @discardableResult
    func markOutcomeShown(_ transactionID: String) -> Bool {
        guard preferences.shownOutcomeID != transactionID else { return false }
        var updated = preferences
        updated.shownOutcomeID = transactionID
        save(updated)
        return true
    }

    private func save(_ updated: UpdatePreferences) {
        preferences = updated
        if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: Self.storageKey) }
    }
}
