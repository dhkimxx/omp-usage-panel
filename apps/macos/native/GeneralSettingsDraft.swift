import Foundation

/// Transactional, typed editing state for the 12 editable `config.json` fields (`version` stays read-only).
/// Numbers are kept as the user's text; providers/labels/metrics are ordered rows with stable identities so
/// duplicates are detected *before* any dictionary is built (a dictionary would silently keep the last row).
/// Nothing here touches disk or the committed `PanelConfig`; `candidate()` is the only way to a committable value.
struct GeneralSettingsDraft: Equatable {
    enum ProviderMode: Equatable { case automatic, custom }
    enum RowList: CaseIterable, Hashable { case providers, labels, metrics }

    enum Field: Hashable {
        case nodePath, ompPath, profile
        case refreshSeconds, cacheMinutes, timeoutSeconds, warnPercent, criticalPercent
        case providers, labels, metrics

        init?(configKey: String) {
            switch configKey {
            case "nodePath": self = .nodePath
            case "ompPath": self = .ompPath
            case "profile": self = .profile
            case "refreshSeconds": self = .refreshSeconds
            case "cacheMinutes": self = .cacheMinutes
            case "timeoutSeconds": self = .timeoutSeconds
            case "warnPercent": self = .warnPercent
            case "criticalPercent": self = .criticalPercent
            case "providers": self = .providers
            case "labels": self = .labels
            case "metrics": self = .metrics
            default: return nil
            }
        }

        /// The row list a list-level or row-level issue belongs to.
        var rowList: RowList? {
            switch self {
            case .providers: return .providers
            case .labels: return .labels
            case .metrics: return .metrics
            default: return nil
            }
        }
    }

    /// `key` is the provider ID; `value` is the label (labels) or exact limit ID (metrics); unused for providers.
    struct Row: Equatable {
        let id: Int
        var key: String
        var value: String
    }

    /// `rowID == nil` means a field-level (or whole-list) problem.
    struct Issue: Equatable {
        let field: Field
        let rowID: Int?
        let message: String
    }

    struct Failure: Error, LocalizedError {
        let issues: [Issue]
        var errorDescription: String? {
            guard let first = issues.first else { return "The settings are invalid." }
            return issues.count == 1 ? first.message : "\(first.message) (and \(issues.count - 1) more)"
        }
    }

    /// Provider and limit IDs observed in the *full* snapshot (accounts and unavailable reports), independent of
    /// the filtered summaries. Presentation labels for limits are informational only.
    struct Catalog: Equatable {
        struct Limit: Equatable { let id: String; let label: String }
        let providers: [String]
        /// Keyed by exact string identity so canonically-equivalent but distinct IDs never merge.
        private let limitsByProvider: [ExactString: [Limit]]

        init(providers: [String] = []) {
            self.providers = providers
            self.limitsByProvider = [:]
        }

        private init(providers: [String], limitsByProvider: [ExactString: [Limit]]) {
            self.providers = providers
            self.limitsByProvider = limitsByProvider
        }

        init(result: PanelResult?) {
            var providers: [String] = []
            var seen = Set<ExactString>()
            var limits: [ExactString: [Limit]] = [:]
            for account in result?.snapshot?.accounts ?? [] {
                if seen.insert(account.provider.exactKey).inserted { providers.append(account.provider) }
                var known = Set((limits[account.provider.exactKey] ?? []).map { $0.id.exactKey })
                for limit in account.limits where known.insert(limit.id.exactKey).inserted {
                    limits[account.provider.exactKey, default: []].append(Limit(id: limit.id, label: limit.label))
                }
            }
            for entry in result?.snapshot?.unavailable ?? [] where seen.insert(entry.provider.exactKey).inserted { providers.append(entry.provider) }
            self.init(providers: providers, limitsByProvider: limits)
        }

        /// Observed limits of one provider (exact ID match), in first-seen order.
        func limits(for provider: String) -> [Limit] { limitsByProvider[provider.exactKey] ?? [] }

        /// Observed provider IDs first, then every configured provider-array entry and labels/metrics key
        /// (so unreported or map-only IDs stay selectable). No allowlist; identity is exact.
        func providerSuggestions(config: PanelConfig) -> [String] {
            var result = providers
            var seen = Set(providers.map(\.exactKey))
            let configured = (config.providers ?? []) + config.labels.sortedEntries.map(\.key) + config.metrics.sortedEntries.map(\.key)
            for id in configured where !PanelConfig.isBlank(id) && seen.insert(id.exactKey).inserted { result.append(id) }
            return result
        }

        /// Observed limit IDs of one provider, plus that provider's currently configured metric ID.
        func limitSuggestions(provider: String, config: PanelConfig) -> [String] {
            var result = limits(for: provider).map(\.id)
            if let configured = config.metrics[provider], !PanelConfig.isBlank(configured), !result.contains(where: { $0.isExactlyEqual(to: configured) }) {
                result.append(configured)
            }
            return result
        }
    }

    // MARK: State

    let version: Int
    var nodePath: String
    var ompPath: String
    var profile: String
    var refreshSeconds: String
    var cacheMinutes: String
    var timeoutSeconds: String
    var warnPercent: String
    var criticalPercent: String
    var showPace: Bool
    /// Automatic (`providers: null`) versus Custom (an ordered array, possibly empty). Rows survive mode switches.
    var providerMode: ProviderMode
    private(set) var providerRows: [Row] = []
    private(set) var labelRows: [Row] = []
    private(set) var metricRows: [Row] = []
    private var nextRowID = 0

    init(config: PanelConfig) {
        version = config.version
        nodePath = config.nodePath
        ompPath = config.ompPath
        profile = config.profile
        refreshSeconds = Self.format(config.refreshSeconds)
        cacheMinutes = Self.format(config.cacheMinutes)
        timeoutSeconds = Self.format(config.timeoutSeconds)
        warnPercent = Self.format(config.warnPercent)
        criticalPercent = Self.format(config.criticalPercent)
        showPace = config.showPace
        providerMode = config.providers == nil ? .automatic : .custom
        for provider in config.providers ?? [] { addRow(.providers, key: provider) }
        for entry in config.labels.sortedEntries { addRow(.labels, key: entry.key, value: entry.value) }
        for entry in config.metrics.sortedEntries { addRow(.metrics, key: entry.key, value: entry.value) }
    }

    // MARK: Text fields

    func text(for field: Field) -> String {
        switch field {
        case .nodePath: return nodePath
        case .ompPath: return ompPath
        case .profile: return profile
        case .refreshSeconds: return refreshSeconds
        case .cacheMinutes: return cacheMinutes
        case .timeoutSeconds: return timeoutSeconds
        case .warnPercent: return warnPercent
        case .criticalPercent: return criticalPercent
        case .providers, .labels, .metrics: return ""
        }
    }

    mutating func setText(_ text: String, for field: Field) {
        switch field {
        case .nodePath: nodePath = text
        case .ompPath: ompPath = text
        case .profile: profile = text
        case .refreshSeconds: refreshSeconds = text
        case .cacheMinutes: cacheMinutes = text
        case .timeoutSeconds: timeoutSeconds = text
        case .warnPercent: warnPercent = text
        case .criticalPercent: criticalPercent = text
        case .providers, .labels, .metrics: break
        }
    }

    // MARK: Rows

    func rows(_ list: RowList) -> [Row] {
        switch list {
        case .providers: return providerRows
        case .labels: return labelRows
        case .metrics: return metricRows
        }
    }

    @discardableResult
    mutating func addRow(_ list: RowList, key: String = "", value: String = "") -> Int {
        let id = nextRowID
        nextRowID += 1
        withRows(list) { $0.append(Row(id: id, key: key, value: value)) }
        return id
    }

    /// Removing a metrics row is how a provider returns to automatic metric selection (no sentinel value exists).
    mutating func removeRow(_ list: RowList, id: Int) {
        withRows(list) { $0.removeAll { $0.id == id } }
    }

    /// Moves a row by `offset` positions, clamped to the list. Order is authoritative for providers.
    mutating func moveRow(_ list: RowList, id: Int, by offset: Int) {
        withRows(list) { rows in
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
            let destination = min(max(index + offset, 0), rows.count - 1)
            guard destination != index else { return }
            rows.insert(rows.remove(at: index), at: destination)
        }
    }

    /// Raw text is stored verbatim (no trimming or normalization).
    mutating func setRow(_ list: RowList, id: Int, key: String? = nil, value: String? = nil) {
        withRows(list) { rows in
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
            if let key { rows[index].key = key }
            if let value { rows[index].value = value }
        }
    }

    private mutating func withRows(_ list: RowList, _ body: (inout [Row]) -> Void) {
        switch list {
        case .providers: body(&providerRows)
        case .labels: body(&labelRows)
        case .metrics: body(&metricRows)
        }
    }

    // MARK: Commit candidate

    /// Parses and validates the whole draft. On success the value satisfies `PanelConfig.validate()`; otherwise
    /// every problem is reported (per field or per row) and nothing is built.
    func candidate() throws -> PanelConfig {
        var issues: [Issue] = []
        func report(_ field: Field, _ message: String, row rowID: Int? = nil) { issues.append(Issue(field: field, rowID: rowID, message: message)) }

        if PanelConfig.isBlank(nodePath) || !nodePath.hasPrefix("/") { report(.nodePath, "Enter an absolute path starting with /.") }
        if PanelConfig.isBlank(ompPath) || !ompPath.hasPrefix("/") { report(.ompPath, "Enter an absolute path starting with /.") }
        if PanelConfig.isBlank(profile) { report(.profile, "Enter a profile name.") }

        /// `positive` requires > 0, otherwise >= 0; `scale` is the unit-to-millisecond factor that must stay finite.
        func number(_ field: Field, _ text: String, positive: Bool, scale: Double? = nil) -> Double? {
            guard let value = Self.parseNumber(text) else { report(field, "Enter a number."); return nil }
            guard value.isFinite, scale.map({ (value * $0).isFinite }) ?? true else { report(field, "That number is too large."); return nil }
            guard positive ? value > 0 : value >= 0 else { report(field, positive ? "Must be greater than 0." : "Must be 0 or greater."); return nil }
            return value
        }
        let parsedRefresh = number(.refreshSeconds, refreshSeconds, positive: true, scale: 1000)
        let parsedCache = number(.cacheMinutes, cacheMinutes, positive: false, scale: 60000)
        let parsedTimeout = number(.timeoutSeconds, timeoutSeconds, positive: true, scale: 1000)
        let parsedWarn = number(.warnPercent, warnPercent, positive: false)
        let parsedCritical = number(.criticalPercent, criticalPercent, positive: false)
        if let warn = parsedWarn, let critical = parsedCritical, critical < warn { report(.criticalPercent, "Must be at least the warning percentage.") }

        var providers: [String]?
        if providerMode == .custom {
            var seen = Set<ExactString>()
            for row in providerRows {
                if PanelConfig.isBlank(row.key) { report(.providers, "Enter a provider ID or remove this row.", row: row.id) }
                else if !seen.insert(row.key.exactKey).inserted { report(.providers, "This provider ID is already listed.", row: row.id) }
            }
            providers = providerRows.map(\.key)
        }

        /// Duplicate detection is exact (same scalars), the identity Node and `ExactConfigMap` use; canonically
        /// equivalent but distinct IDs are separate, legal entries.
        func map(_ list: RowList, _ field: Field, valueName: String) -> ExactConfigMap {
            var result = ExactConfigMap()
            var seen = Set<ExactString>()
            for row in rows(list) {
                if PanelConfig.isBlank(row.key) { report(field, "Enter a provider ID.", row: row.id) }
                else if !seen.insert(row.key.exactKey).inserted { report(field, "This provider ID already has a row.", row: row.id) }
                if PanelConfig.isBlank(row.value) { report(field, "Enter \(valueName).", row: row.id) }
                if !PanelConfig.isBlank(row.key), !PanelConfig.isBlank(row.value) { result[row.key] = row.value }
            }
            return result
        }
        let labels = map(.labels, .labels, valueName: "a label")
        let metrics = map(.metrics, .metrics, valueName: "a limit ID")

        guard issues.isEmpty, let refresh = parsedRefresh, let cache = parsedCache, let timeout = parsedTimeout,
              let warn = parsedWarn, let critical = parsedCritical else {
            throw Failure(issues: issues)
        }
        let config = PanelConfig(version: version, nodePath: nodePath, ompPath: ompPath, profile: profile,
                                 refreshSeconds: refresh, cacheMinutes: cache, timeoutSeconds: timeout,
                                 providers: providers, labels: labels, metrics: metrics,
                                 warnPercent: warn, criticalPercent: critical, showPace: showPace)
        do { try config.validate() }
        catch let error as PanelConfigError {
            if case .invalid(let key, let rule) = error {
                throw Failure(issues: [Issue(field: Field(configKey: key) ?? .nodePath, rowID: nil, message: "Invalid value: \(rule).")])
            }
            throw Failure(issues: [Issue(field: .nodePath, rowID: nil, message: error.localizedDescription)])
        }
        return config
    }

    // MARK: Number text

    /// Shortest round-trip decimal text without a trailing ".0".
    static func format(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }

    /// Strict decimal parser: optional sign, digits with an optional fraction, optional exponent; surrounding
    /// whitespace allowed. Rejects hex, `inf`, `nan`, separators and empty text. May return +/-infinity on overflow.
    static func parseNumber(_ text: String) -> Double? {
        let scalars = Array(text.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end, PanelConfig.isJSWhitespace(scalars[start]) { start += 1 }
        while end > start, PanelConfig.isJSWhitespace(scalars[end - 1]) { end -= 1 }
        var index = start
        func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 48 && scalar.value <= 57 }
        func digits() -> String {
            var run = String.UnicodeScalarView()
            while index < end, isDigit(scalars[index]) { run.append(scalars[index]); index += 1 }
            return String(run)
        }
        func sign() -> String {
            guard index < end, scalars[index] == "+" || scalars[index] == "-" else { return "" }
            defer { index += 1 }
            return scalars[index] == "-" ? "-" : ""
        }
        let mantissaSign = sign()
        let whole = digits()
        var fraction = ""
        if index < end, scalars[index] == "." { index += 1; fraction = digits() }
        guard !whole.isEmpty || !fraction.isEmpty else { return nil }
        var exponent = ""
        if index < end, scalars[index] == "e" || scalars[index] == "E" {
            index += 1
            let exponentSign = sign()
            let exponentDigits = digits()
            guard !exponentDigits.isEmpty else { return nil }
            exponent = "e" + exponentSign + exponentDigits
        }
        guard index == end else { return nil }
        // Canonical form so "5." and ".5" never depend on the platform's partial-decimal handling.
        return Double(mantissaSign + (whole.isEmpty ? "0" : whole) + "." + (fraction.isEmpty ? "0" : fraction) + exponent)
    }
}
