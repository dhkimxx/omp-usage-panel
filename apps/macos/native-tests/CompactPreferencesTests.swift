import Foundation

private func summary(_ provider: String, percent: Double?, accounts: Int = 1) -> ProviderSummary {
    ProviderSummary(provider: provider, label: provider.uppercased(), percent: percent, value: percent.map { "\($0)%" } ?? "unknown",
                    severity: "ok", accountCount: accounts, accountId: nil, accountLabel: nil, metricId: nil,
                    metricLabel: nil, windowLabel: nil, notes: [])
}

private func isolatedDefaults() -> (UserDefaults, () -> Void) { makeIsolatedDefaults(prefix: "omp-compact-preferences-tests") }

private func save(_ store: CompactPreferencesStore, _ preferences: CompactPreferences) {
    guard let prepared = try? store.prepare(preferences) else { preconditionFailure("Expected encodable preferences") }
    store.savePrepared(prepared)
}

func runCompactPreferencesTests() {
    let (defaults, cleanup) = isolatedDefaults()
    defer { cleanup() }

    // Defaults: uninitialized selection, maximum 3 is a default not a cap, everything on the right.
    let fresh = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/a/config.json", profile: "main")
    precondition(fresh.preferences == CompactPreferences())
    precondition(fresh.preferences.selectedProviderIDs == nil && fresh.preferences.defaultSide == .right)
    precondition(fresh.preferences.providerSides.isEmpty)
    precondition(fresh.preferences.side(for: "anything") == .right)
    // Merely reading never writes defaults.
    precondition(defaults.data(forKey: CompactPreferencesStore.storageKey(configPath: "/tmp/a/config.json", profile: "main")) == nil)

    // Persist + restart, including values above 3, mixed sides and nil vs [] distinction.
    let mixed = CompactPreferences(maximumVisibleSlots: 12, selectedProviderIDs: ["a", "b", "a", "c"],
                                   defaultSide: .left, providerSides: ["b": .right, "unselected": .right])
    save(fresh, mixed)
    let normalizedMixed = CompactPreferences(maximumVisibleSlots: 12, selectedProviderIDs: ["a", "b", "c"],
                                             defaultSide: .left, providerSides: ["b": .right, "unselected": .right])
    precondition(fresh.preferences == normalizedMixed)
    let restarted = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/a/config.json", profile: "main")
    precondition(restarted.preferences == normalizedMixed)
    // Unselected/unreported provider overrides survive; unlisted providers follow the default side.
    precondition(restarted.preferences.side(for: "a") == .left && restarted.preferences.side(for: "b") == .right)
    precondition(restarted.preferences.side(for: "unselected") == .right && restarted.preferences.side(for: "never-seen") == .left)
    save(restarted, CompactPreferences(maximumVisibleSlots: 12, selectedProviderIDs: [], defaultSide: .left,
                                       providerSides: ["b": .right]))
    let emptyAfterRestart = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/a/config.json", profile: "main")
    precondition(emptyAfterRestart.preferences.selectedProviderIDs == [])
    precondition(emptyAfterRestart.preferences.providerSides == ["b": .right])
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
    save(clamp, CompactPreferences(maximumVisibleSlots: 0))
    precondition(clamp.preferences.maximumVisibleSlots == 1)

    // Legacy migration: a saved global `side` becomes the default side, nothing is lost, and
    // reading performs no rewrite. Six selections, maximum six and all-left stay exactly as saved.
    // The real pre-migration selection order (six providers, maximum six, all left) must survive verbatim.
    let legacyIDs = ["openai-codex", "commandcode", "mistral", "anthropic", "minimax-code-cn", "opencode-go"]
    func legacyJSON(side: String?, defaultSide: String? = nil, overrides: String? = nil) -> Data {
        var fields = ["\"maximumVisibleSlots\":6",
                      "\"selectedProviderIDs\":[" + legacyIDs.map { "\"\($0)\"" }.joined(separator: ",") + "]"]
        if let side { fields.append("\"side\":\"\(side)\"") }
        if let defaultSide { fields.append("\"defaultSide\":\"\(defaultSide)\"") }
        if let overrides { fields.append("\"providerSides\":\(overrides)") }
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }
    let legacyKey = CompactPreferencesStore.storageKey(configPath: "/tmp/legacy.json", profile: "main")
    let legacyData = legacyJSON(side: "left")
    defaults.set(legacyData, forKey: legacyKey)
    let legacy = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/legacy.json", profile: "main")
    precondition(legacy.preferences == CompactPreferences(maximumVisibleSlots: 6, selectedProviderIDs: legacyIDs,
                                                          defaultSide: .left, providerSides: [:]))
    precondition(legacyIDs.allSatisfy { legacy.preferences.side(for: $0) == .left })
    precondition(defaults.data(forKey: legacyKey) == legacyData)
    // A legacy right side and a missing side both stay right; an explicit defaultSide wins over `side`.
    defaults.set(legacyJSON(side: "right"), forKey: legacyKey)
    precondition(CompactPreferencesStore(defaults: defaults, configPath: "/tmp/legacy.json", profile: "main").preferences.defaultSide == .right)
    defaults.set(legacyJSON(side: nil), forKey: legacyKey)
    precondition(CompactPreferencesStore(defaults: defaults, configPath: "/tmp/legacy.json", profile: "main").preferences.defaultSide == .right)
    defaults.set(legacyJSON(side: "left", defaultSide: "right", overrides: "{\"openai-codex\":\"left\",\"x\":\"sideways\",\"y\":\"right\"}"), forKey: legacyKey)
    let explicit = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/legacy.json", profile: "main")
    precondition(explicit.preferences.defaultSide == .right)
    // One unrecognized override value does not discard the other saved overrides.
    precondition(explicit.preferences.providerSides == ["openai-codex": .left, "y": .right])
    // The first explicit save keeps every ID and the migrated default side across a restart.
    defaults.set(legacyData, forKey: legacyKey)
    let migrating = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/legacy.json", profile: "main")
    save(migrating, migrating.preferences)
    precondition(migrating.preferences == CompactPreferences(maximumVisibleSlots: 6, selectedProviderIDs: legacyIDs, defaultSide: .left))
    precondition(CompactPreferencesStore(defaults: defaults, configPath: "/tmp/legacy.json", profile: "main").preferences == migrating.preferences)

    // Rollback compatibility: the updater-enabled previous app decodes this payload with a Codable that REQUIRES `side`.
    // Whatever the current app writes must stay readable by that exact schema with IDs, maximum and side intact.
    struct RollbackReaderPreferences: Decodable {
        var maximumVisibleSlots: Int
        var selectedProviderIDs: [String]?
        var side: CompactWingSide
    }
    func rollbackRead(_ preferences: CompactPreferences) -> RollbackReaderPreferences {
        let store = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/rollback.json", profile: "main")
        guard let prepared = try? store.prepare(preferences),
              let old = try? JSONDecoder().decode(RollbackReaderPreferences.self, from: prepared.data) else {
            preconditionFailure("Rollback reader could not decode the current payload")
        }
        return old
    }
    let rollbackLeft = rollbackRead(CompactPreferences(maximumVisibleSlots: 6, selectedProviderIDs: legacyIDs, defaultSide: .left))
    precondition(rollbackLeft.selectedProviderIDs == legacyIDs && rollbackLeft.maximumVisibleSlots == 6 && rollbackLeft.side == .left)
    let rollbackOverride = rollbackRead(CompactPreferences(maximumVisibleSlots: 6, selectedProviderIDs: legacyIDs, defaultSide: .left,
                                                           providerSides: [legacyIDs[0]: .right]))
    precondition(rollbackOverride.selectedProviderIDs == legacyIDs && rollbackOverride.maximumVisibleSlots == 6 && rollbackOverride.side == .left)
    let rollbackRight = rollbackRead(CompactPreferences(maximumVisibleSlots: 6, selectedProviderIDs: legacyIDs, defaultSide: .right,
                                                        providerSides: [legacyIDs[1]: .left]))
    precondition(rollbackRight.selectedProviderIDs == legacyIDs && rollbackRight.side == .right)
    precondition(rollbackRead(CompactPreferences(maximumVisibleSlots: 3, selectedProviderIDs: nil, defaultSide: .left)).selectedProviderIDs == nil)
    let rollbackEmpty = rollbackRead(CompactPreferences(maximumVisibleSlots: 3, selectedProviderIDs: [], defaultSide: .left))
    precondition(rollbackEmpty.selectedProviderIDs == [] && rollbackEmpty.side == .left)
    // The current reader still retains per-provider overrides from the same payload.
    let overrideStore = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/rollback.json", profile: "main")
    let overridePrefs = CompactPreferences(maximumVisibleSlots: 6, selectedProviderIDs: legacyIDs, defaultSide: .left,
                                           providerSides: [legacyIDs[0]: .right])
    save(overrideStore, overridePrefs)
    let overrideReloaded = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/rollback.json", profile: "main")
    precondition(overrideReloaded.preferences == overridePrefs && overrideReloaded.preferences.side(for: legacyIDs[0]) == .right)
    // Uninitialized legacy selection stays nil (never reseeded to something else on read).
    defaults.set(Data("{\"maximumVisibleSlots\":3,\"side\":\"left\"}".utf8), forKey: legacyKey)
    let legacyNil = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/legacy.json", profile: "main")
    precondition(legacyNil.preferences.selectedProviderIDs == nil && legacyNil.preferences.defaultSide == .left)
    // Garbage falls back to defaults without being rewritten.
    defaults.set(Data("not json".utf8), forKey: legacyKey)
    precondition(CompactPreferencesStore(defaults: defaults, configPath: "/tmp/legacy.json", profile: "main").preferences == CompactPreferences())
    precondition(defaults.data(forKey: legacyKey) == Data("not json".utf8))

    // Prepared persistence: preparing validates and encodes without touching memory or defaults;
    // saving the prepared value cannot fail and updates both; identical input encodes identically.
    let staged = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/staged.json", profile: "p")
    let before = staged.preferences
    guard let prepared = try? staged.prepare(CompactPreferences(maximumVisibleSlots: -3, selectedProviderIDs: ["z", "z", "y"],
                                                                defaultSide: .left, providerSides: ["y": .right])),
          let again = try? staged.prepare(prepared.preferences) else {
        preconditionFailure("Expected prepared preferences")
    }
    precondition(staged.preferences == before && defaults.data(forKey: CompactPreferencesStore.storageKey(configPath: "/tmp/staged.json", profile: "p")) == nil)
    precondition(prepared.preferences == CompactPreferences(maximumVisibleSlots: 1, selectedProviderIDs: ["z", "y"],
                                                            defaultSide: .left, providerSides: ["y": .right]))
    precondition(again == prepared)
    staged.savePrepared(prepared)
    precondition(staged.preferences == prepared.preferences)
    precondition(defaults.data(forKey: CompactPreferencesStore.storageKey(configPath: "/tmp/staged.json", profile: "p")) == prepared.data)
    precondition(CompactPreferencesStore(defaults: defaults, configPath: "/tmp/staged.json", profile: "p").preferences == prepared.preferences)

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

    // Seed honors a configured maximum above 3 and of 1, and preserves wing choices made before it.
    let wide = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/wide.json", profile: "p")
    save(wide, CompactPreferences(maximumVisibleSlots: 5, defaultSide: .left, providerSides: ["p1": .right]))
    precondition(wide.initializeSelectionIfNeeded(summaries: (0..<8).map { summary("p\($0)", percent: Double($0)) }))
    precondition(wide.preferences.selectedProviderIDs == ["p0", "p1", "p2", "p3", "p4"])
    precondition(wide.preferences.defaultSide == .left && wide.preferences.side(for: "p1") == .right)
    let single = CompactPreferencesStore(defaults: defaults, configPath: "/tmp/single.json", profile: "p")
    save(single, CompactPreferences(maximumVisibleSlots: 1))
    precondition(single.initializeSelectionIfNeeded(summaries: [summary("k", percent: 0), summary("l", percent: 1)]))
    precondition(single.preferences.selectedProviderIDs == ["k"])

    // Missing IDs are retained verbatim when a later report omits them (no reseed, no pruning).
    save(seed, CompactPreferences(maximumVisibleSlots: 3, selectedProviderIDs: ["gone", "zero"], defaultSide: .right))
    precondition(!seed.initializeSelectionIfNeeded(summaries: [summary("zero", percent: 1)]))
    precondition(seed.preferences.selectedProviderIDs == ["gone", "zero"])
}
