import Foundation
import CoreGraphics

struct DashboardCard {
    let provider: String
    let label: String
    let value: String
    let severity: String
    let percent: Double?
    let metric: String
    let context: String
    let tooltip: String
    let window: UsageWindow?
    let showPace: Bool
    let hasIssue: Bool

    func resetText(now: Date = Date()) -> String {
        guard let window = window else { return "Reset unavailable" }
        let estimated = window.estimated == true
        if let reset = window.resetsAt, reset.isFinite {
            // DisplayModel.countdown converts to Int; invalid clock metadata must not trap.
            let seconds = (reset / 1000 - now.timeIntervalSince1970).rounded(.down)
            if seconds.isFinite, seconds > Double(Int.min), seconds < Double(Int.max) {
                let countdown = DisplayModel.countdown(reset, now: now)
                if countdown == "due now" { return estimated ? "Est. reset due now" : "Reset due now" }
                return estimated ? "Est. reset \(countdown)" : "Resets in \(countdown)"
            }
        }
        if let label = window.resetLabel, !label.isEmpty {
            return estimated ? "Est. reset · \(label)" : label
        }
        return estimated ? "Est. reset unavailable" : "Reset unavailable"
    }

    func elapsed(now: Date = Date()) -> Double? {
        guard showPace, now.timeIntervalSince1970.isFinite else { return nil }
        return DisplayModel.elapsed(window, now: now)
    }
}

struct DashboardContent {
    let cards: [DashboardCard]
    let status: String
    let footer: String
    let issue: String
}

enum DashboardModel {
    static func make(result: PanelResult?, issue: String, collecting: Bool,
                     showPace: Bool) -> DashboardContent {
        let source: String
        switch result?.source {
        case "live": source = issue.isEmpty ? "Live" : "Last successful snapshot"
        case "cache": source = "Cached"
        case "stale": source = "Stale data"
        case "unavailable": source = "Unavailable"
        case .some(let name): source = "Source: \(name)"
        case .none: source = "Waiting for usage data"
        }
        var statusParts = [source]
        if collecting { statusParts.append("Refreshing…") }
        if !issue.isEmpty { statusParts.append(issue) }
        else if let error = result?.error, !error.isEmpty { statusParts.append(error) }
        let status = statusParts.joined(separator: " · ")
        let sourceIssue = !issue.isEmpty || result?.source == "stale" || result?.source == "unavailable" || !(result?.error ?? "").isEmpty
        let cards = (result?.summaries ?? []).map { summary in
            // Summary selection is authoritative. Never borrow a different account or limit's window.
            let account = result?.snapshot?.accounts.first {
                $0.provider == summary.provider && $0.id == summary.accountId
            }
            let limit = account?.limits.first { $0.id == summary.metricId }
            let window = limit?.window
            let metric = summary.metricLabel ?? limit?.label ?? summary.windowLabel ?? "Usage"
            let context: String
            if summary.accountCount > 1 {
                context = "\(summary.accountCount) accounts"
            } else {
                context = account?.plan ?? account?.label ?? summary.accountLabel ?? "Account unavailable"
            }
            let unavailable = result?.snapshot?.unavailable.filter { $0.provider == summary.provider } ?? []
            var details = ["\(summary.label): \(summary.value)", "Metric: \(metric)", status]
            if let account = account {
                details.append("Account: \(account.label) (\(account.id))")
                if let plan = account.plan { details.append("Plan: \(plan)") }
                if let fetched = timestamp(account.fetchedAt) { details.append("Fetched: \(fetched)") }
                details.append(contentsOf: account.notes)
            } else {
                let identity = summary.accountLabel ?? summary.accountId ?? "unknown"
                details.append("Account: \(identity) · Selected account data unavailable")
            }
            if let limit = limit {
                details.append("Metric ID: \(limit.id)")
                details.append(DisplayModel.amount(limit.amount))
                if let limitStatus = limit.status { details.append(limitStatus) }
                if let window = window {
                    details.append("\(window.estimated == true ? "Estimated " : "")\(window.label)")
                    if let reset = window.resetsAt, let date = timestamp(reset) { details.append("Resets: \(date)") }
                    if let resetLabel = window.resetLabel { details.append(resetLabel) }
                }
                details.append(contentsOf: limit.notes)
            } else {
                if let id = summary.metricId { details.append("Metric ID: \(id)") }
                details.append("Selected metric data unavailable · Reset unavailable")
            }
            if summary.accountCount > 1 { details.append("\(summary.accountCount) accounts") }
            if let capturedAt = result?.snapshot?.capturedAt, let captured = timestamp(capturedAt) {
                details.append("Snapshot: \(captured)")
            }
            details.append(contentsOf: summary.notes)
            details.append(contentsOf: unavailable.map { "\($0.label): \($0.reason)" })
            return DashboardCard(provider: summary.provider, label: summary.label, value: summary.value,
                                 severity: summary.severity, percent: summary.percent, metric: metric,
                                 context: context, tooltip: details.joined(separator: "\n"), window: window,
                                 showPace: showPace, hasIssue: sourceIssue || summary.percent == nil ||
                                    summary.severity == "unknown" || summary.severity == "unavailable" ||
                                    summary.severity == "error" || !unavailable.isEmpty)
        }
        var footer = "\(cards.count) \(cards.count == 1 ? "provider" : "providers")"
        if let snapshot = result?.snapshot {
            footer += " · \(snapshot.accounts.count) \(snapshot.accounts.count == 1 ? "account" : "accounts")"
            if let captured = timestamp(snapshot.capturedAt, includeDate: false) { footer += " · Snapshot \(captured)" }
        } else {
            footer += " · No snapshot available"
        }
        return DashboardContent(cards: cards, status: status, footer: footer, issue: issue)
    }

    private static func timestamp(_ milliseconds: Double, includeDate: Bool = true) -> String? {
        guard milliseconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000).formatted(date: includeDate ? .abbreviated : .omitted, time: .shortened)
    }
}

struct CompactIndicatorMetrics {
    let itemWidth: CGFloat
    let spacing: CGFloat
    let contentWidth: CGFloat
}

enum DashboardSizing {
    static let cardWidth: CGFloat = 128
    static let cardHeight: CGFloat = 148
    static let cardPadding: CGFloat = 12
    static let cardGap: CGFloat = 10
    static let padding: CGFloat = 20
    static let bodyHeight = headerHeight(cameraHeight: 0) + cardHeight + 56
    static func headerHeight(cameraHeight: CGFloat) -> CGFloat {
        max(44, cameraHeight.isFinite ? cameraHeight + 12 : 0)
    }

    static func preferredSize(providerCount: Int, cameraHeight: CGFloat) -> CGSize {
        // Additional providers scroll inside the board rather than widening it off-screen.
        let count = CGFloat(min(max(providerCount, 0), 5))
        return CGSize(width: max(360, padding * 2 + count * cardWidth + max(0, count - 1) * cardGap),
                      height: headerHeight(cameraHeight: cameraHeight) + cardHeight + 56)
    }

    static func compactIndicators(count: Int, stripWidth: CGFloat) -> CompactIndicatorMetrics {
        guard count > 0, stripWidth.isFinite, stripWidth > 0 else {
            return CompactIndicatorMetrics(itemWidth: 0, spacing: 0, contentWidth: 0)
        }
        let availableWidth = stripWidth - min(20, stripWidth * 0.2)
        let count = CGFloat(count)
        let budget = min(availableWidth, count * 18 + (count - 1) * 4)
        let gap = min(4, budget / (count * 5))
        return CompactIndicatorMetrics(itemWidth: (budget - gap * (count - 1)) / count,
                                       spacing: gap, contentWidth: budget)
    }
}
