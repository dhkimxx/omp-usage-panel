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

struct ExternalSource: Equatable, Encodable {
    let providerId: String
    let path: String

    static func == (lhs: ExternalSource, rhs: ExternalSource) -> Bool {
        lhs.providerId.isExactlyEqual(to: rhs.providerId) && lhs.path.isExactlyEqual(to: rhs.path)
    }
}

/// Immutable committed configuration. Legacy files may omit `externalSources`; `providers == nil` is the explicit JSON `null`
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
    private(set) var externalSources: [ExternalSource] = []

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
            && lhs.criticalPercent == rhs.criticalPercent && lhs.showPace == rhs.showPace && lhs.externalSources == rhs.externalSources
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
        guard externalSources.allSatisfy({ !Self.isBlank($0.providerId) && $0.path.hasPrefix("/") && !$0.path.contains("\0") }) else {
            throw invalid("externalSources", "must contain non-blank provider IDs and absolute file paths")
        }
        guard Set(externalSources.map { $0.providerId.exactKey }).count == externalSources.count else {
            throw invalid("externalSources", "must not contain duplicate provider IDs")
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
struct ProviderSource: Decodable {
    let provider: String
    let source: String
    let capturedAt: Double?
    let error: String?
}
/// Bridge provenance, not a new producer wire version. An empty successful OMP roster still has its own clock.
struct OMPSource: Decodable {
    let source: String
    let capturedAt: Double?
    let providers: [String]
    let error: String?
}
struct PanelResult: Decodable {
    let snapshot: UsageSnapshot?
    let source: String
    let error: String?
    let summaries: [ProviderSummary]
    var providerSources: [ProviderSource]? = nil
    var ompSource: OMPSource? = nil

    func source(for provider: String) -> ProviderSource? {
        providerSources?.first { $0.provider.isExactlyEqual(to: provider) }
    }
}

/// The last CONFIRMED set of connected providers for one profile/config. A SUCCESSFUL OMP collection
/// (snapshot present, source live or cache, no OMP error; an empty roster counts) replaces OMP membership,
/// independently of external freshness. Configured external providers retain membership even when their files fail.
/// Without source metadata, a successful result confirms every provider in summaries, accounts and unavailable
/// reports. A connected provider whose usage fetch failed is still listed as unavailable.
/// A stale fallback or failed OMP collection proves nothing about OMP absence and leaves confirmation untouched.
/// `known == nil` means no OMP roster was ever confirmed (first load, restart): callers keep saved placeholders.
/// In memory only; `reset()` on a genuine profile/config-source change.
///
/// `confirmedAt` is the snapshot time of the data that confirmed it. A collection can hand back an OLDER snapshot
/// than one already accepted (the disk cache is best effort: after a failed cache write a later failure or cache
/// hit returns the pre-removal file). Such data must neither replace what is shown nor move the roster backwards.
struct ConnectedProviders: Equatable {
    private(set) var known: Set<ExactString>?
    private(set) var confirmedAt: Double?

    enum Disposition: Equatable {
        /// Show it and let it update the roster.
        case accept
        /// Older than the confirmed data: keep what is shown. `error` is the failure to surface, nil for a healthy
        /// (cache) answer that merely carries older data.
        case keepNewer(error: String?)
    }

    /// A live answer is fresh by construction and always accepted. Cache and stale answers are accepted unless their
    /// snapshot predates the confirmed one; with nothing confirmed yet (first load) everything is accepted.
    func disposition(of incoming: PanelResult) -> Disposition {
        guard let confirmedAt, incoming.snapshot != nil,
              let capturedAt = incoming.ompSource.map({ $0.capturedAt }) ?? incoming.snapshot?.capturedAt,
              (incoming.ompSource?.source ?? incoming.source) != "live",
              capturedAt < confirmedAt else { return .accept }
        return .keepNewer(error: incoming.error ?? (incoming.source == "stale" ? "Usage refresh failed" : nil))
    }

    mutating func observe(_ result: PanelResult) {
        guard let snapshot = result.snapshot else { return }
        let source = result.ompSource?.source ?? result.source
        let error = result.ompSource.map(\.error) ?? result.error
        guard source == "live" || source == "cache", (error ?? "").isEmpty,
              let capturedAt = result.ompSource.map({ $0.capturedAt }) ?? snapshot.capturedAt else { return }
        if let confirmedAt, capturedAt < confirmedAt,
           result.ompSource != nil || source != "live" { return }
        var ids = Set<ExactString>()
        if let omp = result.ompSource {
            ids.formUnion(omp.providers.map(\.exactKey))
            // Bridge metadata includes every configured external ID, even with no usable snapshot.
            // Summary selections alone are not evidence of an OMP connection.
            ids.formUnion((result.providerSources ?? []).map { $0.provider.exactKey })
        } else {
            for summary in result.summaries { ids.insert(summary.provider.exactKey) }
            for account in snapshot.accounts { ids.insert(account.provider.exactKey) }
            for report in snapshot.unavailable { ids.insert(report.provider.exactKey) }
        }
        known = ids
        confirmedAt = capturedAt
    }

    mutating func reset() { known = nil; confirmedAt = nil }
}

/// What the panel shows and why: the accepted usage data, the latest collection failure to surface next to it, and
/// the confirmed roster. One place decides what a collector outcome may change, so the compact row, overview,
/// provider dropdown and account details all read the same accepted data.
struct UsageIntake {
    private(set) var result: PanelResult?
    private(set) var transportError: String?
    private(set) var roster = ConnectedProviders()
    // A missing external observation is the latest seen state, but must not erase its last successful clock.
    // The producer retains last-good payloads; the consumer only prevents an older file from rolling them back.
    private var externalSuccessAt: [ExactString: Double] = [:]

    /// Returns true when `result` was replaced by this outcome.
    @discardableResult
    mutating func receive(_ value: Result<PanelResult, Error>) -> Bool {
        switch value {
        case .failure(let error):
            transportError = error.localizedDescription
            return false
        case .success(let incoming):
            if incoming.snapshot == nil, result?.snapshot != nil {
                transportError = incoming.error ?? "Usage is unavailable"
                return false
            }
            if incoming.ompSource != nil {
                let accepted = acceptingIndependentSources(incoming)
                result = accepted
                transportError = nil
                // A retained newer OMP group is display data, not a newly confirmed collection.
                if accepted.ompSource?.capturedAt == incoming.ompSource?.capturedAt { roster.observe(accepted) }
                return true
            }
            switch roster.disposition(of: incoming) {
            case .keepNewer(let error):
                // The newest accepted data stays; a stale fallback's failure stays visible beside it.
                if let error { transportError = error }
                return false
            case .accept:
                result = incoming
                transportError = nil
                roster.observe(incoming)
                return true
            }
        }
    }

    /// Retain only source groups whose incoming clock moved backwards. Other groups still advance, including
    /// external quota arriving alongside an old OMP disk cache. Only healthy OMP data confirms OMP membership.
    private mutating func acceptingIndependentSources(_ incoming: PanelResult) -> PanelResult {
        guard let omp = incoming.ompSource else { return incoming }
        let previous = result
        let ompIDs = Set(omp.providers.map(\.exactKey))
        let external = (incoming.providerSources ?? []).filter { !ompIDs.contains($0.provider.exactKey) }
        let externalIDs = Set(external.map { $0.provider.exactKey })
        let previousOMP = previous?.ompSource ?? OMPSource(
            source: previous?.source ?? "unavailable", capturedAt: previous?.snapshot?.capturedAt,
            providers: Array(Set((previous?.snapshot?.accounts.map(\.provider) ?? []) +
                (previous?.snapshot?.unavailable.map(\.provider) ?? []))),
            error: previous?.error)
        let previousOMPIDs = Set(previousOMP.providers.map(\.exactKey)).subtracting(externalIDs)
        var discarded = Set<ExactString>(), retained = Set<ExactString>()
        var retainedOMP = false
        var effectiveOMP = omp
        var sources = incoming.providerSources ?? []
        if let acceptedAt = previousOMP.capturedAt, (omp.capturedAt ?? -.infinity) < acceptedAt {
            retainedOMP = true
            discarded.formUnion(ompIDs); discarded.formUnion(previousOMPIDs)
            retained.formUnion(previousOMPIDs)
            let error = omp.error ?? previousOMP.error
            effectiveOMP = OMPSource(source: error == nil ? previousOMP.source : "stale", capturedAt: acceptedAt,
                                     providers: previousOMP.providers.filter { previousOMPIDs.contains($0.exactKey) }, error: error)
            sources.removeAll { discarded.contains($0.provider.exactKey) }
            sources += effectiveOMP.providers.map { provider in
                let old = previous?.source(for: provider)
                return ProviderSource(provider: provider, source: error == nil ? (old?.source ?? previousOMP.source) : "stale",
                                      capturedAt: old?.capturedAt ?? acceptedAt, error: error ?? old?.error)
            }
        }
        for source in external {
            let key = source.provider.exactKey
            if let capturedAt = source.capturedAt {
                if let acceptedAt = externalSuccessAt[key], capturedAt < acceptedAt {
                    discarded.insert(key); retained.insert(key)
                    sources.removeAll { $0.provider.exactKey == key }
                    if let old = previous?.source(for: source.provider) {
                        sources.append(ProviderSource(provider: old.provider,
                            source: source.error == nil ? old.source : old.capturedAt == nil ? "unavailable" : "stale",
                            capturedAt: old.capturedAt, error: source.error ?? old.error))
                    }
                } else if source.source == "cache", (source.error ?? "").isEmpty { externalSuccessAt[key] = capturedAt }
            }
        }
        guard retainedOMP || !discarded.isEmpty else { return incoming }
        let accounts = (incoming.snapshot?.accounts ?? []).filter { !discarded.contains($0.provider.exactKey) } +
            (previous?.snapshot?.accounts ?? []).filter { retained.contains($0.provider.exactKey) }
        let unavailable = (incoming.snapshot?.unavailable ?? []).filter { !discarded.contains($0.provider.exactKey) } +
            (previous?.snapshot?.unavailable ?? []).filter { retained.contains($0.provider.exactKey) }
        // Keep configured summary order while excluding providers absent from the newer retained OMP roster.
        var summaries = incoming.summaries.compactMap { summary -> ProviderSummary? in
            guard discarded.contains(summary.provider.exactKey) else { return summary }
            return retained.contains(summary.provider.exactKey) ? previous?.summaries.first {
                $0.provider.isExactlyEqual(to: summary.provider)
            } : nil
        }
        let shown = Set(summaries.map { $0.provider.exactKey })
        summaries += (previous?.summaries ?? []).filter { retained.contains($0.provider.exactKey) && !shown.contains($0.provider.exactKey) }
        let healthyOMP = (effectiveOMP.source == "live" || effectiveOMP.source == "cache") && (effectiveOMP.error ?? "").isEmpty
        let healthyExternal = sources.filter { externalIDs.contains($0.provider.exactKey) }
            .map { ($0.source == "live" || $0.source == "cache") && ($0.error ?? "").isEmpty }
        let healthy = healthyOMP || healthyExternal.contains(true)
        let failed = !healthyOMP || healthyExternal.contains(false)
        let captures = [effectiveOMP.capturedAt].compactMap { $0 } + sources.filter {
            externalIDs.contains($0.provider.exactKey) && $0.source != "unavailable"
        }.compactMap(\.capturedAt)
        let snapshot = captures.min().map { UsageSnapshot(version: 1, capturedAt: $0, accounts: accounts, unavailable: unavailable) }
        return PanelResult(snapshot: snapshot, source: failed ? (healthy ? "partial" : snapshot == nil ? "unavailable" : "stale") : effectiveOMP.source,
                           error: failed ? (incoming.error ?? effectiveOMP.error ?? "Usage data is unavailable") : nil,
                           summaries: summaries, providerSources: sources, ompSource: effectiveOMP)
    }

    /// A genuine profile/config-source change: nothing from the previous source may decide anything.
    mutating func reset() {
        result = nil; transportError = nil; roster.reset(); externalSuccessAt.removeAll()
    }
}

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
