import Foundation
import CoreGraphics

func runDashboardModelTests() {
    let now = Date(timeIntervalSince1970: 15)
    func window(reset: Double? = 20000, duration: Double? = 10000,
                label: String? = nil, estimated: Bool = false) -> UsageWindow {
        UsageWindow(id: "period", label: "Selected period", durationMs: duration,
                    resetsAt: reset, resetLabel: label, estimated: estimated)
    }
    func limit(_ id: String, _ period: UsageWindow?) -> UsageLimit {
        UsageLimit(id: id, label: "Metric \(id)",
                   amount: UsageAmount(unit: "requests", used: 0, limit: 100, remaining: nil),
                   window: period, usedFraction: 0.99, status: nil, notes: ["Limit note"])
    }
    func account(_ provider: String, _ id: String, _ limits: [UsageLimit], plan: String? = nil) -> UsageAccount {
        UsageAccount(id: id, provider: provider, label: "Account \(provider) \(id)", fetchedAt: 12000,
                     plan: plan, notes: ["Account note"], limits: limits)
    }
    func summary(_ provider: String = "mistral", percent: Double? = 69.999, value: String = "69.9%",
                 severity: String = "normal", accountId: String? = "chosen", metricId: String? = "chosen",
                 accountCount: Int = 1) -> ProviderSummary {
        ProviderSummary(provider: provider, label: "Label \(provider)", percent: percent, value: value,
                        severity: severity, accountCount: accountCount, accountId: accountId,
                        accountLabel: "Summary account", metricId: metricId, metricLabel: "Summary metric",
                        windowLabel: "Summary window", notes: ["Summary note"])
    }
    let snapshot = UsageSnapshot(version: 1, capturedAt: 14000, accounts: [
        account("wrong-provider", "chosen", [limit("chosen", window(reset: 90000))]),
        account("mistral", "first", [limit("chosen", window(reset: 80000))]),
        account("mistral", "chosen", [limit("first", window(reset: 70000)), limit("chosen", window())], plan: "Pro")
    ], unavailable: [UsageUnavailable(provider: "configured", label: "Configured provider", reason: "Token expired")])
    func content(_ summaries: [ProviderSummary], snapshot sourceSnapshot: UsageSnapshot? = nil,
                 source: String = "live", issue: String = "", collecting: Bool = false,
                 error: String? = nil, showPace: Bool = true) -> DashboardContent {
        DashboardModel.make(result: PanelResult(snapshot: sourceSnapshot ?? snapshot, source: source, error: error,
                                                summaries: summaries),
                            issue: issue, collecting: collecting, showPace: showPace)
    }
    let selected = content([summary()]).cards[0]
    precondition(selected.window?.resetsAt == 20000)
    precondition(selected.elapsed(now: now) == 0.5)
    precondition(selected.elapsed(now: Date(timeIntervalSince1970: 16)) == 0.6)
    precondition(content([summary()], showPace: false).cards[0].elapsed(now: now) == nil)

    // Exact joins are mandatory even when another account/limit could supply a plausible reset.
    for missing in [summary(accountId: "missing"), summary(metricId: "missing"),
                    summary(accountId: nil), summary(metricId: nil), summary("wrong-provider", accountId: "first")] {
        let card = content([missing]).cards[0]
        precondition(card.window == nil && card.elapsed(now: now) == nil)
    }
    let summaries = [summary("mistral", percent: 120.125, value: "120.1%", severity: "critical"),
                     summary("openai-codex", percent: 0, value: "0%"),
                     summary("opencode-go", percent: nil, value: "—", severity: "unknown"),
                     summary("minimax-code-cn", percent: 0.01, value: "<0.1%"),
                     summary("commandcode", percent: 89.999, value: "89.9%", severity: "warning"),
                     summary("configured", percent: nil, value: "—", severity: "critical", accountCount: 0)]
    let all = content(summaries)
    precondition(all.cards.map { $0.provider } == summaries.map { $0.provider })
    precondition(all.cards[1].percent == 0 && !all.cards[1].hasIssue)
    precondition(all.cards[2].percent == nil && all.cards[2].hasIssue)
    let partial = content([summary("configured", percent: 12), summary("mistral", percent: 12)])
    precondition(partial.cards[0].hasIssue && !partial.cards[1].hasIssue)

    precondition(!content([summary()], source: "cache", collecting: true).cards[0].hasIssue)
    precondition(content([summary()], source: "stale", error: "Network down").cards[0].hasIssue)
    precondition(content([summary()], issue: "Stale: Collector failed").cards[0].hasIssue)
    let unavailable = DashboardModel.make(result: PanelResult(snapshot: nil, source: "unavailable",
                                                             error: "No credentials", summaries: summaries),
                                          issue: "", collecting: false, showPace: true)
    precondition(unavailable.cards.count == summaries.count && unavailable.cards.allSatisfy { $0.hasIssue })

    func card(_ period: UsageWindow?) -> DashboardCard {
        let source = UsageSnapshot(version: 1, capturedAt: 14000,
                                   accounts: [account("mistral", "chosen", [limit("chosen", period)])], unavailable: [])
        return content([summary()], snapshot: source).cards[0]
    }
    let estimated = card(window(estimated: true))
    precondition(estimated.elapsed(now: now) == 0.5)
    let labelOnly = card(window(reset: nil, label: "Resets monthly"))
    precondition(labelOnly.elapsed(now: now) == nil)
    let estimatedLabelOnly = card(window(reset: nil, label: "Monthly", estimated: true))
    precondition(estimatedLabelOnly.elapsed(now: now) == nil)
    precondition(card(nil).window == nil && card(nil).elapsed(now: now) == nil)
    precondition(card(window(duration: 0)).elapsed(now: now) == nil)
    precondition(card(window(duration: .infinity)).elapsed(now: now) == nil)
    precondition(card(window(reset: .nan)).elapsed(now: now) == nil)

    for cameraHeight in [CGFloat(0), 28, 40, 96] {
        let header = DashboardSizing.headerHeight(cameraHeight: cameraHeight)
        let preferred = DashboardSizing.preferredSize(providerCount: 5, cameraHeight: cameraHeight)
        precondition(header >= 44 && header >= cameraHeight + 12)
        let standardHeader = DashboardSizing.headerHeight(cameraHeight: 0)
        precondition(preferred.height - header == DashboardSizing.bodyHeight - standardHeader)
        precondition(preferred.height - header >= DashboardSizing.cardHeight + 2 * DashboardSizing.cardPadding)
        precondition(preferred.width == DashboardSizing.preferredSize(providerCount: 20,
                                                                     cameraHeight: cameraHeight).width)
    }
    precondition(DashboardSizing.preferredSize(providerCount: 0, cameraHeight: 0).height == DashboardSizing.bodyHeight)
    precondition(DashboardSizing.preferredSize(providerCount: -1, cameraHeight: 0) ==
                 DashboardSizing.preferredSize(providerCount: 0, cameraHeight: 0))
    precondition(DashboardSizing.headerHeight(cameraHeight: .nan).isFinite)
    precondition(DashboardSizing.headerHeight(cameraHeight: .infinity).isFinite)

    // The compact selection is a separate view of the data: the complete content (all
    // providers, exact values, over-limit percentages, tooltips) is unchanged by it.
    let wide = content((0..<8).map { summary("provider\($0)", percent: $0 == 3 ? 104 : Double($0) * 10,
                                              value: $0 == 3 ? "104%" : "\($0 * 10)%") })
    let compactPlan = CompactSlotPlanner.plan(cards: wide.cards,
                                              preferences: CompactPreferences(maximumVisibleSlots: 2,
                                                                              selectedProviderIDs: wide.cards.map { $0.provider }),
                                              physicalCapacity: CompactCapacities(left: 100, right: 100, total: 100))
    precondition(compactPlan.slots.count == 2 && compactPlan.hiddenProviderIDs.count == 7)
    precondition(wide.cards.count == 8 && wide.footer.hasPrefix("8 providers"))
    precondition(wide.cards[3].percent == 104 && wide.cards[3].tooltip.contains("104%"))
    precondition(wide.cards.map { $0.provider } == (0..<8).map { "provider\($0)" })
    runProviderRemovalTransitionTests()
}

// The provider lifecycle as the panel sees it: successive collections feed ONE saved selection through the
// dashboard cards and the compact plan. Synthetic fixtures only; a trailing "?" marks a not-reported placeholder.
private func runProviderRemovalTransitionTests() {
    func account(_ provider: String, _ id: String) -> UsageAccount {
        UsageAccount(id: id, provider: provider, label: id, fetchedAt: 1000, plan: nil, notes: [], limits: [])
    }
    func summary(_ provider: String, accounts: Int) -> ProviderSummary {
        ProviderSummary(provider: provider, label: provider, percent: accounts > 0 ? 10 : nil,
                        value: accounts > 0 ? "10%" : "—", severity: accounts > 0 ? "normal" : "unknown",
                        accountCount: accounts, accountId: nil, accountLabel: nil, metricId: nil, metricLabel: nil,
                        windowLabel: nil, notes: [])
    }
    // One collection taken at `at` (ms): accounts per provider (in upstream order) plus providers reported only as
    // unavailable.
    func collection(_ providers: [(String, Int)], unavailableOnly: [String] = [], source: String = "live",
                    error: String? = nil, at: Double = 14000) -> PanelResult {
        let accounts = providers.flatMap { provider, count in (0..<count).map { account(provider, "\(provider)-\($0)") } }
        let unavailable = unavailableOnly.map { UsageUnavailable(provider: $0, label: "\($0) account", reason: "Usage unavailable") }
        return PanelResult(snapshot: UsageSnapshot(version: 1, capturedAt: at, accounts: accounts, unavailable: unavailable),
                           source: source, error: error,
                           summaries: providers.map { summary($0.0, accounts: $0.1) } + unavailableOnly.map { summary($0, accounts: 0) })
    }
    struct TransportFailure: Error {}
    // Replays the panel's receive path through the same UsageIntake; `nil` is a transport failure.
    func replay(_ steps: [PanelResult?]) -> UsageIntake {
        var intake = UsageIntake()
        for step in steps {
            intake.receive(step.map { Result<PanelResult, Error>.success($0) } ?? .failure(TransportFailure()))
        }
        return intake
    }
    // The compact row of the final state; a trailing "?" marks a not-reported placeholder.
    func row(_ intake: UsageIntake, selection: [String]) -> [String] {
        let issue = intake.transportError.map { "Stale: \($0)" } ?? ""
        let cards = DashboardModel.make(result: intake.result, issue: issue, collecting: false, showPace: true).cards
        let plan = CompactSlotPlanner.plan(cards: cards,
                                           preferences: CompactPreferences(maximumVisibleSlots: 6, selectedProviderIDs: selection),
                                           physicalCapacity: CompactCapacities(left: 10, right: 10, total: 10),
                                           issue: issue, connectedProviders: intake.roster.known)
        return plan.slots.map { slot in
            switch slot {
            case .provider(let ring): return ring.isReported ? ring.provider : "\(ring.provider)?"
            case .more(let more): return more.text
            case .configure: return "configure"
            }
        }
    }
    func compact(_ steps: [PanelResult?], selection: [String]) -> [String] { row(replay(steps), selection: selection) }
    // The same snapshot as `last`, as the collector returns it after a failed refresh / from a fresh disk cache.
    func failedRefresh(of last: PanelResult) -> PanelResult {
        PanelResult(snapshot: last.snapshot, source: "stale", error: "Usage refresh failed", summaries: last.summaries)
    }
    func cached(_ last: PanelResult) -> PanelResult {
        PanelResult(snapshot: last.snapshot, source: "cache", error: nil, summaries: last.summaries)
    }
    func providers(in intake: UsageIntake) -> Set<String> {
        Set((intake.result?.snapshot?.accounts.map(\.provider) ?? []) + (intake.result?.summaries.map(\.provider) ?? []))
    }
    let selection = ["codex", "go", "mistral"]
    let connected = collection([("codex", 1), ("go", 1), ("mistral", 2)], at: 14000)
    precondition(compact([connected], selection: selection) == ["codex", "go", "mistral"])

    // Removing a provider: the next successful collection no longer reports it, and its ring disappears at once.
    let withoutGo = collection([("codex", 1), ("mistral", 2)], at: 15000)
    precondition(compact([connected, withoutGo], selection: selection) == ["codex", "mistral"])
    precondition(DashboardModel.make(result: withoutGo, issue: "", collecting: false, showPace: true).cards.map(\.provider)
                 == ["codex", "mistral"])
    // Before any confirmed roster nothing is known and saved selections keep their placeholders: first load, and a
    // first collection that failed (stale fallback, or nothing at all).
    precondition(compact([], selection: selection) == ["codex?", "go?", "mistral?"])
    precondition(compact([nil], selection: selection) == ["codex?", "go?", "mistral?"])
    precondition(compact([failedRefresh(of: withoutGo)], selection: selection) == ["codex", "mistral", "go?"])
    // First load whose only answer is an old stale snapshot is accepted as data (nothing newer exists).
    precondition(compact([failedRefresh(of: connected)], selection: selection) == ["codex", "go", "mistral"])
    // After a confirmed removal a later failure of either kind must not resurrect it.
    precondition(compact([connected, withoutGo, failedRefresh(of: withoutGo)], selection: selection) == ["codex", "mistral"])
    precondition(compact([connected, withoutGo, nil], selection: selection) == ["codex", "mistral"])
    precondition(compact([connected, withoutGo, nil, failedRefresh(of: withoutGo), nil], selection: selection) == ["codex", "mistral"])
    // Reconnecting needs an authoritative collection, and then brings it back from the untouched selection.
    precondition(compact([connected, withoutGo, failedRefresh(of: withoutGo), connected], selection: selection) == ["codex", "go", "mistral"])

    // The disk cache is best effort: if its write failed after the removal, a later failure returns the OLDER
    // pre-removal snapshot (stale) and a later healthy answer may be that same older file (cache). Neither may
    // bring back the removed provider's data, accounts or ring, and neither may move the roster backwards.
    let afterOldStale = replay([connected, withoutGo, failedRefresh(of: connected)])
    precondition(row(afterOldStale, selection: selection) == ["codex", "mistral"])
    precondition(afterOldStale.result?.snapshot?.capturedAt == 15000 && !providers(in: afterOldStale).contains("go"))
    precondition(afterOldStale.roster.known == Set(["codex", "mistral"].map(\.exactKey)))
    // The failure stays visible next to the kept data: the transport error is set and every card is flagged.
    precondition(afterOldStale.transportError == "Usage refresh failed")
    let flagged = DashboardModel.make(result: afterOldStale.result, issue: "Stale: Usage refresh failed", collecting: false, showPace: true)
    precondition(!flagged.cards.isEmpty && flagged.cards.allSatisfy(\.hasIssue) && flagged.status.contains("Usage refresh failed"))
    let afterOldCache = replay([connected, withoutGo, cached(connected)])
    precondition(row(afterOldCache, selection: selection) == ["codex", "mistral"])
    precondition(afterOldCache.result?.snapshot?.capturedAt == 15000 && !providers(in: afterOldCache).contains("go"))
    precondition(afterOldCache.roster.known == Set(["codex", "mistral"].map(\.exactKey)) && afterOldCache.transportError == nil)
    // An old cache hit after an earlier failure leaves that failure visible rather than claiming health.
    precondition(replay([connected, withoutGo, nil, cached(connected)]).transportError != nil)
    // Same for a confirmed EMPTY roster.
    let nothing = collection([], at: 15000)
    let emptyOldStale = replay([connected, nothing, failedRefresh(of: connected)])
    precondition(row(emptyOldStale, selection: selection) == ["configure"])
    precondition(emptyOldStale.result?.snapshot?.accounts.isEmpty == true && emptyOldStale.result?.summaries.isEmpty == true)
    precondition(row(replay([connected, nothing, cached(connected)]), selection: selection) == ["configure"])
    // The roster alone also refuses to move backwards on an older healthy cache answer.
    var roster = ConnectedProviders()
    roster.observe(withoutGo); roster.observe(cached(connected))
    precondition(roster.known == Set(["codex", "mistral"].map(\.exactKey)) && roster.confirmedAt == 15000)
    // Newer data is never blocked: a healthy cache/live answer taken after the removal is accepted, including the
    // genuine reconnect, and clears the failure.
    let reconnected = collection([("codex", 1), ("go", 1), ("mistral", 2)], at: 16000)
    let recovered = replay([connected, withoutGo, failedRefresh(of: connected), reconnected])
    precondition(row(recovered, selection: selection) == ["codex", "go", "mistral"] && recovered.transportError == nil)
    precondition(row(replay([connected, withoutGo, cached(collection([("codex", 1)], at: 15500))]), selection: selection) == ["codex"])
    // A source change forgets everything: an old stale snapshot is then first-load data again.
    var switched = replay([connected, withoutGo])
    switched.reset()
    switched.receive(.success(failedRefresh(of: connected)))
    precondition(row(switched, selection: selection) == ["codex", "go", "mistral"])

    // Removing one of several accounts keeps the provider; a provider whose usage fetch merely failed is still
    // reported (as an unavailable report) and keeps its ring.
    precondition(compact([connected, collection([("codex", 1), ("go", 1), ("mistral", 1)], at: 15000)], selection: selection) == ["codex", "go", "mistral"])
    precondition(compact([connected, collection([("codex", 1), ("go", 1)], unavailableOnly: ["mistral"], at: 15000)], selection: selection) == ["codex", "go", "mistral"])
    precondition(compact([connected, collection([("codex", 1), ("mistral", 2)], source: "cache", at: 15000)], selection: selection) == ["codex", "mistral"])

    // Every provider removed: no ghosts, one configure control and an empty overview. A later failure keeps it so.
    precondition(compact([connected, nothing], selection: selection) == ["configure"])
    precondition(compact([connected, nothing, failedRefresh(of: nothing)], selection: selection) == ["configure"])
    precondition(compact([connected, nothing, nil], selection: selection) == ["configure"])
    precondition(compact([connected, nothing, nil, connected], selection: selection) == ["codex", "go", "mistral"])
    let emptyContent = DashboardModel.make(result: nothing, issue: "", collecting: false, showPace: true)
    precondition(emptyContent.cards.isEmpty && nothing.snapshot?.accounts.isEmpty == true)
    // An empty roster that was never confirmed (the first collection itself failed) still keeps the placeholders.
    precondition(compact([failedRefresh(of: nothing)], selection: selection) == ["codex?", "go?", "mistral?"])
}
