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
    let compactPlan = CompactSlotPlanner.plan(cards: wide.cards, selectedProviderIDs: wide.cards.map { $0.provider },
                                              maximumVisibleSlots: 2, physicalCapacity: 100)
    precondition(compactPlan.slots.count == 2 && compactPlan.hiddenProviderIDs.count == 7)
    precondition(wide.cards.count == 8 && wide.footer.hasPrefix("8 providers"))
    precondition(wide.cards[3].percent == 104 && wide.cards[3].tooltip.contains("104%"))
    precondition(wide.cards.map { $0.provider } == (0..<8).map { "provider\($0)" })
}
