import Foundation

private func draftConfig(
    providers: [String]? = nil, labels: ExactConfigMap = [:], metrics: ExactConfigMap = [:],
    nodePath: String = "/usr/bin/node", profile: String = "default", refreshSeconds: Double = 60,
    cacheMinutes: Double = 5, timeoutSeconds: Double = 25, warnPercent: Double = 70, criticalPercent: Double = 90,
    showPace: Bool = true
) -> PanelConfig {
    PanelConfig(version: 1, nodePath: nodePath, ompPath: "/usr/local/bin/omp", profile: profile, refreshSeconds: refreshSeconds,
                cacheMinutes: cacheMinutes, timeoutSeconds: timeoutSeconds, providers: providers, labels: labels,
                metrics: metrics, warnPercent: warnPercent, criticalPercent: criticalPercent, showPace: showPace)
}

/// Draft semantics at the consumer boundary: lossless round trip of committed values, explicit null vs [],
/// duplicate rows rejected before any dictionary exists, strict numeric text, and observed-ID suggestions.
func runGeneralSettingsDraftTests() {
    typealias Draft = GeneralSettingsDraft

    func committed(_ draft: Draft) -> PanelConfig? { try? draft.candidate() }
    func issues(_ draft: Draft) -> [Draft.Issue] {
        do { _ = try draft.candidate(); return [] } catch let failure as Draft.Failure { return failure.issues } catch { return [] }
    }
    func fields(_ draft: Draft) -> [Draft.Field] { issues(draft).map(\.field) }

    // Untouched drafts commit exactly the original (raw values, fractions, null vs [], map-only entries, order).
    let samples = [
        draftConfig(),
        draftConfig(providers: []),
        draftConfig(providers: ["zeta", " spaced ", "openai-codex", "unreported/ID"], labels: ["map-only": " Raw Label ", "openai-codex": "Codex"],
                    metrics: ["map-only": "limit-1", "mistral": "monthly"], profile: "  padded profile ", refreshSeconds: 0.25,
                    cacheMinutes: 0, timeoutSeconds: 1e-7, warnPercent: 150.5, criticalPercent: 1e300, showPace: false),
        draftConfig(warnPercent: 0, criticalPercent: 0),
    ]
    for sample in samples { precondition(committed(Draft(config: sample)) == sample, "unchanged draft must commit the original config") }

    // Provider mode: automatic is nil, custom with no rows is [] (both expressible); rows survive mode switches.
    var draft = Draft(config: draftConfig(providers: nil))
    precondition(draft.providerMode == .automatic && committed(draft)?.providers == nil)
    draft.providerMode = .custom
    precondition(committed(draft)?.providers == [], "custom without rows is an explicit empty list")
    let first = draft.addRow(.providers, key: "b")
    let second = draft.addRow(.providers, key: "a")
    let third = draft.addRow(.providers, key: " c ")
    precondition(committed(draft)?.providers == ["b", "a", " c "], "row order is authoritative, raw text kept")
    draft.moveRow(.providers, id: third, by: -2)
    precondition(committed(draft)?.providers == [" c ", "b", "a"])
    draft.moveRow(.providers, id: third, by: -5)
    draft.moveRow(.providers, id: second, by: 9)
    precondition(committed(draft)?.providers == [" c ", "b", "a"], "moves clamp at the ends")
    draft.setRow(.providers, id: first, key: "B2")
    draft.removeRow(.providers, id: second)
    precondition(committed(draft)?.providers == [" c ", "B2"])
    draft.providerMode = .automatic
    precondition(committed(draft)?.providers == nil && draft.rows(.providers).count == 2, "automatic yields null and keeps rows")
    draft.providerMode = .custom
    precondition(committed(draft)?.providers == [" c ", "B2"], "rows return with custom mode")

    // Provider rows: duplicates (exact), blanks and empty rows are errors; case-different IDs are distinct.
    var providers = Draft(config: draftConfig(providers: ["a"]))
    let duplicate = providers.addRow(.providers, key: "a")
    precondition(issues(providers).count == 1 && issues(providers).first?.rowID == duplicate && issues(providers).first?.field == .providers, "duplicate provider row reported on the later row")
    providers.setRow(.providers, id: duplicate, key: "A")
    precondition(committed(providers)?.providers == ["a", "A"])
    providers.setRow(.providers, id: duplicate, key: "   ")
    precondition(issues(providers).first?.rowID == duplicate && committed(providers) == nil, "blank provider row rejected")
    providers.setRow(.providers, id: duplicate, key: "")
    precondition(committed(providers) == nil, "empty provider row is not silently dropped")

    // Independent maps: map-only providers, unreported IDs and unselected providers are all kept.
    var maps = Draft(config: draftConfig(providers: ["openai-codex"], labels: ["mistral": "M"], metrics: ["mistral": "monthly"]))
    maps.addRow(.labels, key: "never-seen", value: " Custom ")
    maps.addRow(.metrics, key: "openai-codex", value: "primary")
    let committedMaps = committed(maps)
    precondition(committedMaps?.labels == ["mistral": "M", "never-seen": " Custom "] && committedMaps?.metrics == ["mistral": "monthly", "openai-codex": "primary"])
    precondition(committedMaps?.providers == ["openai-codex"], "map entries never depend on the provider list")
    // Automatic metric = remove the override row (no sentinel).
    let metricRowID = maps.rows(.metrics).first { $0.key == "mistral" }!.id
    maps.removeRow(.metrics, id: metricRowID)
    precondition(committed(maps)?.metrics == ["openai-codex": "primary"])

    // Duplicate editor rows error before dictionary creation; nothing is last-row-wins.
    for list in [Draft.RowList.labels, .metrics] {
        let field: Draft.Field = list == .labels ? .labels : .metrics
        var duplicates = Draft(config: draftConfig())
        let one = duplicates.addRow(list, key: "dup", value: "first")
        let two = duplicates.addRow(list, key: "dup", value: "second")
        let found = issues(duplicates)
        precondition(committed(duplicates) == nil && found.count == 1 && found[0].field == field && found[0].rowID == two, "duplicate \(list) row reported on the later row")
        duplicates.setRow(list, id: two, key: "dup2")
        precondition((list == .labels ? committed(duplicates)?.labels : committed(duplicates)?.metrics) == ["dup": "first", "dup2": "second"])
        duplicates.setRow(list, id: one, value: "")
        precondition(issues(duplicates).first?.rowID == one && committed(duplicates) == nil, "blank value row rejected, not dropped")
        duplicates.setRow(list, id: one, key: "", value: "x")
        precondition(issues(duplicates).first?.rowID == one && committed(duplicates) == nil, "blank key row rejected, not dropped")
    }
    // Canonically-equivalent but exactly-distinct IDs are separate, legal entries (Node keeps them distinct); only exact duplicates error.
    let precomposed = "\u{00E9}"
    let decomposed = "e\u{0301}"
    var equivalent = Draft(config: draftConfig())
    equivalent.addRow(.labels, key: precomposed, value: "precomposed")
    equivalent.addRow(.labels, key: decomposed, value: "decomposed")
    equivalent.addRow(.metrics, key: decomposed, value: "m1")
    equivalent.addRow(.metrics, key: precomposed, value: "m2")
    equivalent.providerMode = .custom
    equivalent.addRow(.providers, key: decomposed)
    equivalent.addRow(.providers, key: precomposed)
    let equivalentConfig = committed(equivalent)
    precondition(equivalentConfig?.labels.count == 2 && equivalentConfig?.labels[precomposed] == "precomposed" && equivalentConfig?.labels[decomposed] == "decomposed", "distinct labels both kept")
    precondition(equivalentConfig?.metrics.count == 2 && equivalentConfig?.metrics[decomposed] == "m1" && equivalentConfig?.metrics[precomposed] == "m2", "distinct metrics both kept")
    precondition(equivalentConfig?.providers?.count == 2 && equivalentConfig?.providers?[0].isExactlyEqual(to: decomposed) == true, "distinct provider IDs both kept, in order")
    precondition(equivalentConfig.map { committed(Draft(config: $0)) == $0 } == true, "a draft of such a config commits it unchanged")
    let exactDuplicate = equivalent.addRow(.labels, key: decomposed, value: "again")
    precondition(committed(equivalent) == nil && issues(equivalent).first?.rowID == exactDuplicate, "exact duplicates are still rejected")

    // Numeric text: strict decimals only; failures are field-level and block the commit.
    func commit(_ field: Draft.Field, _ text: String) -> (PanelConfig?, Bool) {
        var edited = Draft(config: draftConfig())
        edited.setText(text, for: field)
        return (committed(edited), fields(edited).contains(field))
    }
    for bad in ["", "abc", "NaN", "inf", "-inf", "Infinity", "0x10", "1,5", "1_0", "1 2", "--1", "1e", ".", "+", "1e999"] {
        for field in [Draft.Field.refreshSeconds, .cacheMinutes, .timeoutSeconds, .warnPercent, .criticalPercent] {
            let result = commit(field, bad)
            precondition(result.0 == nil && result.1, "\(field) must reject '\(bad)'")
        }
    }
    precondition(commit(.refreshSeconds, " 0.5 ").0?.refreshSeconds == 0.5, "fractions and surrounding whitespace accepted")
    precondition(commit(.refreshSeconds, "1e2").0?.refreshSeconds == 100 && commit(.cacheMinutes, "+3").0?.cacheMinutes == 3)
    precondition(commit(.timeoutSeconds, ".5").0?.timeoutSeconds == 0.5 && commit(.timeoutSeconds, "5.").0?.timeoutSeconds == 5)
    precondition(commit(.refreshSeconds, "0").0 == nil && commit(.refreshSeconds, "-1").0 == nil && commit(.timeoutSeconds, "0").0 == nil)
    precondition(commit(.cacheMinutes, "0").0?.cacheMinutes == 0 && commit(.cacheMinutes, "-0.1").0 == nil)
    precondition(commit(.refreshSeconds, "1e306").0 == nil && commit(.cacheMinutes, "1e305").0 == nil, "unit conversion overflow rejected")
    precondition(commit(.refreshSeconds, "1e300").0?.refreshSeconds == 1e300)

    // Thresholds: no 100 ceiling, equality valid, critical below warn reported on critical.
    var thresholds = Draft(config: draftConfig())
    thresholds.setText("150", for: .warnPercent)
    precondition(fields(thresholds) == [.criticalPercent], "critical below warn is reported on critical (\(fields(thresholds)))")
    thresholds.setText("150", for: .criticalPercent)
    precondition(committed(thresholds)?.warnPercent == 150 && committed(thresholds)?.criticalPercent == 150, "equality and >100 valid")
    thresholds.setText("-1", for: .warnPercent)
    precondition(committed(thresholds) == nil && fields(thresholds) == [.warnPercent])

    // Runtime fields: raw values, absolute paths, nonblank profile; showPace pass-through.
    var runtime = Draft(config: draftConfig())
    runtime.setText("node", for: .nodePath)
    runtime.setText("  ", for: .profile)
    precondition(Set(fields(runtime)) == [.nodePath, .profile] && committed(runtime) == nil)
    runtime.setText("/opt/with space/node ", for: .nodePath)
    runtime.setText(" my profile", for: .profile)
    runtime.showPace = false
    let runtimeConfig = committed(runtime)
    precondition(runtimeConfig?.nodePath == "/opt/with space/node " && runtimeConfig?.profile == " my profile" && runtimeConfig?.showPace == false, "paths/profile kept raw")

    // Every problem is reported at once so the UI can mark them all; nothing is built on failure.
    var many = Draft(config: draftConfig())
    many.setText("x", for: .refreshSeconds)
    many.addRow(.labels, key: "", value: "")
    many.setText("relative", for: .ompPath)
    precondition(Set(fields(many)) == [.refreshSeconds, .labels, .ompPath] && committed(many) == nil)

    // Number text round trips exactly (shortest decimal, no trailing .0).
    for value in [60.0, 0.1, 0.25, 1e-7, 1e300, 123456789.125, 0] {
        precondition(Draft.parseNumber(Draft.format(value)) == value, "format/parse round trip \(value)")
    }
    precondition(Draft.format(60) == "60" && Draft.format(0.5) == "0.5")

    // Catalog: full snapshot (accounts and unavailable), not filtered summaries; configured IDs stay selectable.
    let json = #"{"snapshot":{"version":1,"capturedAt":1000,"accounts":[{"id":"a1","provider":"mistral","label":"Work","fetchedAt":1000,"notes":[],"limits":[{"id":"monthly","label":"Month","amount":{"unit":"requests"},"notes":[]},{"id":"daily","label":"Day","amount":{"unit":"requests"},"notes":[]}]},{"id":"a2","provider":"mistral","label":"Home","fetchedAt":1000,"notes":[],"limits":[{"id":"monthly","label":"Month","amount":{"unit":"requests"},"notes":[]}]},{"id":"b1","provider":"hidden-by-config","label":"B","fetchedAt":1000,"notes":[],"limits":[{"id":"only","label":"only","amount":{"unit":"requests"},"notes":[]}]}],"unavailable":[{"provider":"offline","label":"Offline","reason":"x"},{"provider":"mistral","label":"M","reason":"dup"}]},"source":"live","summaries":[{"provider":"mistral","label":"Mistral","percent":1,"value":"1%","severity":"ok","accountCount":2,"notes":[]}]}"#
    guard let result = try? JSONDecoder().decode(PanelResult.self, from: Data(json.utf8)) else { preconditionFailure("catalog fixture must decode") }
    let catalog = Draft.Catalog(result: result)
    precondition(catalog.providers == ["mistral", "hidden-by-config", "offline"], "providers from all accounts then unavailable, unfiltered")
    precondition(catalog.limits(for: "mistral").map(\.id) == ["monthly", "daily"] && catalog.limits(for: "hidden-by-config").map(\.id) == ["only"])
    let configured = draftConfig(providers: ["custom-provider", "mistral"], labels: ["label-only": "L"], metrics: ["metric-only": "custom-limit", "mistral": "weekly"])
    precondition(catalog.providerSuggestions(config: configured) == ["mistral", "hidden-by-config", "offline", "custom-provider", "label-only", "metric-only"], "observed first, then configured array and map keys")
    precondition(catalog.limitSuggestions(provider: "mistral", config: configured) == ["monthly", "daily", "weekly"], "observed limit IDs plus the configured one")
    precondition(catalog.limitSuggestions(provider: "metric-only", config: configured) == ["custom-limit"] && catalog.limitSuggestions(provider: "nope", config: configured).isEmpty)
    precondition(Draft.Catalog(result: nil) == Draft.Catalog() && Draft.Catalog(result: nil).providerSuggestions(config: configured) == ["custom-provider", "mistral", "label-only", "metric-only"])

    // Change tracking compares resulting values only; typing then reverting (or add then remove) is not a change.
    let tracked = draftConfig(providers: ["a"], labels: ["a": "A"])
    let committedPolicy = UpdatePolicy(automaticChecks: true, automaticInstallation: false, notificationsEnabled: true)
    var edited = Draft(config: tracked, updatePolicy: committedPolicy)
    precondition(!edited.hasChanges(from: tracked, updatePolicy: committedPolicy))
    edited.setText("61", for: .refreshSeconds)
    precondition(edited.hasChanges(from: tracked, updatePolicy: committedPolicy))
    edited.setText(Draft.format(60), for: .refreshSeconds)
    let transient = edited.addRow(.labels, key: "b", value: "B")
    precondition(edited.hasChanges(from: tracked, updatePolicy: committedPolicy))
    edited.removeRow(.labels, id: transient)
    precondition(!edited.hasChanges(from: tracked, updatePolicy: committedPolicy), "reverted edits are not unsaved changes")
    edited.updatePolicy.automaticInstallation = true
    precondition(edited.hasChanges(from: tracked, updatePolicy: committedPolicy), "a staged update choice counts as unsaved")
    precondition(committed(edited) == tracked, "update choices never enter the collector configuration")

    // A policy committed elsewhere reaches untouched staged choices only; the user's staged edits survive.
    var staged = Draft(config: tracked, updatePolicy: committedPolicy)
    staged.updatePolicy.automaticInstallation = true
    let changedElsewhere = UpdatePolicy(automaticChecks: true, automaticInstallation: false, notificationsEnabled: false)
    staged.rebaseUpdatePolicy(from: committedPolicy, to: changedElsewhere)
    precondition(staged.updatePolicy == UpdatePolicy(automaticChecks: true, automaticInstallation: true, notificationsEnabled: false))
    precondition(staged.hasChanges(from: tracked, updatePolicy: changedElsewhere))
}
