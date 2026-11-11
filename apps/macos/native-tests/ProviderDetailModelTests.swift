import Foundation

func runProviderDetailModelTests() {
    func config(showPace: Bool = true) -> PanelConfig {
        PanelConfig(version: 1, nodePath: "", ompPath: "", profile: "", refreshSeconds: 60,
                    cacheMinutes: 5, timeoutSeconds: 30, providers: nil, labels: ["extra": "Custom extra"],
                    metrics: [:], warnPercent: 75, criticalPercent: 90, showPace: showPace)
    }
    func limit(_ id: String = "limit", fraction: Double? = 0, used: Double? = 0,
               quota: Double? = 100, remaining: Double? = nil, window: UsageWindow? = nil) -> UsageLimit {
        UsageLimit(id: id, label: id, amount: UsageAmount(unit: "credits", used: used, limit: quota,
                                                        remaining: remaining), window: window,
                   usedFraction: fraction, status: "reported", notes: ["Original limit note"])
    }
    func account(_ provider: String, _ id: String, limits: [UsageLimit] = []) -> UsageAccount {
        UsageAccount(id: id, provider: provider, label: "Label \(id)", fetchedAt: 12000,
                     plan: nil, notes: ["Original account note"], limits: limits)
    }
    func summary(_ provider: String, selected: String? = nil) -> ProviderSummary {
        ProviderSummary(provider: provider, label: "Configured \(provider)", percent: nil, value: "—",
                        severity: "unknown", accountCount: 999, accountId: selected, accountLabel: nil,
                        metricId: nil, metricLabel: nil, windowLabel: nil, notes: ["Original summary note"])
    }
    func result(_ accounts: [UsageAccount], reports: [UsageUnavailable] = [],
                summaries: [ProviderSummary] = [], source: String = "live", error: String? = nil) -> PanelResult {
        PanelResult(snapshot: UsageSnapshot(version: 1, capturedAt: 14000, accounts: accounts,
                                             unavailable: reports), source: source, error: error, summaries: summaries)
    }
    func content(_ result: PanelResult?, scope: DetailScope = .allAccounts, key: DetailAccountKey? = nil,
                 showPace: Bool = true, error: String? = nil) -> ProviderDetailContent {
        ProviderDetailModel.make(result: result, scope: scope, selectedAccount: key,
                                 config: config(showPace: showPace), collecting: false, transportError: error)
    }
    let empty = content(nil)
    precondition(empty.choices.isEmpty && empty.selected == nil && empty.limits.isEmpty)
    precondition(empty.accountCount == 0 && empty.unavailableCount == 0)
    precondition(empty.providers.map(\.scope) == [.allAccounts])

    let a = account("p", "first", limits: [limit("first-limit")])
    let b = account("p", "chosen", limits: [limit("selected-limit", fraction: 1.23)])
    let other = account("q", "chosen", limits: [limit("other-limit")])
    let reports = [UsageUnavailable(provider: "p", label: "same", reason: "Expired credential"),
                   UsageUnavailable(provider: "p", label: "same", reason: "Unreadable report"),
                   UsageUnavailable(provider: "q", label: "same", reason: "Other provider error")]
    let initial = result([other, a, b, account("extra", "additional")], reports: reports,
                         summaries: [summary("p", selected: "chosen"), summary("q")])
    let provider = content(initial, scope: .provider("p"))
    precondition(provider.selected?.key == .account(provider: "p", id: "chosen"))
    precondition(provider.limits.map { $0.limit.id } == ["selected-limit"])
    precondition(provider.limits[0].percent == 123)
    precondition(provider.limits[0].severity == "critical")
    precondition(provider.accountCount == 2 && provider.unavailableCount == 2 && provider.choices.count == 4)
    precondition(provider.providers.map(\.scope) == [.allAccounts, .provider("p"), .provider("q"), .provider("extra")])
    precondition(provider.providers.last?.label == "Custom extra")
    precondition(provider.account.accountNotes == ["Original account note"])
    precondition(provider.account.providerNotes == ["Original summary note"])
    // The synthetic fixture reports no plan; absence is data, not a placeholder.
    precondition(provider.account.plan == nil && provider.account.fetched != nil && provider.account.cautions.isEmpty)
    let planned = UsageAccount(id: "planned", provider: "p", label: "Planned", fetchedAt: .nan, plan: "  Pro  ",
                               notes: ["Same note", "Same note", "  "], limits: [])
    let plannedContent = content(result([planned], summaries: [summary("p")]), scope: .provider("p"))
    precondition(plannedContent.account.plan == "Pro" && plannedContent.account.fetched == nil)
    precondition(plannedContent.account.accountNotes == ["Same note"])
    let blankPlan = UsageAccount(id: "blank", provider: "p", label: "Blank", fetchedAt: 12000, plan: "  ",
                                 notes: [], limits: [])
    precondition(content(result([blankPlan]), scope: .provider("p")).account.plan == nil)
    precondition(provider.limits[0].limit.notes == ["Original limit note"])
    let all = content(initial)
    precondition(all.accountCount == 4 && all.unavailableCount == 3 && all.choices.count == 7)
    precondition(Set(all.choices.map(\.key)).count == 7)
    let unavailableKey = DetailAccountKey.unavailable(provider: "p", label: "same", occurrence: 1)
    let unavailable = content(initial, scope: .provider("p"), key: unavailableKey)
    precondition(unavailable.selected?.account == nil && unavailable.selected?.unavailable?.reason == "Unreadable report")
    precondition(unavailable.limits.isEmpty && unavailable.hasIssue)
    precondition(unavailable.account.cautions == ["Unreadable report"] && unavailable.account.plan == nil)
    precondition(unavailable.account.fetched == nil && unavailable.account.accountNotes.isEmpty)
    precondition(unavailable.account.providerNotes == ["Original summary note"])
    precondition(provider.account.cautions.isEmpty)

    let reordered = result([b, other, a], summaries: [summary("p", selected: "first")])
    let retained = content(reordered, scope: .provider("p"), key: provider.selected?.key)
    precondition(retained.selected?.key == .account(provider: "p", id: "chosen"))
    // Removed selections choose the first actual record, not a new summary-selected credential.
    let removed = content(result([a, b], summaries: [summary("p", selected: "chosen")]),
                          scope: .provider("p"), key: .account(provider: "p", id: "removed"))
    precondition(removed.selected?.key == .account(provider: "p", id: "first"))
    let badJoin = content(initial, scope: .provider("p"), key: .account(provider: "q", id: "chosen"))
    precondition(badJoin.selected?.key == .account(provider: "p", id: "first"))
    let zero = content(result([], summaries: [summary("p")]), scope: .provider("p"))
    precondition(zero.choices.isEmpty && zero.selected == nil)
    let reportOnly = content(result([], reports: [reports[0]]), scope: .provider("p"))
    precondition(reportOnly.accountCount == 0 && reportOnly.unavailableCount == 1 && reportOnly.choices.count == 1)
    precondition(reportOnly.selected?.key == .unavailable(provider: "p", label: "same", occurrence: 0))
    let one = content(result([a]), scope: .provider("p"))
    precondition(one.choices.count == 1 && one.accountCount == 1)
    let manyAccounts = (0..<12).map { account("p", "id-\($0)") }
    let many = content(result(manyAccounts), scope: .provider("p"), key: .account(provider: "p", id: "id-11"))
    precondition(many.accountCount == 12 && many.selected?.account?.id == "id-11")

    // The dropdown catalog comes from the full snapshot, not the filtered summaries.
    let filtered = result([a, other], reports: [UsageUnavailable(provider: "down", label: "gone", reason: "Expired")],
                          summaries: [summary("p")])
    let catalog = ProviderDetailModel.catalog(result: filtered, scope: nil, config: config())
    precondition(catalog.providers.map(\.scope) == [.allAccounts, .provider("p"), .provider("q"), .provider("down")])
    precondition(content(filtered).choices.count == 3)
    precondition(content(filtered, scope: .provider("down")).unavailableCount == 1)
    precondition(content(filtered, scope: .provider("down")).accountCount == 0)
    // A provider whose ID is "all" is a real provider, never the synthetic All scope.
    let literalAll = result([account("all", "x", limits: [limit("literal")])], summaries: [summary("all")])
    let literalScope = content(literalAll, scope: .provider("all"))
    precondition(literalScope.providers.map(\.scope) == [.allAccounts, .provider("all")])
    precondition(literalScope.limits.map { $0.limit.id } == ["literal"])
    precondition(ProviderDetailModel.catalog(result: nil, scope: .provider("missing"), config: config()).providers.map(\.scope)
                 == [.allAccounts, .provider("missing")])
    // Selection scoped to another provider never leaks into a provider scope.
    precondition(content(filtered, scope: .provider("q"), key: .account(provider: "p", id: a.id)).selected?.key
                 == .account(provider: "q", id: other.id))

    let period = UsageWindow(id: "window", label: "Period", durationMs: 10000, resetsAt: 20000,
                             resetLabel: "Provider reset label", estimated: true)
    let values = [limit("zero"), limit("unknown", fraction: nil, used: nil, quota: nil),
                  limit("balance", fraction: 0.5, used: nil, quota: nil, remaining: 38.4),
                  limit("windowed", fraction: 0.25, window: period),
                  limit("no-window", fraction: 0.75), limit("nonfinite", fraction: .infinity)]
    let actual = content(result([account("p", "limits", limits: values)]))
    precondition(actual.limits[0].percent == 0 && actual.limits[1].percent == nil)
    precondition(actual.limits[2].isBalanceOnly && actual.limits[2].percent == nil)
    precondition(actual.limits[2].limit.amount.limit == nil && actual.limits[2].limit.amount.used == nil)
    let now = Date(timeIntervalSince1970: 15)
    precondition(actual.limits[3].elapsed(now: now) == 0.5)
    precondition(actual.limits[3].limit.window?.estimated == true)
    precondition(actual.limits[4].elapsed(now: now) == nil && actual.limits[5].percent == nil)
    precondition(content(result([account("p", "limits", limits: values)]), showPace: false).limits[3].elapsed(now: now) == nil)
    for window in [UsageWindow(id: "bad", label: "Bad", durationMs: 0, resetsAt: 20000, resetLabel: nil, estimated: nil),
                   UsageWindow(id: "bad", label: "Bad", durationMs: .infinity, resetsAt: 20000, resetLabel: nil, estimated: nil),
                   UsageWindow(id: "bad", label: "Bad", durationMs: 10000, resetsAt: .nan, resetLabel: nil, estimated: nil)] {
        let model = DetailLimit(limit: limit(window: window), showPace: true, severity: "unknown")
        precondition(model.elapsed(now: now) == nil)
        precondition(!model.reset(now: now).isEmpty)
    }

    // Detail percentages truncate like the overview and never round across a boundary.
    precondition(DetailFormatting.percent(123, warn: 70, critical: 90) == "123%")
    precondition(DetailFormatting.percent(0, warn: 70, critical: 90) == "0%")
    precondition(DetailFormatting.percent(0.05, warn: 70, critical: 90) == "<0.1%")
    let nearHundred = DetailFormatting.percent(99.99999999999999, warn: 70, critical: 90)
    precondition(nearHundred != "100%" && nearHundred.hasPrefix("99"))
    precondition(DetailFormatting.percent(.nan, warn: 70, critical: 90) == "—")
    let exhausted = UsageLimit(id: "exhausted", label: "Exhausted", amount: UsageAmount(unit: "credits", used: 1, limit: 100, remaining: nil),
                               window: nil, usedFraction: 0.01, status: "exhausted", notes: [])
    precondition(content(result([account("p", "x", limits: [exhausted])])).limits[0].severity == "critical")
    precondition(actual.limits[3].elapsed(now: Date(timeIntervalSince1970: 30)) == 1)
    precondition(actual.limits[3].elapsed(now: Date(timeIntervalSince1970: 0)) == 0)
    precondition(!DetailFormatting.countdown(.greatestFiniteMagnitude, now: now).isEmpty)
    precondition(!DetailFormatting.date(.nan).isEmpty)

    let stale = content(result([b], source: "stale", error: "Provider failed"), error: "Transport failed")
    precondition(stale.hasIssue && stale.selected?.account?.id == "chosen" && stale.limits.count == 1)
    precondition(stale.account.cautions == ["Transport failed", "Provider failed"])
    precondition(stale.account.accountNotes == ["Original account note"])
    let retainedLive = content(result([b], error: "Provider failed"))
    // A retained live result with a failure keeps its data but is never presented as clean.
    precondition(retainedLive.hasIssue && retainedLive.limits.count == 1 && retainedLive.status.contains("Provider failed"))
    let missingSnapshot = PanelResult(snapshot: nil, source: "unavailable", error: "No snapshot",
                                      summaries: [summary("p")])
    precondition(content(missingSnapshot, scope: .provider("p")).choices.isEmpty)
}
