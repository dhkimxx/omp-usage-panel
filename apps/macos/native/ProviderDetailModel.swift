import Foundation

enum DetailScope: Hashable {
    case allAccounts
    case provider(String)
}

enum DetailAccountKey: Hashable {
    case account(provider: String, id: String)
    case unavailable(provider: String, label: String, occurrence: Int)
}

struct DetailProvider {
    let scope: DetailScope
    let label: String
}

struct DetailAccountChoice {
    let key: DetailAccountKey
    let label: String
    let providerLabel: String
    let account: UsageAccount?
    let unavailable: UsageUnavailable?

    var menuTitle: String {
        "\(label) · \(providerLabel)\(unavailable == nil ? "" : " · unavailable report")"
    }
}

struct DetailMetadata {
    let label: String
    let value: String
}

// Selected-account facts the card may show. Raw IDs, units and snapshot data stay in the JSON/core models.
struct DetailAccountInfo {
    // Present only when the provider reported a nonblank plan / a valid fetch time.
    var plan: String?
    var fetched: String?
    // Known failures: an unavailable report's reason and transport/result errors.
    var cautions: [String] = []
    // Provider-reported text has no severity schema, so it is shown neutrally.
    var accountNotes: [String] = []
    var providerNotes: [String] = []
}

struct DetailLimit {
    let limit: UsageLimit
    let showPace: Bool
    let severity: String
    // Boundaries match the overview formatter so rounding never crosses a threshold.
    var warnPercent: Double = 70
    var criticalPercent: Double = 90

    var percent: Double? {
        guard !isBalanceOnly, let fraction = limit.usedFraction, fraction.isFinite,
              (fraction * 100).isFinite else { return nil }
        return fraction * 100
    }
    var isBalanceOnly: Bool {
        limit.amount.used == nil && limit.amount.limit == nil && limit.amount.remaining != nil
    }
    var value: String {
        if isBalanceOnly { return DetailFormatting.number(limit.amount.remaining) }
        if let percent { return DetailFormatting.percent(percent, warn: warnPercent, critical: criticalPercent) }
        return "—"
    }
    var amount: String {
        let amount = limit.amount
        if isBalanceOnly { return "Available balance · \(amount.unit)" }
        if amount.used != nil || amount.limit != nil {
            return "\(DetailFormatting.number(amount.used)) / \(DetailFormatting.number(amount.limit)) \(amount.unit)"
        }
        return "Amount not reported · \(amount.unit)"
    }
    var remaining: String {
        guard limit.amount.remaining != nil else { return "Remaining not reported" }
        return "\(DetailFormatting.number(limit.amount.remaining)) \(limit.amount.unit) remaining"
    }
    var timing: String {
        let status = limit.status.map { " · \($0)" } ?? ""
        guard let window = limit.window else { return (isBalanceOnly ? "Balance only" : "Window not reported") + status }
        return "\(window.estimated == true ? "Estimated · " : "")\(window.label)\(status)"
    }
    func elapsed(now: Date) -> Double? {
        guard showPace else { return nil }
        return DisplayModel.elapsed(limit.window, now: now)
    }
    func reset(now: Date) -> String {
        guard let window = limit.window else { return "Reset not reported" }
        let prefix = window.estimated == true ? "Estimated reset" : "Resets"
        if let reset = window.resetsAt, reset.isFinite {
            return "\(prefix) \(DetailFormatting.countdown(reset, now: now))"
        }
        if let label = window.resetLabel, !label.isEmpty {
            return "\(window.estimated == true ? "Estimated · " : "")\(label)"
        }
        return "Reset not reported"
    }
    var metadata: [DetailMetadata] {
        var rows = [DetailMetadata(label: "Limit ID", value: limit.id),
                    DetailMetadata(label: "Unit", value: limit.amount.unit)]
        if let status = limit.status { rows.append(DetailMetadata(label: "Reported status", value: status)) }
        if let window = limit.window {
            rows.append(DetailMetadata(label: "Window ID", value: window.id))
            if let duration = window.durationMs {
                rows.append(DetailMetadata(label: "Window duration (ms)", value: DetailFormatting.number(duration)))
            }
            if let reset = window.resetsAt {
                rows.append(DetailMetadata(label: "Reset time", value: DetailFormatting.date(reset)))
            }
            if let label = window.resetLabel { rows.append(DetailMetadata(label: "Reset label", value: label)) }
        }
        return rows
    }
}

struct ProviderDetailContent {
    let providers: [DetailProvider]
    let choices: [DetailAccountChoice]
    let selected: DetailAccountChoice?
    let limits: [DetailLimit]
    let account: DetailAccountInfo
    let status: String
    let hasIssue: Bool
    let accountCount: Int
    let unavailableCount: Int

    var countLabel: String {
        let accounts = "\(accountCount) \(accountCount == 1 ? "account" : "accounts")"
        guard unavailableCount > 0 else { return accounts }
        return "\(accounts) · \(unavailableCount) unavailable \(unavailableCount == 1 ? "report" : "reports")"
    }
}

enum ProviderDetailModel {
    /// The dropdown catalog: typed All, then every provider observed in summaries, the full snapshot, or `scope`.
    /// Never derived from filtered summaries alone, so hidden and unavailable providers stay reachable.
    static func catalog(result: PanelResult?, scope: DetailScope?, config: PanelConfig)
        -> (providers: [DetailProvider], labels: [String: String]) {
        var providers = [DetailProvider(scope: .allAccounts, label: "All")]
        var labels: [String: String] = [:]
        for summary in result?.summaries ?? [] where labels[summary.provider] == nil {
            labels[summary.provider] = summary.label
            providers.append(DetailProvider(scope: .provider(summary.provider), label: summary.label))
        }
        let accounts = result?.snapshot?.accounts ?? []
        let unavailable = result?.snapshot?.unavailable ?? []
        for provider in accounts.map(\.provider) + unavailable.map(\.provider) where labels[provider] == nil {
            let label = config.labels[provider] ?? provider
            labels[provider] = label
            providers.append(DetailProvider(scope: .provider(provider), label: label))
        }
        if let scope, case let .provider(provider) = scope, labels[provider] == nil {
            let label = config.labels[provider] ?? provider
            labels[provider] = label
            providers.append(DetailProvider(scope: scope, label: label))
        }
        return (providers, labels)
    }

    static func make(result: PanelResult?, scope: DetailScope, selectedAccount: DetailAccountKey?,
                     config: PanelConfig, collecting: Bool, transportError: String?) -> ProviderDetailContent {
        let (providers, labels) = catalog(result: result, scope: scope, config: config)
        let accounts = result?.snapshot?.accounts ?? []
        let unavailable = result?.snapshot?.unavailable ?? []
        func includes(_ provider: String) -> Bool {
            if case let .provider(selected) = scope { return provider == selected }
            return true
        }
        var choices = accounts.filter { includes($0.provider) }.map {
            DetailAccountChoice(key: .account(provider: $0.provider, id: $0.id), label: $0.label,
                                providerLabel: labels[$0.provider] ?? $0.provider, account: $0, unavailable: nil)
        }
        // Unavailable records do not carry credential IDs. Occurrences disambiguate reports only.
        var occurrences: [String: [String: Int]] = [:]
        for report in unavailable where includes(report.provider) {
            let occurrence = occurrences[report.provider, default: [:]][report.label, default: 0]
            occurrences[report.provider, default: [:]][report.label] = occurrence + 1
            choices.append(DetailAccountChoice(key: .unavailable(provider: report.provider, label: report.label,
                                                               occurrence: occurrence), label: report.label,
                                               providerLabel: labels[report.provider] ?? report.provider,
                                               account: nil, unavailable: report))
        }
        let selected: DetailAccountChoice?
        if let key = selectedAccount, let retained = choices.first(where: { $0.key == key }) {
            selected = retained
        } else if selectedAccount == nil, case let .provider(provider) = scope,
                  let summary = result?.summaries.first(where: { $0.provider == provider }),
                  let id = summary.accountId,
                  let summarized = choices.first(where: { $0.key == .account(provider: provider, id: id) }) {
            selected = summarized
        } else {
            selected = choices.first
        }
        var info = DetailAccountInfo()
        var limits: [DetailLimit] = []
        if let account = selected?.account {
            if let plan = account.plan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty { info.plan = plan }
            info.fetched = DetailFormatting.validDate(account.fetchedAt)
            info.accountNotes = account.notes
            limits = account.limits.map { limit in
                let percent = limit.usedFraction.map { $0 * 100 }
                let severity: String
                if limit.status == "exhausted" || (percent.map { $0.isFinite && $0 >= config.criticalPercent } ?? false) {
                    severity = "critical"
                } else if let percent, percent.isFinite {
                    severity = percent >= config.warnPercent ? "warning" : "normal"
                } else { severity = "unknown" }
                return DetailLimit(limit: limit, showPace: config.showPace, severity: severity,
                                   warnPercent: config.warnPercent, criticalPercent: config.criticalPercent)
            }
        } else if let report = selected?.unavailable {
            info.cautions = [report.reason]
        }
        let summaryNotes = (result?.summaries ?? []).filter { summary in
            if case let .provider(provider) = scope { return summary.provider == provider }
            if let account = selected?.account { return summary.provider == account.provider }
            if let report = selected?.unavailable { return summary.provider == report.provider }
            return true
        }.flatMap(\.notes)
        var issues: [String] = []
        for issue in [transportError, result?.error].compactMap({ $0 }) where !issue.isEmpty && !issues.contains(issue) {
            issues.append(issue)
        }
        info.cautions.append(contentsOf: issues)
        // Exact duplicates collapse once; a note repeating a known failure is not shown twice.
        var seen = Set<String>()
        func distinct(_ values: [String]) -> [String] {
            values.compactMap { value in
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty || !seen.insert(text).inserted ? nil : text
            }
        }
        info.cautions = distinct(info.cautions)
        info.accountNotes = distinct(info.accountNotes)
        info.providerNotes = distinct(summaryNotes)
        let source = result?.source ?? "unavailable"
        let freshness: String
        switch result?.source {
        case "live": freshness = issues.isEmpty ? "Live" : "Last successful snapshot"
        case "cache": freshness = "Cached"
        case "stale": freshness = "Stale data"
        case "unavailable": freshness = "Unavailable"
        case .some(let name): freshness = "Source: \(name)"
        case .none: freshness = "Waiting for usage data"
        }
        let status = ([freshness] + (collecting ? ["Refreshing…"] : []) + issues).joined(separator: " · ")
        return ProviderDetailContent(providers: providers, choices: choices, selected: selected, limits: limits,
                                     account: info, status: status,
                                     hasIssue: !issues.isEmpty || source == "stale" || source == "unavailable" || selected?.unavailable != nil,
                                     accountCount: choices.filter { $0.account != nil }.count,
                                     unavailableCount: choices.filter { $0.unavailable != nil }.count)
    }
}

enum DetailFormatting {
    static func percent(_ percent: Double, warn: Double, critical: Double) -> String {
        guard percent.isFinite else { return "—" }
        if percent > 0 && percent < 0.1 { return "<0.1%" }
        let scaled = percent * 10
        let nearest = (scaled + 0.5).rounded(.down)
        let nearInteger = abs(scaled - nearest) <= Double.ulpOfOne * abs(scaled)
        let rounded = nearest / 10
        let crossesBoundary = [100, warn, critical].contains { percent < $0 && rounded >= $0 }
        let truncated = percent >= 1e15 ? percent
            : (nearInteger ? (crossesBoundary ? scaled.rounded(.up) - 1 : nearest) : scaled.rounded(.down)) / 10
        return "\(truncated.formatted(.number.precision(.fractionLength(0...1))))%"
    }
    static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
    static func validDate(_ milliseconds: Double) -> String? {
        guard milliseconds.isFinite, abs(milliseconds) < 8.64e15 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000).formatted(date: .abbreviated, time: .standard)
    }
    static func date(_ milliseconds: Double) -> String { validDate(milliseconds) ?? "Not reported" }
    static func countdown(_ milliseconds: Double, now: Date) -> String {
        let seconds = (milliseconds / 1000 - now.timeIntervalSince1970).rounded(.down)
        guard seconds.isFinite, abs(seconds) < Double(Int.max / 2) else { return "at \(date(milliseconds))" }
        if seconds <= 0 { return "due now" }
        let value = Int(seconds)
        if value >= 86400 { return "in \(value / 86400)d \((value % 86400) / 3600)h" }
        if value >= 3600 { return "in \(value / 3600)h \((value % 3600) / 60)m" }
        return "in \(value / 60)m \(value % 60)s"
    }
}
