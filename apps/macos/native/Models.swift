import Foundation

struct PanelConfig: Decodable {
    let version: Int
    let nodePath: String
    let ompPath: String
    let profile: String
    let refreshSeconds: Double
    let cacheMinutes: Double
    let timeoutSeconds: Double
    let providers: [String]?
    let labels: [String: String]
    let metrics: [String: String]
    let warnPercent: Double
    let criticalPercent: Double
    let showPace: Bool
}
struct UsageAmount: Decodable { let unit: String; let used: Double?; let limit: Double?; let remaining: Double? }
struct UsageWindow: Decodable { let id: String; let label: String; let durationMs: Double?; let resetsAt: Double?; let resetLabel: String?; let estimated: Bool? }
struct UsageLimit: Decodable { let id: String; let label: String; let amount: UsageAmount; let window: UsageWindow?; let usedFraction: Double?; let status: String?; let notes: [String] }
struct UsageAccount: Decodable { let id: String; let provider: String; let label: String; let fetchedAt: Double; let plan: String?; let notes: [String]; let limits: [UsageLimit] }
struct UsageUnavailable: Decodable { let provider: String; let label: String; let reason: String }
struct UsageSnapshot: Decodable { let version: Int; let capturedAt: Double; let accounts: [UsageAccount]; let unavailable: [UsageUnavailable] }
struct ProviderSummary: Decodable {
    let provider: String; let label: String; let percent: Double?; let value: String; let severity: String
    let accountCount: Int; let accountId: String?; let accountLabel: String?; let metricId: String?; let metricLabel: String?; let windowLabel: String?; let notes: [String]
}
struct PanelResult: Decodable { let snapshot: UsageSnapshot?; let source: String; let error: String?; let summaries: [ProviderSummary] }

enum DisplayModel {
    static func number(_ value: Double?) -> String {
        guard let value = value, value.isFinite else { return "unknown" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
    static func amount(_ amount: UsageAmount) -> String {
        var parts: [String] = []
        if amount.used != nil || amount.limit != nil { parts.append("Used \(number(amount.used)) / \(number(amount.limit)) \(amount.unit)") }
        if let remaining = amount.remaining { parts.append("Remaining \(number(remaining)) \(amount.unit)") }
        return parts.isEmpty ? "Amount unknown (\(amount.unit))" : parts.joined(separator: " · ")
    }
    static func countdown(_ milliseconds: Double, now: Date = Date()) -> String {
        let seconds = Int((milliseconds / 1000 - now.timeIntervalSince1970).rounded(.down))
        if seconds <= 0 { return "due now" }
        if seconds >= 86400 { return "\(seconds / 86400)d \((seconds % 86400) / 3600)h" }
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
    static func elapsed(_ window: UsageWindow?, now: Date = Date()) -> Double? {
        guard let window = window, let duration = window.durationMs, duration > 0, let reset = window.resetsAt, duration.isFinite, reset.isFinite else { return nil }
        return min(1, max(0, 1 - (reset - now.timeIntervalSince1970 * 1000) / duration))
    }
}
