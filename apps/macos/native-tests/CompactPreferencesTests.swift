import Foundation

private func summary(_ provider: String, percent: Double?, accounts: Int = 1) -> ProviderSummary {
    ProviderSummary(provider: provider, label: provider.uppercased(), percent: percent, value: percent.map { "\($0)%" } ?? "unknown",
                    severity: "ok", accountCount: accounts, accountId: nil, accountLabel: nil, metricId: nil,
                    metricLabel: nil, windowLabel: nil, notes: [])
}

private func isolatedDefaults() -> (UserDefaults, () -> Void) {
    let name = "omp-compact-preferences-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (defaults, { defaults.removePersistentDomain(forName: name) })
}

func runCompactPreferencesTests() {
    let (defaults, cleanup) = isolatedDefaults()
    defer { cleanup() }

    // Defaults: uninitialized selection, maximum 3 is a default not a cap.
    let fresh = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/a/config.json", profile: "main")
    precondition(fresh.preferences == CompactPreferences())
    precondition(fresh.preferences.selectedProviderIDs == nil && fresh.preferences.side == .right)

    // Persist + restart, including values above 3, and nil vs [] distinction.
    fresh.save(CompactPreferences(maximumVisibleSlots: 12, selectedProviderIDs: ["a", "b", "a", "c"], side: .left))
    let restarted = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/a/config.json", profile: "main")
    precondition(restarted.preferences == CompactPreferences(maximumVisibleSlots: 12, selectedProviderIDs: ["a", "b", "c"], side: .left))
    restarted.save(CompactPreferences(maximumVisibleSlots: 12, selectedProviderIDs: [], side: .left))
    let emptyAfterRestart = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/a/config.json", profile: "main")
    precondition(emptyAfterRestart.preferences.selectedProviderIDs == [])
    precondition(!emptyAfterRestart.initializeSelectionIfNeeded(summaries: [summary("x", percent: 5)]))
    precondition(emptyAfterRestart.preferences.selectedProviderIDs == [])

    // Isolation by standardized path and profile; delimiter-ambiguous inputs do not collide.
    precondition(CompactPreferencesStore(defaults: defaults, configPath: "/tmp/a/../a/config.json", profile: " main ").preferences.maximumVisibleSlots == 12)
    precondition(CompactPreferencesStore(defaults: defaults, configPath: "/tmp/a/config.json", profile: "other").preferences == CompactPreferences())
    precondition(CompactPreferencesStore(defaults: defaults, configPath: "/tmp/b/config.json", profile: "main").preferences == CompactPreferences())
    precondition(CompactPreferencesStore.storageKey(configPath: "a|b", profile: "c") != CompactPreferencesStore.storageKey(configPath: "a", profile: "b|c"))
    precondition(CompactPreferencesStore.storageKey(configPath: "a\u{0}b", profile: "c") != CompactPreferencesStore.storageKey(configPath: "a", profile: "b\u{0}c"))

    // Non-positive saved counts normalize to 1 rather than 0.
    let clamp = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/clamp.json", profile: "p")
    clamp.save(CompactPreferences(maximumVisibleSlots: 0))
    precondition(clamp.preferences.maximumVisibleSlots == 1)

    // Delayed seed: nothing eligible leaves nil; unknown/unavailable skipped; known 0 qualifies; distinct; up to maximum.
    let seed = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/seed.json", profile: "p")
    precondition(!seed.initializeSelectionIfNeeded(summaries: []))
    precondition(!seed.initializeSelectionIfNeeded(summaries: [summary("u", percent: nil), summary("n", percent: .nan), summary("z", percent: 10, accounts: 0)]))
    precondition(seed.preferences.selectedProviderIDs == nil)
    precondition(seed.initializeSelectionIfNeeded(summaries: [summary("u", percent: nil), summary("zero", percent: 0), summary("zero", percent: 50),
                                                              summary("b", percent: 104), summary("c", percent: 1), summary("d", percent: 2)]))
    precondition(seed.preferences.selectedProviderIDs == ["zero", "b", "c"])
    precondition(!seed.initializeSelectionIfNeeded(summaries: [summary("e", percent: 1)]))
    precondition(CompactPreferencesStore(defaults: defaults, configPath: "/tmp/seed.json", profile: "p").preferences.selectedProviderIDs == ["zero", "b", "c"])

    // Seed honors a configured maximum above 3 and of 1.
    let wide = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/wide.json", profile: "p")
    wide.save(CompactPreferences(maximumVisibleSlots: 5))
    precondition(wide.initializeSelectionIfNeeded(summaries: (0..<8).map { summary("p\($0)", percent: Double($0)) }))
    precondition(wide.preferences.selectedProviderIDs == ["p0", "p1", "p2", "p3", "p4"])
    let single = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/single.json", profile: "p")
    single.save(CompactPreferences(maximumVisibleSlots: 1))
    precondition(single.initializeSelectionIfNeeded(summaries: [summary("k", percent: 0), summary("l", percent: 1)]))
    precondition(single.preferences.selectedProviderIDs == ["k"])

    // Missing IDs are retained verbatim when a later report omits them (no reseed, no pruning).
    seed.save(CompactPreferences(maximumVisibleSlots: 3, selectedProviderIDs: ["gone", "zero"], side: .right))
    precondition(!seed.initializeSelectionIfNeeded(summaries: [summary("zero", percent: 1)]))
    precondition(seed.preferences.selectedProviderIDs == ["gone", "zero"])
}
