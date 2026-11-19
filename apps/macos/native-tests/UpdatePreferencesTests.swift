import Foundation

private func isolatedDefaults() -> (UserDefaults, () -> Void) { makeIsolatedDefaults(prefix: "omp-update-preferences-tests") }

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 24 * 60 * 60

func runUpdatePreferencesTests() {
    let (defaults, cleanup) = isolatedDefaults()
    defer { cleanup() }

    // Fresh install: notifications on, nothing skipped or deferred, nothing recorded.
    let fresh = UpdatePreferencesStore(defaults: defaults)
    precondition(fresh.preferences == UpdatePreferences())
    precondition(fresh.preferences.notificationsEnabled && fresh.preferences.suppression(for: "0.2.0", now: t0) == nil)
    precondition(defaults.data(forKey: UpdatePreferencesStore.storageKey) == nil, "reading never writes")

    // Notifications off persists across restart, can be re-enabled, and never touches skip/defer metadata.
    fresh.setNotificationsEnabled(false, now: t0)
    precondition(UpdatePreferencesStore(defaults: defaults).preferences.notificationsEnabled == false)
    precondition(UpdatePreferencesStore(defaults: defaults).preferences.lastAction == .notificationsDisabled)
    fresh.skip(version: "0.2.0", now: t0)
    fresh.setNotificationsEnabled(true, now: t0.addingTimeInterval(5))
    let reenabled = UpdatePreferencesStore(defaults: defaults).preferences
    precondition(reenabled.notificationsEnabled && reenabled.skippedVersion == "0.2.0" && reenabled.lastAction == .notificationsEnabled && reenabled.lastActionAt == t0.addingTimeInterval(5))
    let writesBefore = defaults.data(forKey: UpdatePreferencesStore.storageKey)
    fresh.setNotificationsEnabled(true, now: t0.addingTimeInterval(99))
    precondition(defaults.data(forKey: UpdatePreferencesStore.storageKey) == writesBefore, "an unchanged choice is not rewritten")

    // Skip is one exact version; a second skip replaces the first; it clears a deferral of the same release only.
    let (skipDefaults, skipCleanup) = isolatedDefaults()
    defer { skipCleanup() }
    let skipping = UpdatePreferencesStore(defaults: skipDefaults)
    skipping.skip(version: "0.2.0", now: t0)
    precondition(skipping.preferences.suppression(for: "0.2.0", now: t0) == .skipped)
    precondition(skipping.preferences.suppression(for: "0.2.1", now: t0) == nil && skipping.preferences.suppression(for: "0.1.9", now: t0) == nil)
    precondition(skipping.preferences.suppression(for: "0.2.0", now: t0.addingTimeInterval(400 * day)) == .skipped, "a skip does not expire by time")
    skipping.skip(version: "0.3.0", now: t0)
    precondition(skipping.preferences.skippedVersion == "0.3.0" && skipping.preferences.suppression(for: "0.2.0", now: t0) == nil)
    precondition(UpdatePreferencesStore(defaults: skipDefaults).preferences.skippedVersion == "0.3.0")
    skipping.deferVersion("0.4.0", now: t0)
    skipping.skip(version: "0.5.0", now: t0)
    precondition(skipping.preferences.deferredVersion == "0.4.0", "skipping another release leaves an unrelated deferral")
    skipping.skip(version: "0.4.0", now: t0)
    precondition(skipping.preferences.deferredVersion == nil && skipping.preferences.deferredUntil == nil && skipping.preferences.skippedVersion == "0.4.0")

    // Later: exactly 24 hours, persisted, exact version, boundary behavior, and a newer release is not covered.
    let (laterDefaults, laterCleanup) = isolatedDefaults()
    defer { laterCleanup() }
    let later = UpdatePreferencesStore(defaults: laterDefaults)
    let until = later.deferVersion("0.2.0", now: t0)
    precondition(until == t0.addingTimeInterval(day) && UpdatePreferences.deferralInterval == day)
    let restarted = UpdatePreferencesStore(defaults: laterDefaults).preferences
    precondition(restarted.deferredVersion == "0.2.0" && restarted.deferredUntil == until && restarted.lastAction == .deferred && restarted.lastActionVersion == "0.2.0")
    precondition(restarted.suppression(for: "0.2.0", now: t0) == .deferred(until: until))
    precondition(restarted.suppression(for: "0.2.0", now: until.addingTimeInterval(-1)) == .deferred(until: until))
    precondition(restarted.suppression(for: "0.2.0", now: until) == nil, "the deferral ends at its deadline")
    precondition(restarted.suppression(for: "0.2.0", now: until.addingTimeInterval(1)) == nil)
    precondition(restarted.suppression(for: "0.2.1", now: t0) == nil)
    // Clock moved backwards by more than the interval: an implausibly distant deadline is treated as expired.
    precondition(restarted.suppression(for: "0.2.0", now: t0.addingTimeInterval(-2 * day)) == nil)
    precondition(restarted.suppression(for: "0.2.0", now: t0.addingTimeInterval(-60)) != nil, "small clock adjustments keep the deferral")
    // A later deferral of another release replaces the previous one.
    later.deferVersion("0.3.0", now: t0.addingTimeInterval(10))
    precondition(later.preferences.deferredVersion == "0.3.0" && later.preferences.suppression(for: "0.2.0", now: t0.addingTimeInterval(11)) == nil)

    // Update Now is recorded as metadata only: no hold, no notification change.
    let (nowDefaults, nowCleanup) = isolatedDefaults()
    defer { nowCleanup() }
    let nowStore = UpdatePreferencesStore(defaults: nowDefaults)
    nowStore.recordUpdateNow(version: "0.2.0", now: t0)
    let afterNow = UpdatePreferencesStore(defaults: nowDefaults).preferences
    precondition(afterNow.lastAction == .updateNow && afterNow.lastActionVersion == "0.2.0" && afterNow.notificationsEnabled)
    precondition(afterNow.skippedVersion == nil && afterNow.deferredVersion == nil)

    // Holds for the running version are dropped once it is installed; other holds stay.
    let (holdDefaults, holdCleanup) = isolatedDefaults()
    defer { holdCleanup() }
    let holds = UpdatePreferencesStore(defaults: holdDefaults)
    holds.skip(version: "0.2.0", now: t0)
    holds.deferVersion("0.3.0", now: t0)
    holds.clearHolds(forInstalledVersion: "0.1.0")
    precondition(holds.preferences.skippedVersion == "0.2.0" && holds.preferences.deferredVersion == "0.3.0")
    holds.clearHolds(forInstalledVersion: "0.2.0")
    precondition(holds.preferences.skippedVersion == nil && holds.preferences.deferredVersion == "0.3.0")
    holds.clearHolds(forInstalledVersion: "0.3.0")
    precondition(holds.preferences.deferredVersion == nil && holds.preferences.deferredUntil == nil)
    precondition(UpdatePreferencesStore(defaults: holdDefaults).preferences.deferredVersion == nil)

    // A durable install outcome is announced exactly once per transaction.
    let (outcomeDefaults, outcomeCleanup) = isolatedDefaults()
    defer { outcomeCleanup() }
    let outcomes = UpdatePreferencesStore(defaults: outcomeDefaults)
    precondition(outcomes.markOutcomeShown("t1"))
    precondition(!outcomes.markOutcomeShown("t1"))
    precondition(!UpdatePreferencesStore(defaults: outcomeDefaults).markOutcomeShown("t1"), "still once after relaunch")
    precondition(outcomes.markOutcomeShown("t2"))

    // Corrupt or foreign data falls back to safe defaults instead of failing; a later save repairs it.
    let (badDefaults, badCleanup) = isolatedDefaults()
    defer { badCleanup() }
    badDefaults.set(Data("not json".utf8), forKey: UpdatePreferencesStore.storageKey)
    let repaired = UpdatePreferencesStore(defaults: badDefaults)
    precondition(repaired.preferences == UpdatePreferences())
    repaired.skip(version: "1.0.0", now: t0)
    precondition(UpdatePreferencesStore(defaults: badDefaults).preferences.skippedVersion == "1.0.0")
    badDefaults.set("a string", forKey: UpdatePreferencesStore.storageKey)
    precondition(UpdatePreferencesStore(defaults: badDefaults).preferences.notificationsEnabled)

    // The blob carries the app-owned installation consent, never Sparkle's automatic CHECK or silent-download choices
    // (Sparkle's defaults remain the only authority for checks).
    let keys = String(decoding: defaults.data(forKey: UpdatePreferencesStore.storageKey) ?? Data(), as: UTF8.self)
    precondition(keys.contains("automaticInstallation") && !keys.contains("automaticChecks") && !keys.lowercased().contains("automaticallychecks") && !keys.contains("SU"))

    // Automatic installation: off until explicitly committed; persisted; withdrawable; independent of notifications and holds.
    let (autoDefaults, autoCleanup) = isolatedDefaults()
    defer { autoCleanup() }
    let auto = UpdatePreferencesStore(defaults: autoDefaults)
    precondition(!auto.preferences.automaticInstallation && UpdatePreferences().automaticInstallation == false)
    auto.setNotificationsEnabled(false, now: t0)
    auto.skip(version: "0.2.0", now: t0)
    precondition(!auto.preferences.automaticInstallation, "notifications and Skip never grant installation consent")
    auto.setAutomaticInstallation(true, now: t0.addingTimeInterval(1))
    var committed = UpdatePreferencesStore(defaults: autoDefaults).preferences
    precondition(committed.automaticInstallation && !committed.notificationsEnabled && committed.skippedVersion == "0.2.0")
    precondition(committed.lastAction == .automaticInstallationEnabled && committed.lastActionAt == t0.addingTimeInterval(1))
    auto.setNotificationsEnabled(true, now: t0.addingTimeInterval(2))
    precondition(UpdatePreferencesStore(defaults: autoDefaults).preferences.automaticInstallation, "re-enabling notifications keeps the consent")
    let autoBlob = autoDefaults.data(forKey: UpdatePreferencesStore.storageKey)
    auto.setAutomaticInstallation(true, now: t0.addingTimeInterval(50))
    precondition(autoDefaults.data(forKey: UpdatePreferencesStore.storageKey) == autoBlob, "an unchanged consent is not rewritten")
    auto.setAutomaticInstallation(false, now: t0.addingTimeInterval(60))
    committed = UpdatePreferencesStore(defaults: autoDefaults).preferences
    precondition(!committed.automaticInstallation && committed.notificationsEnabled && committed.skippedVersion == "0.2.0" && committed.lastAction == .automaticInstallationDisabled)

    // Stores in separate domains never share state.
    let (otherDefaults, otherCleanup) = isolatedDefaults()
    defer { otherCleanup() }
    precondition(UpdatePreferencesStore(defaults: otherDefaults).preferences == UpdatePreferences())
}
