import Foundation

/// Read-only view of one profile's saved compact preferences plus the provider choices to show. Foundation-only;
/// built by the integrator (live choices for the running profile, saved IDs for any other profile).
struct CompactSettingsSnapshot: Equatable {
    let preferences: CompactPreferences
    let providers: [CompactProviderChoice]
}

/// One compact-preferences write, scoped by the trimmed profile name (`default` when blank).
struct ScopedCompactChange: Equatable {
    let profile: String
    let preferences: CompactPreferences
}

/// Everything one Save commits: the collector configuration, the staged updater policy and every changed
/// profile-scoped compact draft (only drafts that differ from their saved baseline appear).
struct SettingsCommit: Equatable {
    let config: PanelConfig
    let updatePolicy: UpdatePolicy
    let compactChanges: [ScopedCompactChange]
    let placement: PanelPlacementPreferences
}

/// Staged compact-view editing state for ONE profile scope. `maximumText` is kept as typed so invalid text is
/// reportable; selection and per-provider sides are edited values over a saved `baseline`. Nothing here persists.
struct CompactSettingsDraft: Equatable {
    static let invalidMaximumMessage = "Enter a whole number of 1 or more."

    private(set) var baseline: CompactSettingsSnapshot
    var maximumText: String
    private(set) var selectedProviderIDs: [String]?
    private(set) var providerSides: [String: CompactWingSide]

    init(snapshot: CompactSettingsSnapshot) {
        baseline = snapshot
        maximumText = String(snapshot.preferences.maximumVisibleSlots)
        selectedProviderIDs = snapshot.preferences.selectedProviderIDs
        providerSides = snapshot.preferences.providerSides
    }

    // MARK: Reading

    /// Strict whole number >= 1 (surrounding spaces allowed, ASCII digits only).
    static func parseMaximum(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(trimmed), value >= 1 else { return nil }
        return value
    }

    var parsedMaximum: Int? { Self.parseMaximum(maximumText) }

    /// Reported providers first, then every saved or staged selection that is not reported (kept selectable).
    var choices: [CompactProviderChoice] {
        var result = baseline.providers
        var known = Set(result.map { $0.id.exactKey })
        for id in (baseline.preferences.selectedProviderIDs ?? []) + (selectedProviderIDs ?? []) where known.insert(id.exactKey).inserted {
            result.append(CompactProviderChoice(id: id, label: id, detail: nil, isReported: false))
        }
        return result
    }

    func isSelected(_ id: String) -> Bool { (selectedProviderIDs ?? []).contains { $0.isExactlyEqual(to: id) } }

    func side(for id: String) -> CompactWingSide { currentPreferences(maximum: 1).side(for: id) }

    /// The staged preferences, or nil while the maximum text is invalid.
    func preferences() -> CompactPreferences? { parsedMaximum.map { currentPreferences(maximum: $0) } }

    private func currentPreferences(maximum: Int) -> CompactPreferences {
        CompactPreferences(maximumVisibleSlots: maximum, selectedProviderIDs: selectedProviderIDs,
                           defaultSide: baseline.preferences.defaultSide, providerSides: providerSides)
    }

    /// True when the staged values differ in effect from the saved ones (typing then reverting is no change; an
    /// override equal to the default side counts the same as no override). Invalid maximum text is a change.
    var hasChanges: Bool {
        guard let staged = preferences() else { return true }
        return !Self.sameEffect(staged, baseline.preferences)
    }

    private static func sameEffect(_ a: CompactPreferences, _ b: CompactPreferences) -> Bool {
        guard a.maximumVisibleSlots == b.maximumVisibleSlots, a.defaultSide == b.defaultSide,
              sameIDs(a.selectedProviderIDs, b.selectedProviderIDs) else { return false }
        return Set(a.providerSides.keys).union(b.providerSides.keys).allSatisfy { a.side(for: $0) == b.side(for: $0) }
    }

    private static func sameIDs(_ a: [String]?, _ b: [String]?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.count == b.count && zip(a, b).allSatisfy { $0.isExactlyEqual(to: $1) }
        default: return false
        }
    }

    /// Plain-language fit of the staged selection into the staged maximum (all slots are one shared budget).
    var summary: String {
        let count = Set((selectedProviderIDs ?? []).map(\.exactKey)).count
        let slots = parsedMaximum ?? baseline.preferences.maximumVisibleSlots
        return CompactPreferences.capacitySummary(selectedCount: count, maximum: slots)
    }

    // MARK: Editing

    /// Steps the staged maximum by `delta` from its parsed value (or the saved one while the text is invalid).
    mutating func adjustMaximum(by delta: Int) {
        let current = parsedMaximum ?? baseline.preferences.maximumVisibleSlots
        let value = delta > 0 ? (current > Int.max - delta ? Int.max : current + delta) : max(1, current + delta)
        maximumText = String(value)
    }

    mutating func setSelected(_ selected: Bool, id: String) {
        var ids = selectedProviderIDs ?? []
        if selected { if !ids.contains(where: { $0.isExactlyEqual(to: id) }) { ids.append(id) } }
        else { ids.removeAll { $0.isExactlyEqual(to: id) } }
        selectedProviderIDs = ids
    }

    mutating func selectAll() { selectedProviderIDs = choices.map(\.id) }
    mutating func clearSelection() { selectedProviderIDs = [] }

    /// An explicit choice equal to the default side is stored as "no override" so reverting is not a change.
    mutating func setSide(_ side: CompactWingSide, for id: String) {
        providerSides[id] = side == baseline.preferences.defaultSide ? nil : side
    }

    /// Adopts a refreshed saved baseline for every field the user has not edited since the previous baseline
    /// (including the delayed first selection seed); edited fields, text and sides are kept.
    mutating func rebase(to snapshot: CompactSettingsSnapshot) {
        let old = baseline.preferences
        let new = snapshot.preferences
        if maximumText == String(old.maximumVisibleSlots) { maximumText = String(new.maximumVisibleSlots) }
        if Self.sameIDs(selectedProviderIDs, old.selectedProviderIDs) { selectedProviderIDs = new.selectedProviderIDs }
        let stagedDefault = old.defaultSide
        for key in Set(old.providerSides.keys).union(new.providerSides.keys).union(providerSides.keys) {
            let staged = providerSides[key] ?? stagedDefault
            if staged == old.side(for: key) { providerSides[key] = new.providerSides[key] }
        }
        baseline = snapshot
    }
}

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
        /// Staged total compact slots of the currently edited compact profile.
        case compactMaximum

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
        /// Set for compact problems of a profile other than the one currently edited.
        var scope: String? = nil
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
    /// Staged app-wide updater choices. They are committed separately from `PanelConfig` (different store).
    var updatePolicy: UpdatePolicy
    /// Staged panel monitor choice (`displayUUID == nil` follows the System primary display).
    var placement: PanelPlacementPreferences
    /// Automatic (`providers: null`) versus Custom (an ordered array, possibly empty). Rows survive mode switches.
    var providerMode: ProviderMode
    private(set) var providerRows: [Row] = []
    private(set) var labelRows: [Row] = []
    private(set) var metricRows: [Row] = []
    private var nextRowID = 0
    /// One staged compact draft per visited profile scope (trimmed profile, `default` when blank). Visiting a
    /// scope only reads its saved preferences; nothing is carried between scopes.
    private(set) var compactDrafts: [String: CompactSettingsDraft] = [:]
    private var compactScopeOrder: [String] = []

    init(config: PanelConfig, updatePolicy: UpdatePolicy = .defaults, placement: PanelPlacementPreferences = .defaults, compactSnapshot: CompactSettingsSnapshot? = nil) {
        self.placement = placement
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
        self.updatePolicy = updatePolicy
        providerMode = config.providers == nil ? .automatic : .custom
        for provider in config.providers ?? [] { addRow(.providers, key: provider) }
        for entry in config.labels.sortedEntries { addRow(.labels, key: entry.key, value: entry.value) }
        for entry in config.metrics.sortedEntries { addRow(.metrics, key: entry.key, value: entry.value) }
        if let compactSnapshot { installCompactSnapshot(compactSnapshot, scope: Self.compactScope(for: config.profile)) }
    }

    // MARK: Change tracking

    /// True when the staged values differ from the committed ones. Row identities and raw text typed-then-reverted
    /// are ignored: only the resulting values count. Used to refuse an update restart that would drop edits.
    func hasChanges(from config: PanelConfig, updatePolicy committedPolicy: UpdatePolicy, placement committedPlacement: PanelPlacementPreferences = .defaults) -> Bool {
        let base = GeneralSettingsDraft(config: config, updatePolicy: committedPolicy, placement: committedPlacement)
        func values(_ rows: [Row]) -> [[String]] { rows.map { [$0.key, $0.value] } }
        return nodePath != base.nodePath || ompPath != base.ompPath || profile != base.profile
            || refreshSeconds != base.refreshSeconds || cacheMinutes != base.cacheMinutes
            || timeoutSeconds != base.timeoutSeconds || warnPercent != base.warnPercent
            || criticalPercent != base.criticalPercent || showPace != base.showPace
            || providerMode != base.providerMode || updatePolicy != base.updatePolicy || placement != base.placement
            || values(providerRows) != values(base.providerRows) || values(labelRows) != values(base.labelRows)
            || values(metricRows) != values(base.metricRows) || hasCompactChanges
    }

    /// Follows a committed policy change made elsewhere (for example "Turn Off Notifications" in the update
    /// notice): a choice the user has not touched adopts the new committed value; a staged edit is kept.
    mutating func rebaseUpdatePolicy(from old: UpdatePolicy, to new: UpdatePolicy) {
        if updatePolicy.automaticChecks == old.automaticChecks { updatePolicy.automaticChecks = new.automaticChecks }
        if updatePolicy.automaticInstallation == old.automaticInstallation { updatePolicy.automaticInstallation = new.automaticInstallation }
        if updatePolicy.notificationsEnabled == old.notificationsEnabled { updatePolicy.notificationsEnabled = new.notificationsEnabled }
    }

    // MARK: Compact view (profile-scoped)

    /// The storage scope of a profile name: trimmed, `default` when blank (same normalization as the saved store).
    static func compactScope(for profile: String) -> String {
        let trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed
    }

    /// The scope the compact section currently edits: follows the staged profile text.
    var compactScope: String { Self.compactScope(for: profile) }

    /// The compact draft of the current scope, nil until a snapshot was installed for it.
    var compact: CompactSettingsDraft? { compactDrafts[compactScope] }

    var needsCompactSnapshot: Bool { compact == nil }

    /// Creates the scope's draft from a saved snapshot, or rebases an existing draft (unedited fields follow).
    mutating func installCompactSnapshot(_ snapshot: CompactSettingsSnapshot, scope: String) {
        if compactDrafts[scope] != nil { compactDrafts[scope]?.rebase(to: snapshot) }
        else {
            compactDrafts[scope] = CompactSettingsDraft(snapshot: snapshot)
            compactScopeOrder.append(scope)
        }
    }

    /// Edits the current scope's draft; no-op while no snapshot exists for it.
    mutating func editCompact(_ body: (inout CompactSettingsDraft) -> Void) {
        let scope = compactScope
        guard compactDrafts[scope] != nil else { return }
        body(&compactDrafts[scope]!)
    }

    /// True when any visited scope differs from its saved baseline.
    var hasCompactChanges: Bool { compactDrafts.values.contains { $0.hasChanges } }

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
        case .compactMaximum: return compact?.maximumText ?? ""
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
        case .compactMaximum: editCompact { $0.maximumText = text }
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

    /// Validates the whole draft into one commit: the configuration, the staged update policy and every visited
    /// compact scope that differs from its saved baseline (an invalid maximum blocks the whole save).
    func commit() throws -> SettingsCommit {
        var issues: [Issue] = []
        var config: PanelConfig?
        do { config = try candidate() }
        catch let failure as Failure { issues += failure.issues }
        var changes: [ScopedCompactChange] = []
        for scope in compactScopeOrder {
            guard let draft = compactDrafts[scope], draft.hasChanges else { continue }
            if let preferences = draft.preferences() {
                changes.append(ScopedCompactChange(profile: scope, preferences: preferences))
            } else if scope == compactScope {
                issues.append(Issue(field: .compactMaximum, rowID: nil, message: CompactSettingsDraft.invalidMaximumMessage))
            } else {
                issues.append(Issue(field: .compactMaximum, rowID: nil,
                                    message: "Compact maximum for profile \u{201C}\(scope)\u{201D}: \(CompactSettingsDraft.invalidMaximumMessage)", scope: scope))
            }
        }
        guard issues.isEmpty, let config else { throw Failure(issues: issues) }
        return SettingsCommit(config: config, updatePolicy: updatePolicy, compactChanges: changes, placement: placement)
    }

    // MARK: Panel monitor (app-wide placement)

    /// Stages the monitor choice: `nil` follows the System primary display, a UUID pins that physical monitor.
    /// Selecting the UUID of the current primary display is deliberately distinct from `nil`.
    mutating func selectMonitor(uuid: String?) { placement.displayUUID = uuid }

    func monitorOptions(choices: [PanelDisplayChoice]) -> [PlacementMonitorOption] {
        PlacementMonitorOption.options(selected: placement.displayUUID, choices: choices)
    }

    func monitorButtonTitle(choices: [PanelDisplayChoice]) -> String {
        PlacementMonitorOption.buttonTitle(selected: placement.displayUUID, choices: choices)
    }

    func monitorHint(choices: [PanelDisplayChoice]) -> String {
        PlacementMonitorOption.hint(selected: placement.displayUUID, choices: choices)
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

/// One row of the Settings "Monitor" list. Foundation-only so the selection rules are testable: a pinned monitor
/// that is not connected stays visible and selected (disabled), and an explicit UUID never collapses into the
/// "System primary" default even when both name the same physical display.
struct PlacementMonitorOption: Equatable {
    static let systemPrimaryID = "placement.system-primary"
    static let systemPrimaryTitle = "System primary (Default)"

    /// Stable dropdown row ID (`dropdown.row.<id>` in the accessibility tree).
    let id: String
    /// nil is the System primary default.
    let displayUUID: String?
    let title: String
    let subtitle: String
    let isAvailable: Bool
    let isSelected: Bool

    static func rowID(forUUID uuid: String) -> String { "placement.display.\(uuid)" }

    static func options(selected: String?, choices: [PanelDisplayChoice]) -> [PlacementMonitorOption] {
        let primaryName = choices.first(where: \.isPrimary).map { displayName($0.name) }
        var result = [PlacementMonitorOption(
            id: systemPrimaryID, displayUUID: nil, title: systemPrimaryTitle,
            subtitle: primaryName.map { "Currently \($0). Stays put when focus moves." } ?? "The display macOS marks as primary. Stays put when focus moves.",
            isAvailable: true, isSelected: selected == nil)]
        var counts: [String: Int] = [:]
        for choice in choices { counts[displayName(choice.name), default: 0] += 1 }
        var seen = Set<String>()
        for choice in choices where seen.insert(choice.uuid).inserted {
            let name = displayName(choice.name)
            var subtitle = choice.isPrimary ? "System primary display" : "Connected display"
            if (counts[name] ?? 0) > 1 { subtitle += " \u{00B7} ID \(shortID(choice.uuid))" }
            result.append(PlacementMonitorOption(id: rowID(forUUID: choice.uuid), displayUUID: choice.uuid, title: name,
                                                 subtitle: subtitle, isAvailable: true, isSelected: selected == choice.uuid))
        }
        if let selected, !seen.contains(selected) {
            result.append(PlacementMonitorOption(id: rowID(forUUID: selected), displayUUID: selected, title: "Disconnected monitor",
                                                 subtitle: "Unavailable \u{00B7} ID \(shortID(selected)) \u{00B7} choice is kept",
                                                 isAvailable: false, isSelected: true))
        }
        return result
    }

    static func buttonTitle(selected: String?, choices: [PanelDisplayChoice]) -> String {
        guard let selected else { return systemPrimaryTitle }
        guard let choice = choices.first(where: { $0.uuid == selected }) else { return "Disconnected monitor (unavailable)" }
        let name = displayName(choice.name)
        let duplicated = choices.filter { displayName($0.name) == name }.count > 1
        return duplicated ? "\(name) \u{00B7} ID \(shortID(choice.uuid))" : name
    }

    static func hint(selected: String?, choices: [PanelDisplayChoice]) -> String {
        guard let selected else {
            return "The panel stays on the System primary display and does not follow the pointer or the active window. If the primary display changes, the panel moves with it."
        }
        if let choice = choices.first(where: { $0.uuid == selected }) {
            return "The panel is always placed on \(displayName(choice.name)), even if it is not the primary display."
        }
        return "This monitor is not connected. Until it returns the panel temporarily uses the System primary display; your choice is kept and the panel moves back when the monitor reconnects."
    }

    private static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Display" : trimmed
    }

    private static func shortID(_ uuid: String) -> String {
        String(uuid.filter { $0 != "-" }.suffix(6)).uppercased()
    }
}
