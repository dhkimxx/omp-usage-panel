import Foundation

// Synthetic observations exercise the real intake, roster, dashboard, compact planner and detail scope.
// No subprocess, provider credentials or wall-clock freshness is involved.
func runExternalIntakeTests() {
    let external = "google-antigravity"
    func account(_ provider: String, at: Double, percent: Double) -> UsageAccount {
        UsageAccount(id: provider, provider: provider, label: provider, fetchedAt: at, plan: nil, notes: [], limits: [
            UsageLimit(id: "quota", label: "Quota", amount: UsageAmount(unit: "percent", used: percent, limit: 100, remaining: 100 - percent),
                       window: nil, usedFraction: percent / 100, status: nil, notes: [])
        ])
    }
    func summary(_ provider: String, percent: Double?) -> ProviderSummary {
        ProviderSummary(provider: provider, label: provider, percent: percent, value: percent.map { "\($0)%" } ?? "—",
                        severity: percent == nil ? "unknown" : "normal", accountCount: percent == nil ? 0 : 1,
                        accountId: percent == nil ? nil : provider, accountLabel: nil, metricId: "quota",
                        metricLabel: "Quota", windowLabel: nil, notes: [])
    }
    func collection(ompAt: Double?, providers: [String] = ["mistral"], ompState: String = "live", ompPercent: Double = 20,
                    externalAt: Double? = 1000, externalState: String = "cache", externalPercent: Double = 30) -> PanelResult {
        let ids = ompAt == nil ? [] : providers
        let ompError = ompState == "unavailable" || ompState == "stale" ? "Usage refresh failed" : nil
        let externalError = externalState == "unavailable" || externalState == "stale" ? "AUTH_REQUIRED" : nil
        var accounts = ids.map { account($0, at: ompAt!, percent: ompPercent) }
        if let externalAt, externalState != "unavailable" { accounts.append(account(external, at: externalAt, percent: externalPercent)) }
        let reports = externalState == "unavailable" ? [UsageUnavailable(provider: external, label: external, reason: "AUTH_REQUIRED")] : []
        let captures = [ompAt, externalState == "unavailable" ? nil : externalAt].compactMap { $0 }
        let snapshot = captures.min().map { UsageSnapshot(version: 1, capturedAt: $0, accounts: accounts, unavailable: reports) }
        let healthyOMP = ompAt != nil && (ompState == "live" || ompState == "cache")
        let healthyExternal = externalAt != nil && externalState == "cache"
        let failed = !healthyOMP || !healthyExternal
        let source = failed ? (healthyOMP || healthyExternal ? "partial" : snapshot == nil ? "unavailable" : "stale") : ompState
        return PanelResult(snapshot: snapshot, source: source, error: failed ? "Usage data is unavailable" : nil,
                           summaries: ids.map { summary($0, percent: ompPercent) } + [summary(external, percent: externalState == "unavailable" ? nil : externalPercent)],
                           providerSources: ids.map { ProviderSource(provider: $0, source: ompState, capturedAt: ompAt, error: ompError) } + [
                               ProviderSource(provider: external, source: externalState, capturedAt: externalAt, error: externalError)
                           ], ompSource: OMPSource(source: ompState, capturedAt: ompAt, providers: ids, error: ompError))
    }
    func cards(_ intake: UsageIntake, issue: String = "", collecting: Bool = false) -> [DashboardCard] {
        DashboardModel.make(result: intake.result, issue: issue, collecting: collecting, showPace: true).cards
    }

    // F1: first-load OMP failure plus healthy external quota cannot confirm an external-only roster.
    for failedOMP in [collection(ompAt: nil, ompState: "unavailable"), collection(ompAt: 10000, ompState: "stale")] {
        var intake = UsageIntake()
        precondition(intake.receive(.success(failedOMP)))
        precondition(intake.roster.known == nil && intake.roster.confirmedAt == nil, "a failed OMP first load must remain unconfirmed")
        precondition(ProviderDetailModel.reconciledScope(.provider("go"), connected: intake.roster.known) == .provider("go"))
        let plan = CompactSlotPlanner.plan(cards: cards(intake),
                                           preferences: CompactPreferences(maximumVisibleSlots: 6, selectedProviderIDs: ["go", external]),
                                           physicalCapacity: CompactCapacities(left: 10, right: 10, total: 10), connectedProviders: intake.roster.known)
        precondition(plan.slots.contains { if case .provider(let ring) = $0 { return ring.provider == "go" && !ring.isReported }; return false },
                     "a saved OMP selection needs its placeholder while its roster is unknown")
    }

    // F2: the OMP clock (not min(OMP, external)) gates OMP cache data and a confirmed removal.
    do {
        var intake = UsageIntake()
        intake.receive(.success(collection(ompAt: 10000, providers: ["mistral", "go"], ompPercent: 10)))
        intake.receive(.success(collection(ompAt: 20000, ompPercent: 40)))
        let known = intake.roster.known
        precondition(intake.roster.confirmedAt == 20000, "an old external capture must not lower the confirmed OMP clock")
        precondition(intake.receive(.success(collection(ompAt: 10000, providers: ["mistral", "go"], ompState: "cache", ompPercent: 10,
                                                        externalAt: 30000, externalPercent: 80))))
        precondition(intake.result?.summaries.first { $0.provider == "mistral" }?.percent == 40, "old OMP cache cannot overwrite newer real quota")
        precondition(intake.result?.snapshot?.accounts.contains { $0.provider == "go" } == false, "old OMP cache cannot resurrect a removed provider")
        precondition(intake.result?.summaries.first { $0.provider == external }?.percent == 80, "new external observations must still advance")
        precondition(intake.result?.source(for: "mistral")?.capturedAt == 20000 && intake.result?.source(for: external)?.capturedAt == 30000)
        precondition(intake.roster.known == known && intake.roster.confirmedAt == 20000)
        intake.receive(.success(collection(ompAt: 10000, providers: ["mistral", "go"], ompState: "stale", externalAt: 35000)))
        precondition(intake.roster.known == known && intake.roster.confirmedAt == 20000, "failed or older OMP cannot union or reconfirm its roster")
        precondition(intake.result?.snapshot?.accounts.contains { $0.provider == "go" } == false)
        precondition(intake.result?.source(for: "mistral")?.source == "stale")
        precondition(!cards(intake).first { $0.provider == external }!.hasIssue, "OMP failure remains source-local")
    }

    // Empty OMP rosters retain their clock; healthy OMP confirms even if an external source fails.
    do {
        var intake = UsageIntake()
        intake.receive(.success(collection(ompAt: 20000, providers: [], externalAt: nil, externalState: "unavailable")))
        intake.receive(.success(collection(ompAt: 10000, providers: [], ompState: "cache", externalAt: 2000)))
        precondition(intake.result?.ompSource?.capturedAt == 20000)
        intake.receive(.success(collection(ompAt: 15000, providers: ["go"], ompState: "stale", externalAt: 3000)))
        precondition(intake.result?.snapshot?.accounts.contains { $0.provider == "go" } == false)
        precondition(intake.roster.known == Set([external.exactKey]) && intake.roster.confirmedAt == 20000)
        var partial = UsageIntake()
        partial.receive(.success(collection(ompAt: 20000, ompPercent: 40, externalAt: nil, externalState: "unavailable")))
        partial.receive(.success(collection(ompAt: 10000, providers: ["mistral", "go"], ompState: "cache", externalAt: 30000)))
        precondition(partial.roster.known == Set(["mistral", external].map(\.exactKey)) && partial.roster.confirmedAt == 20000)
        precondition(partial.result?.summaries.first { $0.provider == "mistral" }?.percent == 40)
    }

    // Passive AG commonly expires: healthy OMP additions/removals must reach the actual detail and compact consumers.
    do {
        var intake = UsageIntake()
        intake.receive(.success(collection(ompAt: 20000, externalAt: 19000)))
        intake.receive(.success(collection(ompAt: 21000, providers: ["mistral", "go"], externalAt: 19000, externalState: "stale")))
        precondition(intake.result?.source == "partial" && intake.roster.confirmedAt == 21000)
        let scope = ProviderDetailModel.reconciledScope(.provider("go"), connected: intake.roster.known)
        precondition(scope == .provider("go"), "new OMP detail must not reconcile to All while AG is stale")
        let config = PanelConfig(version: 1, nodePath: "", ompPath: "", profile: "", refreshSeconds: 60,
                                 cacheMinutes: 5, timeoutSeconds: 30, providers: nil, labels: [:],
                                 metrics: [:], warnPercent: 75, criticalPercent: 90, showPace: true)
        let detail = ProviderDetailModel.make(result: intake.result, scope: scope, selectedAccount: nil,
                                             config: config, collecting: false, transportError: nil)
        precondition(detail.choices.count == 1 && detail.selected?.account?.provider == "go" && !detail.limits.isEmpty)
        intake.receive(.success(collection(ompAt: 22000, providers: ["go"], ompState: "cache", externalAt: 19000, externalState: "stale")))
        precondition(ProviderDetailModel.reconciledScope(scope, connected: intake.roster.known) == scope)
        precondition(ProviderDetailModel.reconciledScope(.provider("mistral"), connected: intake.roster.known) == .allAccounts)
        let preferences = CompactPreferences(maximumVisibleSlots: 6, selectedProviderIDs: ["mistral", "go", external],
                                             providerSides: ["mistral": .left])
        let capacity = CompactCapacities(left: 10, right: 10, total: 10)
        let plan = CompactSlotPlanner.plan(cards: cards(intake), preferences: preferences,
                                           physicalCapacity: capacity, connectedProviders: intake.roster.known)
        precondition(!plan.slots.contains { if case .provider(let ring) = $0 { return ring.provider == "mistral" }; return false },
                     "a confirmed OMP removal must not leave a compact placeholder during AG staleness")
        precondition(plan.slots.contains { if case .provider(let ring) = $0 { return ring.provider == external }; return false })
        let known = intake.roster.known
        // Failed OMP at the same clock must not replace membership or borrow the healthy external clock.
        intake.receive(.success(collection(ompAt: 22000, providers: ["mistral"], ompState: "stale", externalAt: 30000)))
        precondition(intake.roster.known == known && intake.roster.confirmedAt == 22000)
        precondition(intake.result?.source(for: "mistral")?.capturedAt == 22000 && intake.result?.source(for: external)?.capturedAt == 30000)
        // Even a newer failed OMP capture cannot confirm a removal or a reconnect.
        intake.receive(.success(collection(ompAt: 23000, providers: ["mistral"], ompState: "stale", externalAt: 31000)))
        precondition(intake.roster.known == known && intake.roster.confirmedAt == 22000)
        // Configured external membership survives an unavailable file, and saved OMP selections reconnect on their original side.
        intake.receive(.success(collection(ompAt: 24000, providers: ["mistral", "go"], externalAt: nil, externalState: "unavailable")))
        precondition(intake.roster.known == Set(["mistral", "go", external].map(\.exactKey)) && intake.roster.confirmedAt == 24000)
        let reconnected = CompactSlotPlanner.plan(cards: cards(intake), preferences: preferences,
                                                  physicalCapacity: capacity, connectedProviders: intake.roster.known)
        precondition(reconnected.slots.contains { if case .provider(let ring) = $0 { return ring.provider == "mistral" && ring.isReported }; return false })
        precondition(preferences.side(for: "mistral") == .left)
        precondition(reconnected.slots.contains { if case .provider(let ring) = $0 { return ring.provider == external }; return false },
                     "external ownership must preserve the selected unavailable provider")
    }

    // F3: all-fail null preserves last good; with no last good it stays genuinely null (never epoch zero).
    do {
        let failed = collection(ompAt: nil, ompState: "unavailable", externalAt: nil, externalState: "unavailable")
        var intake = UsageIntake()
        intake.receive(.success(collection(ompAt: 20000, externalAt: 19000)))
        precondition(!intake.receive(.success(failed)))
        precondition(intake.result?.snapshot?.capturedAt == 19000 && intake.transportError != nil)
        precondition(intake.roster.confirmedAt == 20000)
        var first = UsageIntake()
        precondition(first.receive(.success(failed)))
        precondition(first.result?.snapshot == nil && first.roster.known == nil)
        precondition(!DashboardModel.make(result: first.result, issue: "", collecting: false, showPace: true).footer.contains("Snapshot"))
        intake.receive(.success(collection(ompAt: nil, ompState: "unavailable", externalAt: 30000, externalPercent: 60)))
        precondition(intake.result?.snapshot?.accounts.first { $0.provider == "mistral" }?.fetchedAt == 20000)
        precondition(intake.result?.summaries.first { $0.provider == external }?.percent == 60)
        precondition(intake.result?.source(for: "mistral")?.source == "stale")
    }

    // F4/F6: an unavailable external card has no borrowed OMP snapshot time; transport/refresh text is not lost.
    do {
        var intake = UsageIntake()
        intake.receive(.success(collection(ompAt: 20000, externalAt: nil, externalState: "unavailable")))
        let card = cards(intake).first { $0.provider == external }!
        precondition(card.value == "—" && card.hasIssue && card.tooltip.contains("Unavailable"))
        precondition(!card.tooltip.contains("Snapshot:"), "an explicit null source capture cannot fall back to another source")
        let refreshing = cards(intake, issue: "Transport failed", collecting: true)
        precondition(refreshing.allSatisfy { $0.tooltip.contains("Transport failed") && $0.tooltip.contains("Refreshing…") && $0.hasIssue })
        precondition(refreshing.first { $0.provider == "mistral" }!.tooltip.contains("Last successful snapshot"))
    }

    // Each external clock survives a newer unavailable observation; a rollback cannot resurrect older quota.
    do {
        var intake = UsageIntake()
        intake.receive(.success(collection(ompAt: 20000, externalAt: 15000, externalPercent: 70)))
        intake.receive(.success(collection(ompAt: 21000, externalAt: nil, externalState: "unavailable")))
        intake.receive(.success(collection(ompAt: 22000, externalAt: 10000, externalPercent: 10)))
        precondition(intake.result?.source(for: external)?.source == "unavailable")
        precondition(intake.result?.source(for: external)?.capturedAt == nil)
        precondition(cards(intake).first { $0.provider == external }!.value == "—")
        precondition(intake.result?.source(for: "mistral")?.capturedAt == 22000)
        precondition(intake.result?.source == "partial" && intake.roster.confirmedAt == 22000,
                     "a rejected external rollback cannot block healthy OMP confirmation or refresh the external capture")
        intake.receive(.success(collection(ompAt: 23000, externalAt: 16000, externalPercent: 90)))
        precondition(intake.result?.summaries.first { $0.provider == external }?.percent == 90)
        intake.receive(.success(collection(ompAt: 24000, externalAt: 999999, externalState: "stale")))
        intake.receive(.success(collection(ompAt: 25000, externalAt: 17000, externalPercent: 50)))
        precondition(intake.result?.summaries.first { $0.provider == external }?.percent == 50,
                     "a failed/future observation cannot advance the successful external clock")
        intake.reset()
        intake.receive(.success(collection(ompAt: 1000, externalAt: 1000)))
        precondition(intake.result?.source(for: external)?.capturedAt == 1000, "a source reset must forget every independent clock")
    }
}
