import Foundation

/// Errors from the strict panel-configuration codec, validator and store. Messages name the field and rule only;
/// they never include raw configuration content.
enum PanelConfigError: Error, LocalizedError, Equatable {
    case invalid(field: String, rule: String)
    case malformed
    case unreadable(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let field, let rule): return "Invalid panel configuration: \(field) \(rule)."
        case .malformed: return "Invalid panel configuration: the file is not valid JSON."
        case .unreadable(let reason): return "Cannot read the panel configuration: \(reason)"
        case .writeFailed(let reason): return "Cannot write the panel configuration: \(reason)"
        }
    }
}

/// Immutable committed configuration. Every key is required; `providers == nil` is the explicit JSON `null`
/// (automatic membership/order) and is distinct from `[]` (no summary providers). Equality is exact (UTF-16
/// identity for every string, ordered providers, exact map keys), never Swift canonical equivalence.
struct PanelConfig: Equatable {
    let version: Int
    let nodePath: String
    let ompPath: String
    let profile: String
    let refreshSeconds: Double
    let cacheMinutes: Double
    let timeoutSeconds: Double
    let providers: [String]?
    let labels: ExactConfigMap
    let metrics: ExactConfigMap
    let warnPercent: Double
    let criticalPercent: Double
    let showPace: Bool

    static func == (lhs: PanelConfig, rhs: PanelConfig) -> Bool {
        let sameProviders: Bool
        switch (lhs.providers, rhs.providers) {
        case (nil, nil): sameProviders = true
        case (let left?, let right?): sameProviders = left.count == right.count && zip(left, right).allSatisfy { $0.isExactlyEqual(to: $1) }
        default: sameProviders = false
        }
        return lhs.version == rhs.version && lhs.nodePath.isExactlyEqual(to: rhs.nodePath) && lhs.ompPath.isExactlyEqual(to: rhs.ompPath)
            && lhs.profile.isExactlyEqual(to: rhs.profile) && lhs.refreshSeconds == rhs.refreshSeconds
            && lhs.cacheMinutes == rhs.cacheMinutes && lhs.timeoutSeconds == rhs.timeoutSeconds && sameProviders
            && lhs.labels == rhs.labels && lhs.metrics == rhs.metrics && lhs.warnPercent == rhs.warnPercent
            && lhs.criticalPercent == rhs.criticalPercent && lhs.showPace == rhs.showPace
    }
}

extension PanelConfig {
    /// ECMAScript `String.prototype.trim` whitespace (the Node validator's definition of blank).
    static func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }

    /// True for the empty string and for strings of only ECMAScript whitespace.
    static func isBlank(_ text: String) -> Bool { text.unicodeScalars.allSatisfy(isJSWhitespace) }

    /// Mirrors apps/macos/config.mjs `parseConfig` rule for rule. Values are never normalized.
    func validate() throws {
        func invalid(_ field: String, _ rule: String) -> PanelConfigError { .invalid(field: field, rule: rule) }
        guard version == 1 else { throw invalid("version", "must be 1") }
        guard !Self.isBlank(nodePath), nodePath.hasPrefix("/") else { throw invalid("nodePath", "must be a non-blank absolute path") }
        guard !Self.isBlank(ompPath), ompPath.hasPrefix("/") else { throw invalid("ompPath", "must be a non-blank absolute path") }
        guard !Self.isBlank(profile) else { throw invalid("profile", "must be a non-blank string") }
        guard refreshSeconds.isFinite, refreshSeconds > 0, (refreshSeconds * 1000).isFinite else { throw invalid("refreshSeconds", "must be a finite number greater than 0 that stays finite in milliseconds") }
        guard cacheMinutes.isFinite, cacheMinutes >= 0, (cacheMinutes * 60000).isFinite else { throw invalid("cacheMinutes", "must be a finite number of 0 or more that stays finite in milliseconds") }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, (timeoutSeconds * 1000).isFinite else { throw invalid("timeoutSeconds", "must be a finite number greater than 0 that stays finite in milliseconds") }
        if let providers {
            guard providers.allSatisfy({ !Self.isBlank($0) }) else { throw invalid("providers", "must contain only non-blank strings") }
            // Exact (code-unit) uniqueness, like the JS Set, not Swift's canonical-equivalence equality.
            guard Set(providers.map(\.exactKey)).count == providers.count else { throw invalid("providers", "must not contain duplicates") }
        }
        guard labels.allSatisfy({ !Self.isBlank($0.key) && !Self.isBlank($0.value) }) else { throw invalid("labels", "must map non-blank keys to non-blank strings") }
        guard metrics.allSatisfy({ !Self.isBlank($0.key) && !Self.isBlank($0.value) }) else { throw invalid("metrics", "must map non-blank keys to non-blank strings") }
        guard warnPercent.isFinite, warnPercent >= 0 else { throw invalid("warnPercent", "must be a finite number of 0 or more") }
        guard criticalPercent.isFinite, criticalPercent >= warnPercent else { throw invalid("criticalPercent", "must be a finite number not below warnPercent") }
    }
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
